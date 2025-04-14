//
//  GoogleCloudLogHandler.swift
//  GoogleCloudLogging
//
//  Created by Alexey Demin on 2020-04-27.
//  Copyright © 2020 DnV1eX. All rights reserved.
//  Updated by Alexandru Solomon on 2025-04-14
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

@preconcurrency import Foundation
import Logging
import struct os.OSAllocatedUnfairLock

// MARK: - GoogleCloudLogHandler
/// A thread-safe log handler that buffers and uploads logs to Google Cloud Logging.
///
/// This handler manages log entries by:
/// 1. Bufferings logs in memory
/// 2. Periodically flushing them to a temporary file
/// 3. Uploading batches to Google Cloud Logging on a schedule
/// 4. Applying various limits and retention policies
///
public final class GoogleCloudLogHandler: @unchecked Sendable {

  // MARK: - Private Static Properties

  /// The shared Google Cloud Logging service instance
  nonisolated(unsafe) private static var loggingService: GoogleCloudLogging?

  /// Thread-safe state container for handler configuration and buffers
  nonisolated(unsafe) private static var criticalState = ManagedCriticalState(State())

  /// Serial queue for file access operations
  private static let fileAccessQueue = DispatchQueue(label: "GoogleCloudLogHandler.fileAccessQueue")

  /// Internal logger for handler operations
  private static let internalLogger = Logger(label: "GoogleCloudLogHandler")

  /// File URL for temporary log storage
  private static let logFileURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("GoogleCloudLogEntries", isDirectory: false)
    .appendingPathExtension("jsonl")

  /// Timer for scheduled uploads to Google Cloud
  private static let uploadTimer: DispatchSourceTimer = {
    let timer = DispatchSource.makeTimerSource()
    timer.setEventHandler(handler: uploadOnSchedule)
    timer.activate()
    return timer
  }()

  /// Timer for periodic buffer flushes to disk
  private static let flushTimer: DispatchSourceTimer = {
    let timer = DispatchSource.makeTimerSource()
    let dispatchWorkItem = DispatchWorkItem {
      flushBufferToFile()
    }
    timer.setEventHandler(handler: dispatchWorkItem)
    timer.activate()
    return timer
  }()


  // MARK: - Private instance properties

  /// Lock for instance-level thread safety
  private var unfairLock = OSAllocatedUnfairLock()

  /// Instance-specific log level override
  private var _logLevel: Logging.Logger.Level? = GoogleCloudLogHandler.defaultLogLevel

  /// Instance-specific metadata
  private var _metadata: Logging.Logger.Metadata = [:]

  // MARK: - Public Properties

  /// The logger's metadata
  public var metadata: Logging.Logger.Metadata {
    get {
      unfairLock.withLock {
        _metadata
      }
    }
    set {
      unfairLock.withLock {
        _metadata = newValue
      }
    }
  }

  /// The logger's log level
  public var logLevel: Logging.Logger.Level {
    get {
      _logLevel ?? Self.getLogLevel()
    }
    set {
      _logLevel = newValue
    }
  }

  // MARK: - Lifecycle

  /// The label associated to the logger instance
  private let label: String

  public init(label: String) {
    self.label = label
  }
}

// MARK: - Upload methods

extension GoogleCloudLogHandler {

  /// Schedules periodic uploads based on configured internval
  private static func upload() {
    assert(loggingService != nil, "App must setup GoogleCloudLogHandler before calling upload")

    uploadTimer.schedule(delay: nil, repeating: Self.getUploadInterval())
  }

  /// Timer callback that initiates log upload process
  private static func uploadOnSchedule() {
    internalLogger.debug("Start uploading logs")

    fileAccessQueue.async {
      do {
        let (logData, fileHandle) = try readLogFile()
        guard !logData.isEmpty else {
          internalLogger.debug("No logs to upload")
          return
        }

        let processedEntries = processLogEntries(from: logData)
        uploadLogs(processedEntries, fileHandle: fileHandle)

      } catch {
        internalLogger.error("Error uploading logs: \(error)")
      }
    }
  }

  /// Updates log file after processing, keeping only specified entries
  private static func updateLogFile(keeping entries: [Log.Entry], originalLineCount: Int, fileHandle: FileHandle) {
    do {
      if originalLineCount != entries.count {
        let encoder = JSONEncoder()
        var lines = entries.compactMap { try? encoder.encode($0) }
        if let data = try fileHandle.legacyReadToEnd(), !data.isEmpty {
          lines.append(data)
        }
        try Data(lines.joined(separator: [.newline])).write(to: logFileURL, options: .atomic)
        internalLogger.debug("Overflowed or expired logs have been deleted")
      } else {
        internalLogger.debug("No overflowed or expired logs to delete")
      }
    } catch {
      internalLogger.error("Unable to delete overflowed or expired logs", metadata: [MetadataKey.error: "\(error)"])
    }
  }

