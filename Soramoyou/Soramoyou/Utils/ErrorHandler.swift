//
//  ErrorHandler.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import os.log

/// エラーのカテゴリ
enum ErrorCategory {
    case userError      // 4xx: ユーザーエラー（入力検証、認証、権限）
    case systemError    // 5xx: システムエラー（ネットワーク、サービス、画像処理）
    case businessError  // 422: ビジネスロジックエラー（制限違反、状態違反）
}

/// エラーの分類と処理を行う統一的なエラーハンドラー
struct ErrorHandler {
    private static let logger = Logger(subsystem: "com.soramoyou", category: "ErrorHandler")
    
    /// エラーを分類
    static func categorize(_ error: Error) -> ErrorCategory {
        // AuthError: ユーザーエラー
        if error is AuthError {
            return .userError
        }
        
        // FirestoreServiceError: システムエラーまたはユーザーエラー
        if let firestoreError = error as? FirestoreServiceError {
            switch firestoreError {
            case .notFound:
                return .userError
            default:
                return .systemError
            }
        }
        
        // StorageServiceError: システムエラー
        if error is StorageServiceError {
            return .systemError
        }
        
        // ImageServiceError: システムエラー
        if error is ImageServiceError {
            return .systemError
        }
        
        // PostViewModelError: ビジネスロジックエラーまたはユーザーエラー
        if let postError = error as? PostViewModelError {
            switch postError {
            case .userNotAuthenticated, .noImages:
                return .userError
            case .imageCompressionFailed, .uploadFailed, .saveFailed:
                return .systemError
            }
        }
        
        // EditViewModelError: ユーザーエラーまたはシステムエラー
        if let editError = error as? EditViewModelError {
            switch editError {
            case .noImage, .toolNotEquipped:
                return .userError
            case .previewGenerationFailed:
                return .systemError
            }
        }
        
        // LocationServiceError: システムエラー
        if error is LocationServiceError {
            return .systemError
        }
        
        // PhotoSelectionError: ユーザーエラー
        if error is PhotoSelectionError {
            return .userError
        }
        
        // NSError: ネットワークエラーなど
        if let nsError = error as NSError? {
            // ネットワークエラー
            if nsError.domain == NSURLErrorDomain {
                return .systemError
            }
            // その他のシステムエラー
            return .systemError
        }
        
        // デフォルト: システムエラー
        return .systemError
    }
    
    /// エラーメッセージを取得（ユーザーフレンドリー）
    static func getUserFriendlyMessage(_ error: Error) -> String {
        // LocalizedErrorを実装しているエラーは、errorDescriptionを使用
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        
        // NSErrorの場合
        if let nsError = error as NSError? {
            // ネットワークエラー
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet:
                    return "インターネットに接続されていません"
                case NSURLErrorTimedOut:
                    return "接続がタイムアウトしました"
                case NSURLErrorNetworkConnectionLost:
                    return "ネットワーク接続が失われました"
                default:
                    return "ネットワークエラーが発生しました"
                }
            }
            
