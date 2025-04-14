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

import Foundation
import Logging

public struct GoogleCloudLogHandler: @unchecked Sendable {

  // MARK: - Private instance properties

  /// The label associated to the logger instance
  private let label: String

  // MARK: - Public Properties

  /// The logger's metadata
  public var metadata: Logging.Logger.Metadata = [:]

  /// The logger's log level
  public var logLevel: Logging.Logger.Level = .info

  // MARK: - Lifecycle

  public init(label: String) {
    self.label = label
  }
}

// MARK: - GoogleCloudLogHandler + LogHandler

extension GoogleCloudLogHandler: LogHandler {
  public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
    get {
      metadata[key]
    }
    set(newValue) {
      metadata[key] = newValue
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
    LogEngineRegistry.getEngine().processLog(label: self.label, level: level, message: message, metadata: metadata, file: file, function: function, line: line)
  }
}
