//
//  String+Extensions.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

extension String {
  func safeLogId() -> String {
    let logId = String(
      (applyingTransform(.toLatin, reverse: false) ?? self)
        .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en_US"))
        .replacingOccurrences(of: " ", with: "_")
        .unicodeScalars
        .filter(CharacterSet.logIdSymbols.contains)
        .prefix(511))
    return logId.isEmpty ? "_" : logId
  }
}