            // その他のNSError
            return nsError.localizedDescription
        }
        
        // デフォルトメッセージ
        return "エラーが発生しました。もう一度お試しください。"
    }
    
    /// エラーをログに記録
    static func logError(_ error: Error, context: String? = nil, userId: String? = nil) {
        let category = categorize(error)
        let message = getUserFriendlyMessage(error)
        
        let logMessage = """
        Error occurred
        Category: \(category)
        Context: \(context ?? "Unknown")
        User ID: \(userId ?? "Unknown")
        Message: \(message)
        Error: \(error.localizedDescription)
        """
        
        switch category {
        case .userError:
            logger.info("\(logMessage)")
        case .systemError:
            logger.error("\(logMessage)")
            // Crashlyticsにシステムエラーを記録
            LoggingService.shared.recordError(error, context: context, userId: userId)
        case .businessError:
            logger.warning("\(logMessage)")
            // Crashlyticsにビジネスロジックエラーを記録（非致命的）
            LoggingService.shared.recordNonFatalError(error, context: context, userId: userId)
        }
        
        // Firebase Analyticsにエラーイベントを記録
        LoggingService.shared.logErrorEvent(error, context: context, category: category)
    }
    
    /// リトライ可能かどうかを判定
    static func isRetryable(_ error: Error) -> Bool {
        let category = categorize(error)
        
        // システムエラーのみリトライ可能
        guard category == .systemError else {
            return false
        }
        
        // NSErrorの場合
        if let nsError = error as NSError? {
            // ネットワークエラーはリトライ可能
            if nsError.domain == NSURLErrorDomain {
                return true
            }
        }
        
        // FirestoreServiceError、StorageServiceError、ImageServiceErrorはリトライ可能
        if error is FirestoreServiceError || 
           error is StorageServiceError || 
           error is ImageServiceError {
            return true
        }
        
        return false
    }
    
    /// リトライを実行（指数バックオフ）
    static func retry<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        operation: @escaping () async throws -> T,
        operationName: String? = nil
    ) async throws -> T {
        var lastError: Error?
        var delay = initialDelay
        let operationName = operationName ?? "unknown_operation"
        
        for attempt in 1...maxAttempts {
            do {
                let result = try await operation()
                
                // 成功した場合、リトライ統計を記録
                if attempt > 1 {
                    LoggingService.shared.logRetryEvent(
                        operation: operationName,
                        attempt: attempt,
                        success: true
                    )
                }
                
                return result
            } catch {
                lastError = error
                
                // リトライ不可能なエラーの場合は即座にthrow
                guard isRetryable(error) else {
                    // リトライ不可能なエラーの場合も統計を記録
                    LoggingService.shared.logRetryEvent(
                        operation: operationName,
                        attempt: attempt,
                        success: false,
                        error: error
                    )
                    throw error
                }
                
                // 最後の試行の場合はエラーをthrow
                guard attempt < maxAttempts else {
                    // すべての試行が失敗した場合、リトライ統計を記録
                    LoggingService.shared.logNetworkRetryStats(
                        operation: operationName,
                        totalAttempts: maxAttempts,
                        success: false
                    )
                    break
                }
                
                // リトライイベントを記録
                LoggingService.shared.logRetryEvent(
                    operation: operationName,
                    attempt: attempt,
                    success: false,
                    error: error
                )
                
                // 指数バックオフで待機
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 2 // 指数バックオフ
                
                logger.info("Retrying operation (attempt \(attempt + 1)/\(maxAttempts))")
            }
        }
        
        // すべての試行が失敗した場合
        if let lastError = lastError {
            throw lastError
        }
        
        throw NSError(domain: "ErrorHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "リトライに失敗しました"])
    }
}

/// エラー表示用の拡張
extension Error {
    /// エラーのカテゴリを取得
    var category: ErrorCategory {
        return ErrorHandler.categorize(self)
    }

    /// ユーザーフレンドリーなメッセージを取得
    var userFriendlyMessage: String {
        return ErrorHandler.getUserFriendlyMessage(self)
    }

    /// リトライ可能かどうかを判定
    var isRetryable: Bool {
        return ErrorHandler.isRetryable(self)
    }
}

// MARK: - ViewModel Error Handling Protocol

/// ViewModelで共通のエラーハンドリングを提供するプロトコル
protocol ErrorHandling: AnyObject {
    var errorMessage: String? { get set }
}

extension ErrorHandling {
    /// エラーを処理し、ユーザーフレンドリーなメッセージを設定する
    /// - Parameters:
    ///   - error: 発生したエラー
    ///   - context: エラーコンテキスト（ログ用）
    ///   - userId: ユーザーID（ログ用）
    @MainActor
    func handleError(_ error: Error, context: String, userId: String? = nil) {
        ErrorHandler.logError(error, context: context, userId: userId)
        errorMessage = error.userFriendlyMessage
    }

    /// エラーをクリアする
    @MainActor
    func clearError() {
        errorMessage = nil
    }
}

// MARK: - Async Error Handling

extension ErrorHandling {
    /// 非同期操作を実行し、エラーを自動的に処理する
    /// - Parameters:
    ///   - context: エラーコンテキスト（ログ用）
    ///   - userId: ユーザーID（ログ用）
    ///   - operation: 実行する非同期操作
    /// - Returns: 操作の結果。エラー時はnil
    @MainActor
    func withErrorHandling<T>(
        context: String,
        userId: String? = nil,
        operation: () async throws -> T
    ) async -> T? {
        do {
            return try await operation()
        } catch {
            handleError(error, context: context, userId: userId)
            return nil
        }
    }

    /// 非同期操作を実行し、エラーを再スローする
    /// - Parameters:
    ///   - context: エラーコンテキスト（ログ用）
    ///   - userId: ユーザーID（ログ用）
    ///   - operation: 実行する非同期操作
    /// - Returns: 操作の結果
    /// - Throws: 操作からのエラー
    @MainActor
    func withErrorHandlingRethrow<T>(
        context: String,
        userId: String? = nil,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            handleError(error, context: context, userId: userId)
            throw error
        }
    }
}

