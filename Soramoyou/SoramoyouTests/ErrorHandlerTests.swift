//
//  ErrorHandlerTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-24.
//

import XCTest
@testable import Soramoyou

final class ErrorHandlerTests: XCTestCase {
    var mockLoggingService: MockLoggingService!

    override func setUp() {
        super.setUp()
        mockLoggingService = MockLoggingService()
        ErrorHandler.loggingService = mockLoggingService
    }

    override func tearDown() {
        // デフォルトに戻す
        ErrorHandler.loggingService = LoggingService.shared
        mockLoggingService = nil
        super.tearDown()
    }

    // MARK: - Error Categorization Tests

    func testCategorize_authError_returnsUserError() {
        // Given
        let error = AuthError.invalidEmail

        // When
        let category = ErrorHandler.categorize(error)

        // Then
        XCTAssertEqual(category, .userError)
    }

    func testCategorize_firestoreNotFoundError_returnsUserError() {
        // Given
        let error = FirestoreServiceError.notFound

        // When
        let category = ErrorHandler.categorize(error)

        // Then
        XCTAssertEqual(category, .userError)
    }

    func testCategorize_firestoreOtherError_returnsSystemError() {
        // Given
        let error = FirestoreServiceError.fetchFailed(NSError(domain: "test", code: -1))

        // When
        let category = ErrorHandler.categorize(error)

        // Then
        XCTAssertEqual(category, .systemError)
    }

    func testCategorize_storageError_returnsSystemError() {
        // Given
        let error = StorageServiceError.uploadFailed(NSError(domain: "test", code: -1))

        // When
        let category = ErrorHandler.categorize(error)

        // Then
        XCTAssertEqual(category, .systemError)
    }

    func testCategorize_imageServiceError_returnsSystemError() {
        // Given
        let error = ImageServiceError.processingFailed

        // When
        let category = ErrorHandler.categorize(error)

        // Then
        XCTAssertEqual(category, .systemError)
    }

    func testCategorize_postViewModelUserError_returnsUserError() {
        // Given
        let error = PostViewModelError.userNotAuthenticated

        // When
        let category = ErrorHandler.categorize(error)

        // Then
        XCTAssertEqual(category, .userError)
    }

    func testCategorize_postViewModelSystemError_returnsSystemError() {
        // Given
        let error = PostViewModelError.uploadFailed

        // When
        let category = ErrorHandler.categorize(error)

        // Then
        XCTAssertEqual(category, .systemError)
    }

    func testCategorize_networkError_returnsSystemError() {
        // Given
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

        // When
        let category = ErrorHandler.categorize(error)

        // Then
        XCTAssertEqual(category, .systemError)
    }

    // MARK: - User Friendly Message Tests

    func testGetUserFriendlyMessage_authError_returnsLocalizedMessage() {
        // Given
        let error = AuthError.invalidEmail

        // When
        let message = ErrorHandler.getUserFriendlyMessage(error)

        // Then
        XCTAssertEqual(message, "有効なメールアドレスを入力してください")
    }

    func testGetUserFriendlyMessage_networkError_returnsAppropriateMessage() {
        // Given
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

        // When
        let message = ErrorHandler.getUserFriendlyMessage(error)

        // Then
        XCTAssertEqual(message, "インターネットに接続されていません")
    }

    func testGetUserFriendlyMessage_unknownError_returnsDefaultMessage() {
        // Given
        let error = NSError(domain: "unknown", code: -999)

        // When
        let message = ErrorHandler.getUserFriendlyMessage(error)

        // Then
        XCTAssertTrue(message.contains("エラーが発生しました"))
    }

    // MARK: - Retryable Tests

    func testIsRetryable_networkError_returnsTrue() {
        // Given
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        // When
        let isRetryable = ErrorHandler.isRetryable(error)

        // Then
        XCTAssertTrue(isRetryable)
    }

    func testIsRetryable_firestoreError_returnsTrue() {
        // Given
        let error = FirestoreServiceError.fetchFailed(NSError(domain: "test", code: -1))

        // When
        let isRetryable = ErrorHandler.isRetryable(error)

        // Then
        XCTAssertTrue(isRetryable)
    }

    func testIsRetryable_storageError_returnsTrue() {
        // Given
        let error = StorageServiceError.uploadFailed(NSError(domain: "test", code: -1))

        // When
        let isRetryable = ErrorHandler.isRetryable(error)

        // Then
        XCTAssertTrue(isRetryable)
    }

    func testIsRetryable_imageServiceError_returnsTrue() {
        // Given
        let error = ImageServiceError.processingFailed

        // When
        let isRetryable = ErrorHandler.isRetryable(error)

        // Then
        XCTAssertTrue(isRetryable)
    }

    func testIsRetryable_userError_returnsFalse() {
        // Given
        let error = AuthError.invalidEmail

        // When
        let isRetryable = ErrorHandler.isRetryable(error)

        // Then
        XCTAssertFalse(isRetryable)
    }

    func testIsRetryable_businessError_returnsFalse() {
        // Given
        let error = PostViewModelError.userNotAuthenticated

        // When
        let isRetryable = ErrorHandler.isRetryable(error)

        // Then
        XCTAssertFalse(isRetryable)
    }

