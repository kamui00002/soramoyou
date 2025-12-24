//
//  RetryableOperation.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation

/// リトライ可能な操作を実行するヘルパー
struct RetryableOperation {
    /// リトライを実行（指数バックオフ）
    static func execute<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        operation: @escaping () async throws -> T,
        operationName: String? = nil
    ) async throws -> T {
        return try await ErrorHandler.retry(
            maxAttempts: maxAttempts,
            initialDelay: initialDelay,
            operation: operation,
            operationName: operationName
        )
    }
    
    /// リトライ可能な操作を実行（カスタム条件付き）
    static func executeIfRetryable<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        operation: @escaping () async throws -> T,
        operationName: String? = nil
    ) async throws -> T {
        let operationName = operationName ?? "unknown_operation"

        do {
            return try await operation()
        } catch {
            // リトライ可能なエラーの場合のみリトライ
            guard error.isRetryable else {
                throw error
            }

            // 最初の試行をカウントに含めるため、残りの試行回数を計算
            let remainingAttempts = max(1, maxAttempts - 1)

            return try await ErrorHandler.retry(
                maxAttempts: remainingAttempts,
                initialDelay: initialDelay,
                operation: operation,
                operationName: operationName
            )
        }
    }
}

