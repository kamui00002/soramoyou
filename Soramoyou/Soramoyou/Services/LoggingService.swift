//
//  LoggingService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import FirebaseCrashlytics
import FirebaseAnalytics
import os.log

/// ロギングとモニタリングサービス
class LoggingService: LoggingServiceProtocol {
    static let shared = LoggingService()
    
    private let logger = Logger(subsystem: "com.soramoyou", category: "LoggingService")
    
    private init() {}
    
    // MARK: - Crashlytics
    
    /// クラッシュレポートを記録
    func recordError(_ error: Error, context: String? = nil, userId: String? = nil) {
        // 機密情報を除外
        let sanitizedContext = sanitizeContext(context)
        
        // Crashlyticsにエラーを記録
        Crashlytics.crashlytics().record(error: error)
        
        // カスタムキーを設定
        if let context = sanitizedContext {
            Crashlytics.crashlytics().setCustomValue(context, forKey: "error_context")
        }
        
        if let userId = userId {
            Crashlytics.crashlytics().setUserID(userId)
        }
        
        // ログにも記録
        logger.error("Error recorded to Crashlytics: \(error.localizedDescription), context: \(sanitizedContext ?? "unknown")")
    }
    
    /// 非致命的なエラーを記録
    func recordNonFatalError(_ error: Error, context: String? = nil, userId: String? = nil) {
        // 機密情報を除外
        let sanitizedContext = sanitizeContext(context)
        
        // Crashlyticsに非致命的なエラーを記録
        let nsError = error as NSError
        Crashlytics.crashlytics().record(error: nsError)
        
        // カスタムキーを設定
        if let context = sanitizedContext {
            Crashlytics.crashlytics().setCustomValue(context, forKey: "error_context")
        }
        
        if let userId = userId {
            Crashlytics.crashlytics().setUserID(userId)
        }
        
        // ログにも記録
        logger.warning("Non-fatal error recorded to Crashlytics: \(error.localizedDescription), context: \(sanitizedContext ?? "unknown")")
    }
    
    /// カスタムログを記録
    func log(_ message: String, level: LogLevel = .info) {
        let sanitizedMessage = sanitizeMessage(message)
        
        switch level {
        case .debug:
            logger.debug("\(sanitizedMessage)")
        case .info:
            logger.info("\(sanitizedMessage)")
        case .warning:
            logger.warning("\(sanitizedMessage)")
            Crashlytics.crashlytics().log("WARNING: \(sanitizedMessage)")
        case .error:
            logger.error("\(sanitizedMessage)")
            Crashlytics.crashlytics().log("ERROR: \(sanitizedMessage)")
        }
    }
    
    // MARK: - Analytics
    
    /// イベントを記録
    func logEvent(_ name: String, parameters: [String: Any]? = nil) {
        // 機密情報を除外したパラメータを作成
        let sanitizedParameters = sanitizeParameters(parameters)
        
        // Firebase Analyticsにイベントを記録
        Analytics.logEvent(name, parameters: sanitizedParameters)
        
        // ログにも記録
        logger.info("Analytics event: \(name), parameters: \(sanitizedParameters?.description ?? "none")")
    }
    
    /// エラーイベントを記録
    func logErrorEvent(_ error: Error, context: String? = nil, category: ErrorCategory) {
        let sanitizedContext = sanitizeContext(context)
        
        var parameters: [String: Any] = [
            "error_category": category.rawValue,
            "error_description": error.localizedDescription
        ]
        
        if let context = sanitizedContext {
            parameters["error_context"] = context
        }
        
        // Firebase Analyticsにエラーイベントを記録
        logEvent("error_occurred", parameters: parameters)
    }
    
    /// リトライイベントを記録
    func logRetryEvent(operation: String, attempt: Int, success: Bool, error: Error? = nil) {
        var parameters: [String: Any] = [
            "operation": sanitizeContext(operation) ?? "unknown",
            "attempt": attempt,
            "success": success
        ]
        
        if let error = error {
            parameters["error_description"] = error.localizedDescription
        }
        
        // Firebase Analyticsにリトライイベントを記録
        logEvent("retry_operation", parameters: parameters)
    }
    
