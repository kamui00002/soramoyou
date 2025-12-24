//
//  RetryableOperationTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-24.
//

import XCTest
@testable import Soramoyou

final class RetryableOperationTests: XCTestCase {
    var mockLoggingService: MockLoggingService!

    override func setUp() {
        super.setUp()
        mockLoggingService = MockLoggingService()
        ErrorHandler.loggingService = mockLoggingService
    }

    override func tearDown() {
        ErrorHandler.loggingService = LoggingService.shared
        mockLoggingService = nil
        super.tearDown()
    }

    // MARK: - execute Tests

    func testExecute_successOnFirstAttempt_returnsResult() async {
        // Given
        var callCount = 0
        let operation = {
            callCount += 1
            return "success"
        }

        // When
        let result = try? await RetryableOperation.execute(
            maxAttempts: 3,
            initialDelay: 0.01,
            operation: operation,
            operationName: "test_operation"
        )

        // Then
        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 1)
    }

    func testExecute_failsAllAttempts_throwsError() async {
        // Given
        var callCount = 0
        let operation: () throws -> String = {
            callCount += 1
            throw ImageServiceError.processingFailed
        }

        // When/Then
        do {
            _ = try await RetryableOperation.execute(
                maxAttempts: 3,
                initialDelay: 0.01,
                operation: operation,
                operationName: "test_operation"
            )
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(callCount, 3)
        }
    }

    // MARK: - executeIfRetryable Tests

    func testExecuteIfRetryable_retryableError_retriesOperation() async {
        // Given
        var callCount = 0
        let operation = {
            callCount += 1
            if callCount == 1 {
                throw ImageServiceError.processingFailed // リトライ可能
            }
            return "success"
        }

        // When
        let result = try? await RetryableOperation.executeIfRetryable(
            maxAttempts: 3,
            initialDelay: 0.01,
            operation: operation,
            operationName: "test_operation"
        )

        // Then
        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 2) // 1回失敗、2回目成功
    }

    func testExecuteIfRetryable_nonRetryableError_throwsImmediately() async {
        // Given
        var callCount = 0
        let operation: () throws -> String = {
            callCount += 1
            throw AuthError.invalidEmail // リトライ不可
        }

        // When/Then
        do {
            _ = try await RetryableOperation.executeIfRetryable(
                maxAttempts: 3,
                initialDelay: 0.01,
                operation: operation,
                operationName: "test_operation"
            )
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(callCount, 1) // リトライされない
        }
    }

    func testExecuteIfRetryable_successOnFirstAttempt_noRetry() async {
        // Given
        var callCount = 0
        let operation = {
            callCount += 1
            return "success"
        }

        // When
        let result = try? await RetryableOperation.executeIfRetryable(
            maxAttempts: 3,
            initialDelay: 0.01,
            operation: operation,
            operationName: "test_operation"
        )

        // Then
        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 1)
    }

    func testExecuteIfRetryable_retryCountCorrect() async {
        // Given
        var callCount = 0
        let operation: () throws -> String = {
            callCount += 1
            throw ImageServiceError.processingFailed
        }

        // When
        do {
            _ = try await RetryableOperation.executeIfRetryable(
                maxAttempts: 3,
                initialDelay: 0.01,
                operation: operation,
                operationName: "test_operation"
            )
            XCTFail("Expected error to be thrown")
        } catch {
            // Then
            // 最初の試行(1回) + 残りのリトライ(maxAttempts - 1 = 2回) = 合計3回
            XCTAssertEqual(callCount, 3)
        }
    }

    // MARK: - Integration Tests

    func testExecuteIfRetryable_withNetworkError_retriesCorrectly() async {
        // Given
        var callCount = 0
        let operation = {
            callCount += 1
            if callCount < 3 {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            }
            return "success"
        }

        // When
        let result = try? await RetryableOperation.executeIfRetryable(
            maxAttempts: 3,
            initialDelay: 0.01,
            operation: operation,
            operationName: "network_operation"
        )

        // Then
        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 3)
    }

    func testExecuteIfRetryable_withStorageError_retriesCorrectly() async {
        // Given
        var callCount = 0
        let operation = {
            callCount += 1
            if callCount == 1 {
                throw StorageServiceError.uploadFailed(NSError(domain: "test", code: -1))
            }
            return "uploaded"
        }

        // When
        let result = try? await RetryableOperation.executeIfRetryable(
            maxAttempts: 3,
            initialDelay: 0.01,
            operation: operation,
            operationName: "storage_upload"
        )

        // Then
        XCTAssertEqual(result, "uploaded")
        XCTAssertEqual(callCount, 2)
    }
}
