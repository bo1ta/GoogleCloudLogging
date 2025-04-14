//
//  LogEngineRegistry.swift
//  GoogleCloudLogging
//
//  Created by Alexandru Solomon on 14.04.2025.
//

import Foundation

public enum LogEngineRegistry {
  private static let lock = NSLock()

  /// The stored engine instance. Defaults to the shared LogEngine.
  private nonisolated(unsafe) static var currentEngine: LogEngineProvider = LogEngine.shared

  /// Registers a custom LogEngineProvider implementation.
  /// Call this *before* `LoggingSystem.bootstrap` if you want to override the default engine.
  /// - Parameter engine: The LogEngineProvider instance to use.
  public nonisolated(unsafe) static func register(engine: LogEngineProvider) {
    lock.withLock {
      currentEngine = engine
    }
  }

  /// Retrieves the currently registered LogEngineProvider.
  internal static func getEngine() -> LogEngineProvider {
    lock.withLock {
      currentEngine
    }
  }

  /// Resets the engine back to the default shared instance (useful for testing).
  public static func resetToDefault() {
    lock.withLock {
      currentEngine = LogEngine.shared
    }
  }
}