    /// ネットワークエラーのリトライ統計を記録
    func logNetworkRetryStats(operation: String, totalAttempts: Int, success: Bool) {
        var parameters: [String: Any] = [
            "operation": sanitizeContext(operation) ?? "unknown",
            "total_attempts": totalAttempts,
            "success": success
        ]
        
        // Firebase Analyticsにネットワークリトライ統計を記録
        logEvent("network_retry_stats", parameters: parameters)
    }
    
    // MARK: - User Properties
    
    /// ユーザープロパティを設定
    func setUserProperty(_ value: String?, forName name: String) {
        // 機密情報を除外
        let sanitizedValue = sanitizeValue(value)
        
        Analytics.setUserProperty(sanitizedValue, forName: name)
        
        // ログにも記録
        logger.info("User property set: \(name) = \(sanitizedValue ?? "nil")")
    }
    
    /// ユーザーIDを設定
    func setUserId(_ userId: String) {
        guard !userId.isEmpty else {
            Analytics.setUserID(nil)
            Crashlytics.crashlytics().setUserID(nil)
            return
        }

        Analytics.setUserID(userId)
        Crashlytics.crashlytics().setUserID(userId)

        // ログにも記録
        logger.info("User ID set: \(userId)")
    }
    
    // MARK: - Sanitization
    
    /// 機密情報を除外したコンテキストを返す
    private func sanitizeContext(_ context: String?) -> String? {
        guard let context = context else { return nil }
        
        // 機密情報のパターンを検出して除外
        var sanitized = context
        
        // メールアドレスを除外
        sanitized = sanitized.replacingOccurrences(
            of: #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#,
            with: "[EMAIL_REDACTED]",
            options: .regularExpression
        )
        
        // パスワードを除外
        sanitized = sanitized.replacingOccurrences(
            of: #"(?i)(password|passwd|pwd)\s*[:=]\s*[^\s]+"#,
            with: "[PASSWORD_REDACTED]",
            options: .regularExpression
        )
        
        // トークンを除外
        sanitized = sanitized.replacingOccurrences(
            of: #"(?i)(token|api[_-]?key|secret)\s*[:=]\s*[^\s]+"#,
            with: "[TOKEN_REDACTED]",
            options: .regularExpression
        )
        
        return sanitized
    }
    
    /// 機密情報を除外したメッセージを返す
    private func sanitizeMessage(_ message: String) -> String {
        return sanitizeContext(message) ?? message
    }
    
    /// 機密情報を除外したパラメータを返す
    private func sanitizeParameters(_ parameters: [String: Any]?) -> [String: Any]? {
        guard let parameters = parameters else { return nil }
        
        var sanitized: [String: Any] = [:]
        
        for (key, value) in parameters {
            // 機密情報のキーを検出
            let lowerKey = key.lowercased()
            if lowerKey.contains("password") ||
               lowerKey.contains("token") ||
               lowerKey.contains("secret") ||
               lowerKey.contains("api_key") ||
               lowerKey.contains("auth") {
                sanitized[key] = "[REDACTED]"
            } else if let stringValue = value as? String {
                sanitized[key] = sanitizeContext(stringValue) ?? stringValue
            } else {
                sanitized[key] = value
            }
        }
        
        return sanitized
    }
    
    /// 機密情報を除外した値を返す
    private func sanitizeValue(_ value: String?) -> String? {
        return sanitizeContext(value)
    }
}

// MARK: - LogLevel

enum LogLevel {
    case debug
    case info
    case warning
    case error
}

// MARK: - ErrorCategory Extension

extension ErrorCategory {
    var rawValue: String {
        switch self {
        case .userError:
            return "user_error"
        case .systemError:
            return "system_error"
        case .businessError:
            return "business_error"
        }
    }
}


