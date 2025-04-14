//
//  LogEngine.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation
import Logging
import Dispatch

public protocol LogEngineProvider {

  /// Processes the log and queues it for upload
  ///
  func processLog(label: String, level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, file: String, function: String, line: UInt)

  /// Configures the handler with Google Cloud credentials
  ///
  func configure(serviceAccountCredentials url: URL, clientID: UUID?) throws

  /// Schedules periodic uploads based on configured internval
  ///
  func upload()
}

/// A thread-safe log engine that buffers and uploads logs to Google Cloud Logging.
///
/// This handler manages log entries by:
/// 1. Bufferings logs in memory
/// 2. Periodically flushing them to a temporary file
/// 3. Uploading batches to Google Cloud Logging on a schedule
/// 4. Applying various limits and retention policies
///
public class LogEngine: LogEngineProvider, @unchecked Sendable {
  public static let shared = LogEngine()

  // MARK: Internal State

  private struct State {
    var globalMetadata: Logger.Metadata = [:]
    var forcedLogLevel: Logger.Level?
    var logLevel: Logger.Level = .info
    var signalingLogLevel: Logger.Level? = .info
    var maxLogEntrySize: UInt? = 256_000
    var maxLogSize: UInt? = 10_000_000
    var retentionPeriod: TimeInterval? = 3600 * 24 * 30
    var includeSourceLocation = true
    var uploadInterval: TimeInterval? = 3600
    var metadata: Logger.Metadata = [:]
  }

  private let criticalState = ManagedCriticalState(State())

  // MARK: - Private Properties

  private var loggingService: GoogleCloudLogging?

  private let fileAccessQueue = DispatchQueue(label: "LogEngine.fileAccessQueue")
  private let internalLogger = Logger(label: "LogEngine")
  private let logFileURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("GoogleCloudLogEntries", isDirectory: false)
    .appendingPathExtension("jsonl")

  private let uploadTimer: DispatchSourceTimer

  init() {
    uploadTimer = DispatchSource.makeTimerSource()
    uploadTimer.setEventHandler(handler: {
      self.uploadOnSchedule()
    })
    uploadTimer.activate()
  }

  // MARK: - Public methods

  /// Configures the handler with Google Cloud credentials
  public func configure(serviceAccountCredentials url: URL, clientID: UUID?) throws {
    loggingService = try GoogleCloudLogging(serviceAccountCredentials: url)

    criticalState.withCriticalRegion { state in
      state.globalMetadata[MetadataKey.clientId] = clientID.map(Logger.MetadataValue.stringConvertible)
    }

    try prepareLogFile()
  }

  /// Prepares the temporary log file
  private func prepareLogFile() throws {
    if (try? logFileURL.checkResourceIsReachable()) != true {
      try FileManager.default.createDirectory(
        at: logFileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil)
      try Data().write(to: logFileURL)
    }
  }

  public func processLog(label: String, level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, file: String, function: String, line: UInt) {
    let logEntry = createLogEntry(label: label, level: level, message: message, metadata: metadata, file: file, function: function, line: line)
    flushBufferToFile(logEntry, level: level, file: file, function: function)
  }

  public func upload() {
    assert(loggingService != nil, "App must setup GoogleCloudLogHandler before calling upload")

    uploadTimer.schedule(delay: nil, repeating: getUploadInterval())
  }

  private func uploadOnSchedule() {
    internalLogger.debug("Start uploading logs")

    fileAccessQueue.async {
      do {
        let (logData, fileHandle) = try self.readLogFile()
        guard !logData.isEmpty else {
          self.internalLogger.debug("No logs to upload")
          return
        }

        let processedEntries = self.processLogEntries(from: logData)
        self.uploadLogs(processedEntries, fileHandle: fileHandle)

      } catch {
        self.internalLogger.error("Error uploading logs: \(error)")
      }
    }
  }