  /// Uploads processed logs to Google Cloud
  private static func uploadLogs(_ processedLogs: ProcessedLogs, fileHandle: FileHandle) {
    guard let loggingService else {
      internalLogger.critical("Attempt to upload logs without GoogleCloudLogHandler setup")

      if processedLogs.needsCleanup {
        updateLogFile(keeping: processedLogs.entries, originalLineCount: processedLogs.originalLineCount, fileHandle: fileHandle)
      }
      return
    }

    Task {
      do {
        try await loggingService.writeEntries(processedLogs.entries)

        fileAccessQueue.async {
          self.deleteOldEntries(fileHandle: fileHandle)
        }

      } catch {
        handleUploadError(error)

        if processedLogs.needsCleanup {
          fileAccessQueue.async {
            updateLogFile(
              keeping: processedLogs.entries,
              originalLineCount: processedLogs.originalLineCount,
              fileHandle: fileHandle)
          }
        }
      }
    }
  }

  /// Handles errors during log upload
  private static func handleUploadError(_ error: Error) {
    switch error {
    case let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorNotConnectedToInternet:
      internalLogger.notice("Logs cannot be uploaded without an internet connection")
    case let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut:
      internalLogger.notice("Logs may not have been uploaded due to poor internet connection")
    case GoogleCloudLogging.EntriesWriteError.noEntriesToSend:
      internalLogger.notice("No relevant logs to upload")
    default:
      internalLogger.error("Unable to upload logs", metadata: [MetadataKey.error: "\(error)"])
    }
  }

  /// Cleans up successfuly uploaded logs
  private static func deleteOldEntries(fileHandle: FileHandle) {
    do {
      try (fileHandle.legacyReadToEnd() ?? Data()).write(to: logFileURL, options: .atomic)
      internalLogger.debug("Uploaded logs have been deleted")
    } catch {
      internalLogger.error("Unable to delete uploaded logs", metadata: [MetadataKey.error: "\(error)"])
    }
  }
}

// MARK: - GoogleCloudLogHandler + LogHandler

extension GoogleCloudLogHandler: LogHandler {

