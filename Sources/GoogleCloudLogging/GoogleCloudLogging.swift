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

// MARK: - GoogleCloudLogging

actor GoogleCloudLogging {
  private var accessToken: Token?

  let serviceAccountCredentials: Credentials
  let session: URLSession

  init(serviceAccountCredentials url: URL) throws {
    let data = try Data(contentsOf: url)
    let credentials = try JSONDecoder().decode(Credentials.self, from: data)

    guard credentials.type == "service_account" else {
      throw InitError.wrongCredentialsType(credentials)
    }

    serviceAccountCredentials = credentials
    session = URLSession(configuration: .ephemeral)
  }

  func requestToken() async throws -> Token {
    guard let url = URL(string: self.serviceAccountCredentials.tokenURI) else {
      throw TokenRequestError.invalidURL(self.serviceAccountCredentials.tokenURI)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    do {
      let jwt = try JWT.create(using: self.serviceAccountCredentials, for: [.loggingWrite])
      request.httpBody = try JSONEncoder().encode([
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": jwt,
      ])
    } catch {
      throw error
    }

    let (data, _) = try await self.session.data(for: request)
    if let responseError = try JSONDecoder().decode(Response.self, from: data).error {
      throw TokenRequestError.errorReceived(responseError)
    }

    let token = try JSONDecoder().decode(Token.self, from: data)
    guard token.tokenType == "Bearer" else {
      throw TokenRequestError.wrongTokenType(token)
    }
    return token
  }

  func writeEntries(_ entries: [Log.Entry]) async throws {
    if let accessToken, !accessToken.isExpired {
      try await self.writeEntries(entries, token: accessToken)
    } else {
      do {
        let token = try await self.requestToken()
        try await self.writeEntries(entries, token: token)
      }
    }
  }

  func writeEntries(_ entries: [Log.Entry], token: Token) async throws {
    guard !entries.isEmpty else {
      throw EntriesWriteError.noEntriesToSend
    }
    guard !token.isExpired else {
      throw EntriesWriteError.tokenExpired(token)
    }

    guard let url = URL(string: "https://logging.googleapis.com/v2/entries:write") else {
      throw EntriesWriteError.noEntriesToSend
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601WithNanoseconds

      let entries: [Log.Entry] = entries.map {
        var entry = $0
        entry.logName = Log.name(projectId: self.serviceAccountCredentials.projectId, logId: $0.logName)
        return entry
      }

      request.httpBody = try encoder.encode(Log(
        resource: .global(projectId: self.serviceAccountCredentials.projectId),
        entries: entries))
    } catch {
      throw error
    }

    let (data, _) = try await self.session.data(for: request)
    if let responseError = try JSONDecoder().decode(Response.self, from: data).error {
      throw EntriesWriteError.errorReceived(responseError)
    }
  }
}

// MARK: - Errors

extension GoogleCloudLogging {

  // MARK: - Real errors

  enum InitError: Error {
    case wrongCredentialsType(Credentials)
  }

  enum TokenRequestError: Error {
    case invalidURL(String)
    case noDataReceived(URLResponse?)
    case errorReceived(Response.Error)
    case wrongTokenType(Token)
  }

  enum EntriesWriteError: Error {
    case noEntriesToSend
    case tokenExpired(Token)
    case noDataReceived(URLResponse?)
    case errorReceived(Response.Error)
  }
}
