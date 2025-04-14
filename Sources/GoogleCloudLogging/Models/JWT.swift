//
//  JWT.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

enum JWT {
  enum KeyError: Error {
    case unableToDecode(from: String)
  }

  enum SignError: Error {
    case unableToSign
  }

  struct Header: Encodable {
    enum CodingKeys: String, CodingKey {
      case type = "typ"
      case algorithm = "alg"
    }

    let type: String
    let algorithm: String
  }

  struct Payload: Encodable {
    enum CodingKeys: String, CodingKey {
      case issuer = "iss"
      case audience = "aud"
      case expiration = "exp"
      case issuedAt = "iat"
      case scope
    }

    let issuer: String
    let audience: String
    let expiration: Int
    let issuedAt: Int
    let scope: String
  }

  static func create(using credentials: Credentials, for scopes: [Scope]) throws -> String {
    let header = Header(type: "JWT", algorithm: "RS256")
    let now = Date()
    let payload = Payload(
      issuer: credentials.clientEmail,
      audience: credentials.tokenURI,
      expiration: Int(now.addingTimeInterval(3600).timeIntervalSince1970),
      issuedAt: Int(now.timeIntervalSince1970),
      scope: scopes.map(\.rawValue).joined(separator: " "))
    let encoder = JSONEncoder()
    let encodedHeader = try encoder.encode(header).base64URLEncodedString()
    let encodedPayload = try encoder.encode(payload).base64URLEncodedString()
    let privateKey = try key(from: credentials.privateKey)
    let signature = try sign(Data("\(encodedHeader).\(encodedPayload)".utf8), with: privateKey)
    let encodedSignature = signature.base64URLEncodedString()
    return "\(encodedHeader).\(encodedPayload).\(encodedSignature)"
  }

  static func key(from pem: String) throws -> Data {
    let unwrappedPEM = pem.split(separator: "\n").filter { !$0.contains("PRIVATE KEY") }.joined()
    let headerLength = 26
    guard let der = Data(base64Encoded: unwrappedPEM), der.count > headerLength else { throw KeyError.unableToDecode(from: pem) }
    return der[headerLength...]
  }

  static func sign(_ data: Data, with key: Data) throws -> Data {
    var error: Unmanaged<CFError>?
    let attributes = [
      kSecAttrKeyType: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate,
      kSecAttrKeySizeInBits: 256,
    ] as CFDictionary
    guard let privateKey = SecKeyCreateWithData(key as CFData, attributes, &error) else {
      throw error?.takeRetainedValue() as? Error ?? SignError.unableToSign
    }
    guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) as Data?
    else {
      throw error?.takeRetainedValue() as? Error ?? SignError.unableToSign
    }
    return signature
  }
}
