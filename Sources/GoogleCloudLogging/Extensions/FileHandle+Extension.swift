//
//  FileHandle+Extension.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

extension FileHandle {
  @discardableResult
  func legacySeekToEnd() throws -> UInt64 {
    if #available(OSX 10.15, iOS 13.4, watchOS 6.2, tvOS 13.4, *) {
      try seekToEnd()
    } else {
      seekToEndOfFile()
    }
  }

  func legacyWrite(contentsOf data: some DataProtocol) throws {
    if #available(OSX 10.15, iOS 13.4, watchOS 6.2, tvOS 13.4, *) {
      try write(contentsOf: data)
    } else {
      write(Data(data))
    }
  }

  func legacyReadToEnd() throws -> Data? {
    if #available(OSX 10.15, iOS 13.4, watchOS 6.2, tvOS 13.4, *) {
      try readToEnd()
    } else {
      readDataToEndOfFile()
    }
  }
}
