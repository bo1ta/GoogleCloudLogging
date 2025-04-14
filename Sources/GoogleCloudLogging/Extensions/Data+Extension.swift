//
//  Data+Extension.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

extension Data.Element {
  // swiftlint:disable:next force_unwrapping
  static let newline = Data("\n".utf8).first! // 10
}
