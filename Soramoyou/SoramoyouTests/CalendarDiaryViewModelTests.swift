//
//  CalendarDiaryViewModelTests.swift
//  SoramoyouTests
//
//  空カレンダー日記の ViewModel テスト。SkyCollectionViewModelTests と同型。
//  最小 Mock（fetchUserPosts のみ上書き、残りは FirestoreServiceProtocol+TestDefaults）で検証。
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

@MainActor
final class CalendarDiaryViewModelTests: XCTestCase {

    func testLoadGroupsPostsByDay() async {
        // Arrange
        let mock = MockFirestoreServiceForCalendarDiary()
        let capturedAt = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 6, day: 1, hour: 12)
        )!
        mock.stubbedPosts = [
            Post(id: "1", userId: "u1", images: [], capturedAt: capturedAt)
        ]
        let viewModel = CalendarDiaryViewModel(firestoreService: mock)

        // Act
        await viewModel.load(userId: "u1")

        // Assert: postsByDay に暦日キーで正しく詰まる / 異常なし / ローディング解除
        XCTAssertEqual(viewModel.posts(on: SkyStreakDay(year: 2026, month: 6, day: 1)).map { $0.id }, ["1"])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadSetsErrorMessageOnFailure() async {
        // Arrange: fetch が throw する
        let mock = MockFirestoreServiceForCalendarDiary()
        mock.stubbedError = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        let viewModel = CalendarDiaryViewModel(firestoreService: mock)

        // Act
        await viewModel.load(userId: "u1")

        // Assert: errorMessage が設定され、グルーピングはされず、ローディングは解除
        XCTAssertNotNil(viewModel.errorMessage, "失敗時は errorMessage を設定する")
        XCTAssertTrue(viewModel.posts(on: SkyStreakDay(year: 2026, month: 6, day: 1)).isEmpty, "失敗時はグルーピングしない")
        XCTAssertFalse(viewModel.isLoading, "完了後は isLoading=false")
    }

    func testHasPostsIsFalseForYearMonthWithNoPosts() async {
        // Arrange: 2026年6月にのみ投稿がある
        let mock = MockFirestoreServiceForCalendarDiary()
        let capturedAt = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 6, day: 1, hour: 12)
        )!
        mock.stubbedPosts = [
            Post(id: "1", userId: "u1", images: [], capturedAt: capturedAt)
        ]
        let viewModel = CalendarDiaryViewModel(firestoreService: mock)
        await viewModel.load(userId: "u1")

        // Assert: 投稿がある年月は true、存在しない年月（境界）は false
        XCTAssertTrue(viewModel.hasPosts(year: 2026, month: 6))
        XCTAssertFalse(viewModel.hasPosts(year: 2026, month: 7), "投稿が無い月は false")
        XCTAssertFalse(viewModel.hasPosts(year: 1999, month: 1), "投稿が存在しない年月は false")
    }
}

// MARK: - Mock

/// `fetchUserPosts` のみ上書きする最小 Mock。残りは TestDefaults（fatalError）で満たす。
final class MockFirestoreServiceForCalendarDiary: FirestoreServiceProtocol {
    var stubbedPosts: [Post] = []
    var stubbedError: Error?

    func fetchUserPosts(
        userId: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> [Post] {
        if let stubbedError { throw stubbedError }
        return stubbedPosts
    }
}