  /// Access metadata values by key
  public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get {
      Self.getMetadataValue(key)
    }
    set(newValue) {
      Self.setMetadataValue(key, value: newValue)
    }
  }

  /// Flushes bufferd logs to disk
  private static func flushBufferToFile(_ entries: [Log.Entry]? = nil, _ level: Logger.Level? = nil, _ file: String? = nil, function: String? = nil) {
    let logEntryBuffer = entries ?? getLogEntryBuffer()
    guard !logEntryBuffer.isEmpty else {
      return
    }

    fileAccessQueue.async {
      do {
        try prepareLogFile()

        let fileHandle = try FileHandle(forWritingTo: logFileURL)
        defer { try? fileHandle.close() }

        try fileHandle.legacySeekToEnd()

        let encoder = JSONEncoder()
        for entry in logEntryBuffer {
          try fileHandle.legacyWrite(contentsOf: encoder.encode(entry))
          try fileHandle.legacyWrite(contentsOf: [.newline])
        }

        resetLogEntryBuffer()
      } catch {
        internalLogger.error("Unable to save entries. Error: \(error)")
      }

      guard let level, let file, let function else {
        return
      }

      if
        let signalingLogLevel = Self.getSignalingLogLevel(), level >= signalingLogLevel,
        file != #file || function != "uploadOnSchedule()"
      {
        Self.upload()
      }
    }
  }

  /// Process a log message
  public func log(
    level: Logger.Level,
    message: Logger.Message,
    metadata: Logger.Metadata?,
    source: String,
    file: String,
    function: String,
    line: UInt)
  {
    let logEntry = createLogEntry(level: level, message: message, file: file, function: function, line: line)

    var entriesToFlush: [Log.Entry]? = nil
    Self.criticalState.withCriticalRegion { state in
      state.logEntryBuffer.append(logEntry)

      if state.logEntryBuffer.count >= state.bufferSizeLimit {
        entriesToFlush = state.logEntryBuffer
        state.logEntryBuffer.removeAll()
      }
    }

    if let entriesToFlush {
      Self.flushBufferToFile(entriesToFlush, level, file, function: function)
    }

    let bufferFlushInterval = Self.getBufferFlushInterval()
    Self.flushTimer.schedule(deadline: .now(), repeating: bufferFlushInterval)
  }

  /// Create a log entry from components
  private func createLogEntry(level: Logger.Level, message: Logger.Message, file: String, function: String, line: UInt) -> Log.Entry {
    let date = Date()
    let hashValue = Self.createHashedID(message, date: date)

    var replacedMetadata = metadata.update(with: self.metadata)

    if !replacedMetadata.isEmpty, file != #file || function != #function {
      Self.internalLogger.warning(
        "Log metadata is replaced by logger metadata",
        metadata: [MetadataKey.replacedMetadata: .dictionary(replacedMetadata)])
    }

    replacedMetadata = metadata.update(with: Self.getGlobalMetadata())

    if !replacedMetadata.isEmpty, file != #file || function != #function {
      Self.internalLogger.warning(
        "Log metadata is replaced by global metadata",
        metadata: [MetadataKey.replacedMetadata: .dictionary(replacedMetadata)])
    }

    let labels = metadata.mapValues { "\($0)" }
    let sourceLocation = Log.Entry.SourceLocation(file: file, line: "\(line)", function: function)

    return Log.Entry(
      logName: self.label,
      timestamp: date,
      severity: .init(level: level),
      insertId: hashValue.map { String($0, radix: 36) },
      labels: labels.isEmpty ? nil : labels,
      sourceLocation: sourceLocation,
      textPayload: "\(message)")
  }

  /// Creates a unique ID for log entries
  private static func createHashedID(_ message: Logger.Message, date: Date) -> Int? {
    Self.criticalState.withCriticalRegion { state in
      state.globalMetadata[MetadataKey.clientId].map {
        var hasher = Hasher()
        hasher.combine("\($0)") // Required in case random seeding is disabled.
        hasher.combine("\(message)")
        hasher.combine(date)
        return hasher.finalize()
      }
    }
  }

  /// Reads logs from temporary file
  private static func readLogFile() throws -> (Data, FileHandle) {
    let fileHandle = try FileHandle(forReadingFrom: logFileURL)
    guard let data = try fileHandle.legacyReadToEnd() else {
      return (Data(), fileHandle)
    }
    return (data, fileHandle)
  }

  /// Applies processing rules to log entries
  private static func processLogEntries(from data: Data) -> ProcessedLogs {
    var lines = data.split(separator: .newline)
    let originalLineCount = lines.count
    var needsCleanup = false

    lines = applyLogEntrySizeLimit(lines, &needsCleanup)
    lines = applyTotalLogSizeLimit(lines, &needsCleanup)

    var logEntries = decodeLogEntries(lines, &needsCleanup)
    logEntries = applyRetentionPeriod(logEntries)

    return ProcessedLogs(entries: logEntries, originalLineCount: originalLineCount, needsCleanup: needsCleanup)
  }

  /// Enforces maximum log entry size
  private static func applyLogEntrySizeLimit(_ lines: [Data.SubSequence], _ needsCleanup: inout Bool) -> [Data.SubSequence] {
    guard let maxLogEntrySize = getMaxLogEntrySize() else {
      return lines
    }

    var filteredLines = lines
    let logSize = filteredLines.reduce(0) { $0 + $1.count }

    if logSize > maxLogEntrySize {
      let beforeCount = filteredLines.count
      filteredLines.removeAll { $0.count > maxLogEntrySize }
      let removedLineCount = beforeCount - filteredLines.count

      if removedLineCount > 0 {
        needsCleanup = true
        internalLogger.warning(
          "Some log entries are excluded from the upload due to exceeding the log entry size limit",
          metadata: [
            MetadataKey.excludedLogEntryCount: "\(removedLineCount)",
            MetadataKey.maxLogEntrySize: "\(maxLogEntrySize)",
          ])
      }
    }

    return filteredLines
  }

  /// Enforces log retention period
  private static func applyRetentionPeriod(_ logEntries: [Log.Entry]) -> [Log.Entry] {
    guard let retentionPeriod = getRetentionPeriod() else {
      return logEntries
    }

    var newLogEntries = logEntries

    let logEntryCount = logEntries.count
    newLogEntries.removeAll { $0.timestamp.map { -$0.timeIntervalSinceNow > retentionPeriod } ?? false }
    let removedLogEntryCount = logEntryCount - newLogEntries.count
    if removedLogEntryCount > 0 {
      internalLogger.warning(
        "Failed due to exceeding the retention period",
        metadata: [
          MetadataKey.excludedLogEntryCount: "\(removedLogEntryCount)",
          MetadataKey.retentionPeriod: "\(retentionPeriod)",
        ])
    }

    return newLogEntries
  }

  /// Enforces total log size limit
  private static func applyTotalLogSizeLimit(_ lines: [Data.SubSequence], _: inout Bool) -> [Data.SubSequence] {
    guard let maxLogSize = getMaxLogSize() else {
      return lines
    }

    var filteredLines = lines
    var logSize = filteredLines.reduce(0) { $0 + $1.count }

    if logSize > maxLogSize {
      let lineCount = lines.count
      repeat {
        logSize -= filteredLines.removeFirst().count
      } while logSize > maxLogSize
      let removedLineCount = lineCount - lines.count
      internalLogger.warning(
        "Failed due to exceeding the log size limit",
        metadata: [MetadataKey.excludedLogEntryCount: "\(removedLineCount)", MetadataKey.maxLogSize: "\(maxLogSize)"])
    }

    return filteredLines
  }

  /// Decodes log entries from file data
  private static func decodeLogEntries(_ lines: [Data.SubSequence], _: inout Bool) -> [Log.Entry] {
    let decoder = JSONDecoder()
    let logEntries = lines.compactMap { try? decoder.decode(Log.Entry.self, from: $0) }
    let undecodedLogEntryCount = lines.count - logEntries.count
    if undecodedLogEntryCount > 0 {
      internalLogger.warning(
        "Failed due to decoding failure",
        metadata: [MetadataKey.excludedLogEntryCount: "\(undecodedLogEntryCount)"])
    }
    return logEntries
  }
}

