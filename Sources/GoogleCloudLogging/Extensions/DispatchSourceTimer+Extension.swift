//
//  DispatchSourceTimer+Extension.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

extension DispatchSourceTimer {
  func schedule(delay: TimeInterval?, repeating: TimeInterval?) {
    schedule(
      deadline: delay.map { .now() + $0 } ?? .now(),
      repeating: repeating.map { .seconds(Int($0)) } ?? .never,
      leeway: repeating.map { .seconds(Int($0 / 2)) } ?? .nanoseconds(0))
  }
}
