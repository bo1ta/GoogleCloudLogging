//
//  Dictionary+Extension.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

extension Dictionary {
  mutating func update(with other: [Key: Value]) -> [Key: Value] {
    var replaced = [Key: Value]()
    self = other.reduce(into: self) { replaced[$1.key] = $0.updateValue($1.value, forKey: $1.key) }
    return replaced
  }
}