// MARK: - Configuration

extension GoogleCloudLogHandler {

  /// Configures the handler with Google Cloud credentials
  public static func configure(serviceAccountCredentials url: URL, clientID: UUID?, logFile _: URL? = nil) throws {
    loggingService = try GoogleCloudLogging(serviceAccountCredentials: url)

    criticalState.withCriticalRegion { state in
      state.globalMetadata[MetadataKey.clientId] = clientID.map(Logger.MetadataValue.stringConvertible)
    }

    try prepareLogFile()
  }

  /// Prepares the temporary log file
  private static func prepareLogFile() throws {
    if (try? logFileURL.checkResourceIsReachable()) != true {
      try FileManager.default.createDirectory(
        at: logFileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil)
      try Data().write(to: logFileURL)
    }
  }
}

// MARK: - State Management

extension GoogleCloudLogHandler {
  /// Default log level when none is specified
  static var defaultLogLevel: Logger.Level {
    .info
  }

  /// Configuration state container
  struct State {
    var globalMetadata: Logger.Metadata = [:]
    var forcedLogLevel: Logger.Level?
    var logLevel: Logger.Level = GoogleCloudLogHandler.defaultLogLevel
    var signalingLogLevel: Logger.Level? = .critical
    var maxLogEntrySize: UInt? = 256_000
    var maxLogSize: UInt? = 10_000_000
    var retentionPeriod: TimeInterval? = 3600 * 24 * 30
    var includeSourceLocation = true
    var uploadInterval: TimeInterval? = 3600
    var metadata: Logger.Metadata = [:]
    var logEntryBuffer: [Log.Entry] = []
    var bufferFlushInterval: TimeInterval = 1.0
    var bufferSizeLimit: Int = 100
  }

    // MARK: Various state accessors and mutators

  public static func setUploadInterval(_ interval: TimeInterval) {
    Self.criticalState.withCriticalRegion { state in
      state.uploadInterval = interval
    }
  }

  public static func getMetadataValue(_ key: String) -> Logger.Metadata.Value? {
    Self.criticalState.withCriticalRegion { state in
      state.metadata[key]
    }
  }

  public static func setMetadataValue(_ key: String, value: Logger.Metadata.Value?) {
    Self.criticalState.withCriticalRegion { state in
      state.metadata[key] = value
    }
  }

  private static func getUploadInterval() -> TimeInterval? {
    Self.criticalState.withCriticalRegion { state in
      state.uploadInterval
    }
  }

  private static func getBufferFlushInterval() -> TimeInterval {
    Self.criticalState.withCriticalRegion { state in
      state.bufferFlushInterval
    }
  }

  private static func getMaxLogEntrySize() -> UInt? {
    Self.criticalState.withCriticalRegion { state in
      state.maxLogEntrySize
    }
  }

  private static func resetLogEntryBuffer() {
    Self.criticalState.withCriticalRegion { state in
      state.logEntryBuffer.removeAll()
    }
  }

  private static func getLogEntryBuffer() -> [Log.Entry] {
    Self.criticalState.withCriticalRegion { state in
      state.logEntryBuffer
    }
  }

  private static func getRetentionPeriod() -> TimeInterval? {
    Self.criticalState.withCriticalRegion { state in
      state.retentionPeriod
    }
  }

  private static func getMaxLogSize() -> UInt? {
    Self.criticalState.withCriticalRegion { state in
      state.maxLogSize
    }
  }

  private static func getSignalingLogLevel() -> Logger.Level? {
    Self.criticalState.withCriticalRegion { state in
      state.signalingLogLevel
    }
  }

  private static func getGlobalMetadata() -> Logger.Metadata {
    Self.criticalState.withCriticalRegion { state in
      state.globalMetadata
    }
  }

  private static func getLogLevel() -> Logger.Level {
    Self.criticalState.withCriticalRegion { state in
      state.logLevel
    }
  }

  private struct ProcessedLogs {
    let entries: [Log.Entry]
    let originalLineCount: Int
    let needsCleanup: Bool
  }
}
