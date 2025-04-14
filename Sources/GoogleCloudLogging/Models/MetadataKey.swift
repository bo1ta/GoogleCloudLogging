//
//  MetadataKey.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

public enum MetadataKey {
  public static let clientId = "clientId"
  public static let buildConfiguration = "buildConfiguration"
  public static let error = "error"
  public static let description = "description"
  static let serviceAccountCredentials = "serviceAccountCredentials"
  static let logFile = "logFile"
  static let label = "label"
  static let replacedMetadata = "replacedMetadata"
  static let logEntry = "logEntry"
  static let excludedLogEntryCount = "excludedLogEntryCount"
  static let maxLogEntrySize = "maxLogEntrySize"
  static let maxLogSize = "maxLogSize"
  static let retentionPeriod = "retentionPeriod"
  static let uploadInterval = "uploadInterval"
}
