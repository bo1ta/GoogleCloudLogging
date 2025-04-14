//
//  Token.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

struct Token: Decodable {
  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case tokenType = "token_type"
  }

  let accessToken: String
  let expiresIn: Int
  let tokenType: String

  let receiptDate = Date()
  var isExpired: Bool { receiptDate + TimeInterval(expiresIn) < Date() }
}
