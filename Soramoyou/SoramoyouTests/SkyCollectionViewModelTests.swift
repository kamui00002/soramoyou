//
//  SkyCollectionViewModelTests.swift
//  SoramoyouTests
//
//  空コレクション図鑑（柱2）の ViewModel テスト（G4/P3 対応）。
//  最小 Mock（fetchUserPosts のみ上書き、残りは FirestoreServiceProtocol+TestDefaults）で検証。
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

@MainActor
final class SkyCollectionViewModelTests: XCTestCase {

    func testLoadAggregatesPosts() async {
        // Arrange
        let mock = MockFirestoreServiceForCollection()
        mock.stubbedPosts = [
            Post(id: "1", userId: "u1", images: [], timeOfDay: .morning, skyType: .clear),
            Post(id: "2", userId: "u1", images: [], timeOfDay: .evening, skyType: .sunset)
        ]
        let viewModel = SkyCollectionViewModel(firestoreService: mock)

        // Act
        await viewModel.load(userId: "u1")

        // Assert: 集計結果が state に入る / 異常なし / ローディング解除
        XCTAssertEqual(viewModel.state.totalPosts, 2)
        XCTAssertEqual(viewModel.state.skyTypes, [.clear, .sunset])
        XCTAssertEqual(viewModel.state.timeOfDays, [.morning, .evening])
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadSetsErrorMessageOnFailure() async {
        // Arrange: fetch が throw する
        let mock = MockFirestoreServiceForCollection()
        mock.stubbedError = NSError(
            domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        let viewModel = SkyCollectionViewModel(firestoreService: mock)

        // Act
        await viewModel.load(userId: "u1")

        // Assert: errorMessage が設定され、集計はされず、ローディングは解除
        XCTAssertNotNil(viewModel.errorMessage, "失敗時は errorMessage を設定する")
        XCTAssertEqual(viewModel.state.totalPosts, 0, "失敗時は集計しない")
        XCTAssertFalse(viewModel.isLoading, "完了後は isLoading=false")
    }
}

// MARK: - Mock

/// `fetchUserPosts` のみ上書きする最小 Mock。残りは TestDefaults（fatalError）で満たす。
final class MockFirestoreServiceForCollection: FirestoreServiceProtocol {
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
