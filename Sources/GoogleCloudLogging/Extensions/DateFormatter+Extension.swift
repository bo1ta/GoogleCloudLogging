//
//  DateFormatter+Extension.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

extension ISO8601DateFormatter {
  static func internetDateTimeWithNanosecondsString(
    from date: Date,
    timeZone: TimeZone = .gmt)
    -> String
  {
    var string = ISO8601DateFormatter.string(from: date, timeZone: timeZone, formatOptions: .withInternetDateTime)
    var timeInterval = date.timeIntervalSinceReferenceDate
    if timeInterval < 0 {
      timeInterval += (-timeInterval * 2).rounded(.up)
    }
    string.insert(contentsOf: "\(timeInterval)".drop { $0 != "." }.prefix(10), at: string.index(string.startIndex, offsetBy: 19))
    return string
  }
}
