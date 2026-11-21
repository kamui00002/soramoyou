//
//  FeedbackViewModelTests.swift
//  SoramoyouTests
//
//  フィードバック送信 ViewModel の検証
//

@testable import Soramoyou
import XCTest

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
        XCTAssertEqual(firestore.captured?.message, "空の色が綺麗でした") // 前後空白はトリム
        XCTAssertEqual(firestore.captured?.category, "request")
        XCTAssertNil(firestore.captured?.replyEmail) // 欄を触らなければ書かない
    }

    // MARK: - 返信用のメールアドレス

    /// 返信用のメールアドレスは前後の空白と改行を削ってから渡す（Rules と関数は削らずに確かめるため）
    func testSubmitTrimsReplyEmail() async {
        let firestore = MockFirestoreServiceForFeedback()
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1")
        let viewModel = FeedbackViewModel(firestoreService: firestore, authService: auth)
        viewModel.message = "返事がほしいです"
        viewModel.replyEmail = "  sora@example.com \n"

        let success = await viewModel.submit()

        XCTAssertTrue(success)
        XCTAssertEqual(firestore.captured?.replyEmail, "sora@example.com")
    }

    /// 空白だけの返信用のメールアドレスは「空欄」と同じ＝書かずに送る
    func testSubmitTreatsWhitespaceOnlyReplyEmailAsEmpty() async {
        let firestore = MockFirestoreServiceForFeedback()
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1")
        let viewModel = FeedbackViewModel(firestoreService: firestore, authService: auth)
        viewModel.message = "感想です"
        viewModel.replyEmail = " \u{3000}\n "

        let success = await viewModel.submit()

        XCTAssertTrue(success)
        XCTAssertNotNil(firestore.captured)
        XCTAssertNil(firestore.captured?.replyEmail)
    }

    /// 形が合わない返信用のメールアドレス（全角で打った等）では送らず、直し方をエラーで伝える
    func testSubmitRejectsInvalidReplyEmail() async {
        let firestore = MockFirestoreServiceForFeedback()
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1")
        let viewModel = FeedbackViewModel(firestoreService: firestore, authService: auth)
        viewModel.message = "返事がほしいです"
        viewModel.replyEmail = "sora\u{FF20}example.com" // 全角の @

        let success = await viewModel.submit()

        XCTAssertFalse(success)
        XCTAssertNil(firestore.captured)
        XCTAssertFalse(viewModel.didSubmit)
        XCTAssertFalse(viewModel.isSending)
        XCTAssertEqual(viewModel.errorMessage, "返信用のメールアドレスの形が正しくありません。半角の name@example.com の形で入力してください（貼り付けたときは、打ち直すと直ることがあります）")
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
