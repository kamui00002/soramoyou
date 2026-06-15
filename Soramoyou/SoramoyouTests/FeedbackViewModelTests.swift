//
//  FeedbackViewModelTests.swift
//  SoramoyouTests
//
//  フィードバック送信 ViewModel の検証
//

import XCTest
@testable import Soramoyou

@MainActor
final class FeedbackViewModelTests: XCTestCase {

    /// 正常系: 本文と種別を載せて送信し、didSubmit が立つ
    func testSubmitSendsFeedbackAndSetsDidSubmit() async {
        let firestore = MockFirestoreServiceForFeedback()
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1")
        let viewModel = FeedbackViewModel(firestoreService: firestore, authService: auth)
        viewModel.message = "  空の色が綺麗でした  "
        viewModel.category = .request

        let success = await viewModel.submit()

        XCTAssertTrue(success)
        XCTAssertTrue(viewModel.didSubmit)
        XCTAssertEqual(firestore.captured?.userId, "u1")
        XCTAssertEqual(firestore.captured?.message, "空の色が綺麗でした")  // 前後空白はトリム
        XCTAssertEqual(firestore.captured?.category, "request")
    }

    /// 未ログインでは送信できない
    func testSubmitFailsWhenNotAuthenticated() async {
        let firestore = MockFirestoreServiceForFeedback()
        let auth = MockAuthService()
        auth.currentUserValue = nil
        let viewModel = FeedbackViewModel(firestoreService: firestore, authService: auth)
        viewModel.message = "送れないはず"

        let success = await viewModel.submit()

        XCTAssertFalse(success)
        XCTAssertNil(firestore.captured)
        XCTAssertFalse(viewModel.didSubmit)
        XCTAssertEqual(viewModel.errorMessage, "ログインが必要です")
    }

    /// 空本文では送信できない
    func testSubmitFailsWhenMessageEmpty() async {
        let firestore = MockFirestoreServiceForFeedback()
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1")
        let viewModel = FeedbackViewModel(firestoreService: firestore, authService: auth)
        viewModel.message = "    "

        let success = await viewModel.submit()

        XCTAssertFalse(success)
        XCTAssertNil(firestore.captured)
    }
}

/// FeedbackViewModel 専用モック（submitFeedback のみ override）
private final class MockFirestoreServiceForFeedback: FirestoreServiceProtocol {
    var captured: Feedback?

    func submitFeedback(_ feedback: Feedback) async throws {
        captured = feedback
    }
}