    // MARK: - Log Error Tests

    func testLogError_systemError_callsLoggingService() {
        // Given
        let error = ImageServiceError.processingFailed
        let context = "test_context"
        let userId = "user123"

        // When
        ErrorHandler.logError(error, context: context, userId: userId)

        // Then
        XCTAssertTrue(mockLoggingService.recordErrorCalled)
        XCTAssertTrue(mockLoggingService.logErrorEventCalled)
    }

    func testLogError_businessError_callsNonFatalError() {
        // Given - ビジネスエラーを作るためにEditViewModelErrorを使用
        let error = EditViewModelError.noImage

        // When
        ErrorHandler.logError(error, context: "test", userId: "user123")

        // Then
        // EditViewModelError.noImageはuserErrorなので、recordErrorは呼ばれない
        XCTAssertFalse(mockLoggingService.recordErrorCalled)
        XCTAssertTrue(mockLoggingService.logErrorEventCalled)
    }

    // MARK: - Retry Tests

    func testRetry_successOnFirstAttempt_returnsImmediately() async {
        // Given
        var callCount = 0
        let operation = {
            callCount += 1
            return "success"
        }

        // When
        let result = try? await ErrorHandler.retry(
            maxAttempts: 3,
            initialDelay: 0.01,
            operation: operation,
            operationName: "test_operation"
        )

        // Then
        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(mockLoggingService.logRetryEventCalled) // 1回目の成功ではログされない
    }

    func testRetry_successOnSecondAttempt_logsRetry() async {
        // Given
        var callCount = 0
        let operation = {
            callCount += 1
            if callCount == 1 {
                throw ImageServiceError.processingFailed
            }
            return "success"
        }

        // When
        let result = try? await ErrorHandler.retry(
            maxAttempts: 3,
            initialDelay: 0.01,
            operation: operation,
            operationName: "test_operation"
        )

        // Then
        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 2)
        XCTAssertTrue(mockLoggingService.logRetryEventCalled)
    }

    func testRetry_failsAllAttempts_throwsLastError() async {
        // Given
        var callCount = 0
        let operation: () throws -> String = {
            callCount += 1
            throw ImageServiceError.processingFailed
        }

        // When/Then
        do {
            _ = try await ErrorHandler.retry(
                maxAttempts: 3,
                initialDelay: 0.01,
                operation: operation,
                operationName: "test_operation"
            )
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(callCount, 3)
            XCTAssertTrue(mockLoggingService.logNetworkRetryStatsCalled)
        }
    }

    func testRetry_nonRetryableError_throwsImmediately() async {
        // Given
        var callCount = 0
        let operation: () throws -> String = {
            callCount += 1
            throw AuthError.invalidEmail // ユーザーエラー（リトライ不可）
        }

        // When/Then
        do {
            _ = try await ErrorHandler.retry(
                maxAttempts: 3,
                initialDelay: 0.01,
                operation: operation,
                operationName: "test_operation"
            )
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(callCount, 1) // リトライされない
            XCTAssertTrue(mockLoggingService.logRetryEventCalled)
        }
    }

    // MARK: - Error Extension Tests

    func testErrorExtension_category_returnsCorrectCategory() {
        // Given
        let error: Error = AuthError.invalidEmail

        // When
        let category = error.category

        // Then
        XCTAssertEqual(category, .userError)
    }

    func testErrorExtension_userFriendlyMessage_returnsMessage() {
        // Given
        let error: Error = AuthError.invalidEmail

        // When
        let message = error.userFriendlyMessage

        // Then
        XCTAssertEqual(message, "有効なメールアドレスを入力してください")
    }

    func testErrorExtension_isRetryable_returnsCorrectValue() {
        // Given
        let retryableError: Error = ImageServiceError.processingFailed
        let nonRetryableError: Error = AuthError.invalidEmail

        // When/Then
        XCTAssertTrue(retryableError.isRetryable)
        XCTAssertFalse(nonRetryableError.isRetryable)
    }
}

// MARK: - Mock Logging Service

class MockLoggingService: LoggingServiceProtocol {
    var recordErrorCalled = false
    var recordNonFatalErrorCalled = false
    var logErrorEventCalled = false
    var logRetryEventCalled = false
    var logNetworkRetryStatsCalled = false

    func recordError(_ error: Error, context: String?, userId: String?) {
        recordErrorCalled = true
    }

    func recordNonFatalError(_ error: Error, context: String?, userId: String?) {
        recordNonFatalErrorCalled = true
    }

    func log(_ message: String, level: LogLevel) {
        // No-op
    }

    func logEvent(_ name: String, parameters: [String: Any]?) {
        // No-op
    }

    func logErrorEvent(_ error: Error, context: String?, category: ErrorCategory) {
        logErrorEventCalled = true
    }

    func logRetryEvent(operation: String, attempt: Int, success: Bool, error: Error?) {
        logRetryEventCalled = true
    }

    func logNetworkRetryStats(operation: String, totalAttempts: Int, success: Bool) {
        logNetworkRetryStatsCalled = true
    }

    func setUserId(_ userId: String) {
        // No-op
    }

    func setUserProperty(_ value: String, forName: String) {
        // No-op
    }
}
