//
//  Response.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

struct Response: Decodable {
  struct Error: Decodable {
    let code: Int
    let message: String
    let status: String
  }

  let error: Error?
}
