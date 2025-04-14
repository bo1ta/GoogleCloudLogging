//
//  Log.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation
import Logging

struct Log: Encodable {
  struct MonitoredResource: Encodable {
    let type: String
    let labels: [String: String]

    static func global(projectId: String) -> MonitoredResource { MonitoredResource(
      type: "global",
      labels: ["project_id": projectId]) }
  }

  struct Entry: Codable {
    enum Severity: String, Codable {
      case `default` = "DEFAULT"
      case debug = "DEBUG"
      case info = "INFO"
      case notice = "NOTICE"
      case warning = "WARNING"
      case error = "ERROR"
      case critical = "CRITICAL"
      case alert = "ALERT"
      case emergency = "EMERGENCY"

      init(level: Logger.Level) {
        switch level {
        case .trace: self = .default
        case .debug: self = .debug
        case .info: self = .info
        case .notice: self = .notice
        case .warning: self = .warning
        case .error: self = .error
        case .critical: self = .critical
        }
      }
    }

    struct SourceLocation: Codable {
      let file: String
      let line: String
      let function: String
    }

    var logName: String
    let timestamp: Date?
    let severity: Severity?
    let insertId: String?
    let labels: [String: String]?
    let sourceLocation: SourceLocation?
    let textPayload: String
  }

  let resource: MonitoredResource
  let entries: [Entry]

  static func name(projectId: String, logId: String) -> String { "projects/\(projectId)/logs/\(logId.safeLogId())" }
}
