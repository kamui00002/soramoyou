//
//  LoggingServiceProtocol.swift
//  Soramoyou
//
//  Created on 2025-12-24.
//

import Foundation

/// ロギングサービスのプロトコル（DI用）
protocol LoggingServiceProtocol {
    // MARK: - Crashlytics
    func recordError(_ error: Error, context: String?, userId: String?)
    func recordNonFatalError(_ error: Error, context: String?, userId: String?)
    func log(_ message: String, level: LogLevel)

    // MARK: - Analytics
    func logEvent(_ name: String, parameters: [String: Any]?)
    func logErrorEvent(_ error: Error, context: String?, category: ErrorCategory)
    func logRetryEvent(operation: String, attempt: Int, success: Bool, error: Error?)
    func logNetworkRetryStats(operation: String, totalAttempts: Int, success: Bool)

    // MARK: - User Tracking
    func setUserId(_ userId: String)
    func setUserProperty(_ value: String, forName: String)
}