  /// Updates log file after processing, keeping only specified entries
  private func updateLogFile(keeping entries: [Log.Entry], originalLineCount: Int, fileHandle: FileHandle) {
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
  private func uploadLogs(_ processedLogs: ProcessedLogs, fileHandle: FileHandle) {
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
            self.updateLogFile(
              keeping: processedLogs.entries,
              originalLineCount: processedLogs.originalLineCount,
              fileHandle: fileHandle)
          }
        }
      }
    }
  }

  /// Handles errors during log upload
  private func handleUploadError(_ error: Error) {
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
  private func deleteOldEntries(fileHandle: FileHandle) {
    do {
      try (fileHandle.legacyReadToEnd() ?? Data()).write(to: logFileURL, options: .atomic)
      internalLogger.debug("Uploaded logs have been deleted")
    } catch {
      internalLogger.error("Unable to delete uploaded logs", metadata: [MetadataKey.error: "\(error)"])
    }
  }

  private func flushBufferToFile(_ logEntry: Log.Entry, level: Logger.Level, file: String, function: String) {
    fileAccessQueue.async {
      do {
        try self.prepareLogFile()

        let fileHandle = try FileHandle(forWritingTo: self.logFileURL)
        defer { try? fileHandle.close() }

        try fileHandle.legacySeekToEnd()
        try fileHandle.legacyWrite(contentsOf: JSONEncoder().encode(logEntry))
        try fileHandle.legacyWrite(contentsOf: [.newline])
      } catch {
        self.internalLogger.error("Unable to save entries. Error: \(error)")
      }

      if
        let signalingLogLevel = self.getSignalingLogLevel(), level >= signalingLogLevel,
        file != #file || function != "uploadOnSchedule()"
      {
        self.upload()
      }
    }
  }

  private func createLogEntry(label: String, level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, file: String, function: String, line: UInt) -> Log.Entry {
    let date = Date()
    let hashValue = createHashedID(message, date: date)

    var metadata = metadata ?? [:]
    var replacedMetadata = metadata.update(with: self.getGlobalMetadata())

    if !replacedMetadata.isEmpty, file != #file || function != #function {
      internalLogger.warning(
        "Log metadata is replaced by logger metadata",
        metadata: [MetadataKey.replacedMetadata: .dictionary(replacedMetadata)])
    }

    replacedMetadata = metadata.update(with: self.getGlobalMetadata())

    if !replacedMetadata.isEmpty, file != #file || function != #function {
      self.internalLogger.warning(
        "Log metadata is replaced by global metadata",
        metadata: [MetadataKey.replacedMetadata: .dictionary(replacedMetadata)])
    }

    let labels = metadata.mapValues { "\($0)" }
    let sourceLocation = Log.Entry.SourceLocation(file: file, line: "\(line)", function: function)

    return Log.Entry(
      logName: label,
      timestamp: date,
      severity: .init(level: level),
      insertId: hashValue.map { String($0, radix: 36) },
      labels: labels.isEmpty ? nil : labels,
      sourceLocation: sourceLocation,
      textPayload: "\(message)")
  }

  /// Creates a unique ID for log entries
  private func createHashedID(_ message: Logger.Message, date: Date) -> Int? {
    criticalState.withCriticalRegion { state in
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
  private func readLogFile() throws -> (Data, FileHandle) {
    let fileHandle = try FileHandle(forReadingFrom: logFileURL)
    guard let data = try fileHandle.legacyReadToEnd() else {
      return (Data(), fileHandle)
    }
    return (data, fileHandle)
  }

  /// Applies processing rules to log entries
  private func processLogEntries(from data: Data) -> ProcessedLogs {
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
  private func applyLogEntrySizeLimit(_ lines: [Data.SubSequence], _ needsCleanup: inout Bool) -> [Data.SubSequence] {
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
  private func applyRetentionPeriod(_ logEntries: [Log.Entry]) -> [Log.Entry] {
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
  private func applyTotalLogSizeLimit(_ lines: [Data.SubSequence], _: inout Bool) -> [Data.SubSequence] {
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
  private func decodeLogEntries(_ lines: [Data.SubSequence], _: inout Bool) -> [Log.Entry] {
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

// MARK: - Safe Accessors

extension LogEngine {
  public func setUploadInterval(_ interval: TimeInterval) {
    criticalState.withCriticalRegion { state in
      state.uploadInterval = interval
    }
  }

  public func getMetadataValue(_ key: String) -> Logger.Metadata.Value? {
    criticalState.withCriticalRegion { state in
      state.metadata[key]
    }
  }

  public func setMetadataValue(_ key: String, value: Logger.Metadata.Value?) {
    criticalState.withCriticalRegion { state in
      state.metadata[key] = value
    }
  }

  public func getUploadInterval() -> TimeInterval? {
    criticalState.withCriticalRegion { state in
      state.uploadInterval
    }
  }

  public func getMaxLogEntrySize() -> UInt? {
    criticalState.withCriticalRegion { state in
      state.maxLogEntrySize
    }
  }

  public func getRetentionPeriod() -> TimeInterval? {
    criticalState.withCriticalRegion { state in
      state.retentionPeriod
    }
  }

  public func getMaxLogSize() -> UInt? {
    criticalState.withCriticalRegion { state in
      state.maxLogSize
    }
  }

  public func getSignalingLogLevel() -> Logger.Level? {
    criticalState.withCriticalRegion { state in
      state.signalingLogLevel
    }
  }

  public func getGlobalMetadata() -> Logger.Metadata {
    criticalState.withCriticalRegion { state in
      state.globalMetadata
    }
  }

  public func getLogLevel() -> Logger.Level {
    criticalState.withCriticalRegion { state in
      state.logLevel
    }
  }
}

extension LogEngine {
  private struct ProcessedLogs {
    let entries: [Log.Entry]
    let originalLineCount: Int
    let needsCleanup: Bool
  }
}
