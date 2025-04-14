//
//  Referenced.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

@propertyWrapper
class Referenced<T> {
  var wrappedValue: T?
}
