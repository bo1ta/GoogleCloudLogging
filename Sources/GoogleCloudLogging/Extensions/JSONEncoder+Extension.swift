//
//  JSONEncoder+Extension.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

extension JSONEncoder.DateEncodingStrategy {
  static let iso8601WithNanoseconds = custom { date, encoder in
    var container = encoder.singleValueContainer()
    try container.encode(ISO8601DateFormatter.internetDateTimeWithNanosecondsString(from: date))
  }
}
