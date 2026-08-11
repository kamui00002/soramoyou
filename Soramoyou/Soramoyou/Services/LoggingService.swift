//
//  LoggingService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import FirebaseAnalytics
import FirebaseCrashlytics
import Foundation
import os.log
import PostHog

/// ロギングとモニタリングサービス
class LoggingService {
    static let shared = LoggingService()

    private let logger = Logger(subsystem: "com.soramoyou", category: "LoggingService")

    /// 直前に PostHog へ identify 済みのユーザーID（nil = 匿名）。
    /// reset() は「identify 済み → 匿名」への実遷移でのみ呼ぶ必要があるため保持する。
    private var lastIdentifiedUserID: String?

    private init() {}

    // MARK: - PostHog セットアップ

    /// PostHog の Project API key。これは「クライアント公開キー」であり、
    /// アプリのバイナリに埋め込まれる前提の値。秘匿キーではないのでリポジトリに置いてよい。
    private static let postHogAPIKey = "phc_ygTnSrCc4AEp6G9m4hD8VLadRGjPPF7w4nYDBMMjX8LL"
    private static let postHogHost = "https://us.i.posthog.com"

    /// PostHog SDK を初期化する（アプリ起動時に一度だけ呼ぶ）
    /// - Note: Firebase Analytics と二重に送るのではなく、`logEvent` ファサード1本から
    ///         両方へ流す設計にしている（グローバルルールの原則2: ファサードは1つ）。
    func configurePostHog() {
        let config = PostHogConfig(projectToken: Self.postHogAPIKey, host: Self.postHogHost)
        // 画面の自動計測は SwiftUI では画面名が取れない（全て
        // PresentationHostingController<AnyView> になる）ため無効化し、
        // 必要な画面では logScreen(_:) を明示的に呼ぶ方針にする。
        config.captureScreenViews = false
        PostHogSDK.shared.setup(config)
    }

    /// 画面表示を計測する（SwiftUI の自動計測が使えないため手動で呼ぶ）
    /// - Parameter name: PostHog 上に出す画面名。日本語で構わない（例: "ホーム"）
    func logScreen(_ name: String) {
        PostHogSDK.shared.screen(name)
        logger.info("Screen: \(name)")
    }

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

        if let userId {
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

        if let userId {
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

        // PostHog にも同じイベントを記録（サニタイズ済みパラメータを流用するので PII は入らない）
        PostHogSDK.shared.capture(name, properties: sanitizedParameters)

        // ログにも記録
        logger.info("Analytics event: \(name), parameters: \(sanitizedParameters?.description ?? "none")")
    }

    /// エラーイベントを記録
    func logErrorEvent(_ error: Error, context: String? = nil, category: ErrorCategory) {
        let sanitizedContext = sanitizeContext(context)

        // エラー説明にPIIが含まれる可能性があるためサニタイズ
        let sanitizedErrorDescription = sanitizeContext(error.localizedDescription) ?? "Unknown error"

        var parameters: [String: Any] = [
            "error_category": category.rawValue,
            "error_description": sanitizedErrorDescription,
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
            "success": success,
        ]

        if let error {
            // エラー説明にPIIが含まれる可能性があるためサニタイズ
            parameters["error_description"] = sanitizeContext(error.localizedDescription) ?? "Unknown error"
        }

        // Firebase Analyticsにリトライイベントを記録
        logEvent("retry_operation", parameters: parameters)
    }

    /// ネットワークエラーのリトライ統計を記録
    func logNetworkRetryStats(operation: String, totalAttempts: Int, success: Bool) {
        var parameters: [String: Any] = [
            "operation": sanitizeContext(operation) ?? "unknown",
            "total_attempts": totalAttempts,
            "success": success,
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

        // PostHog にも反映（super property = 以降の全イベントに自動で付く属性）
        if let sanitizedValue {
            PostHogSDK.shared.register([name: sanitizedValue])
        }

        // ログにも記録
        logger.info("User property set: \(name) = \(sanitizedValue ?? "nil")")
    }

    /// ユーザーIDを設定
    func setUserID(_ userID: String?) {
        // ユーザーIDは機密情報ではないが、念のため検証
        guard let userID, !userID.isEmpty else {
            Analytics.setUserID(nil)
            Crashlytics.crashlytics().setUserID(nil)

            // PostHog の reset() は「identify 済み → 匿名」への実遷移（本当のログアウト）でのみ呼ぶ。
            // 起動直後など元から匿名の状態で呼ぶと distinct_id が無駄に作り直され、
            // 同じ人が別人としてカウントされてしまうため。
            if lastIdentifiedUserID != nil {
                PostHogSDK.shared.reset()
                lastIdentifiedUserID = nil
            }
            return
        }

        Analytics.setUserID(userID)
        Crashlytics.crashlytics().setUserID(userID)

        // PostHog でも内部 UID のみで識別する（email / displayName は絶対に渡さない）
        PostHogSDK.shared.identify(userID)
        lastIdentifiedUserID = userID

        // ログにも記録（userID は個人情報なので privacy: .private で第三者には <private> 表示にする）
        logger.info("User ID set: \(userID, privacy: .private)")
    }

    // MARK: - Sanitization

    /// 機密情報を除外したコンテキストを返す
    private func sanitizeContext(_ context: String?) -> String? {
        guard let context else { return nil }

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
        sanitizeContext(message) ?? message
    }

    /// 機密情報を除外したパラメータを返す
    private func sanitizeParameters(_ parameters: [String: Any]?) -> [String: Any]? {
        guard let parameters else { return nil }

        var sanitized: [String: Any] = [:]

        for (key, value) in parameters {
            // 機密情報のキーを検出
            let lowerKey = key.lowercased()
            if lowerKey.contains("password") ||
                lowerKey.contains("token") ||
                lowerKey.contains("secret") ||
                lowerKey.contains("api_key") ||
                lowerKey.contains("auth")
            {
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
        sanitizeContext(value)
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
            "user_error"
        case .systemError:
            "system_error"
        case .businessError:
            "business_error"
        }
    }
}
