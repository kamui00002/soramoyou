//
//  SettingsViewModelTests.swift
//  SoramoyouTests
//
//  プッシュ通知の配信プレフ（読み込み・トグル保存・巻き戻し）の単体テスト。
//  保存は targeted update（updateNotificationPreferences）を通る。
//  ⚠️ enabled:true 経路は PushNotificationManager.shared（実 UNUserNotificationCenter）に依存するため、
//     許可要求を伴わない enabled:false 経路と「未ログインで guard 返し」中心に検証する。
//

import XCTest
@testable import Soramoyou

/// SettingsViewModel 専用モック（fetchUser / updateNotificationPreferences のみ override）。
/// 他メソッドは FirestoreServiceProtocol+TestDefaults の fatalError 既定。
private final class MockFirestoreServiceForSettings: FirestoreServiceProtocol {
    var fetchUserResult: User?
    var fetchUserError: Error?
    var updateShouldThrow = false
    private(set) var updateCalled = false
    private(set) var updatedPrefs: (reactions: Bool, following: Bool, everyone: Bool)?

    func fetchUser(userId: String) async throws -> User {
        if let error = fetchUserError { throw error }
        guard let user = fetchUserResult else {
            throw NSError(domain: "MockFirestoreServiceForSettings", code: -1)
        }
        return user
    }

    func updateNotificationPreferences(
        userId: String,
        notifyReactions: Bool,
        notifyNewPostsFromFollowing: Bool,
        notifyNewPostsFromEveryone: Bool
    ) async throws {
        updateCalled = true
        updatedPrefs = (notifyReactions, notifyNewPostsFromFollowing, notifyNewPostsFromEveryone)
        if updateShouldThrow {
            throw NSError(domain: "MockFirestoreServiceForSettings", code: -2)
        }
    }
}

@MainActor
final class SettingsViewModelTests: XCTestCase {

    private func makeSUT(
        currentUser: User?,
        firestore: MockFirestoreServiceForSettings
    ) -> SettingsViewModel {
        let auth = MockAuthService()
        auth.currentUserValue = currentUser
        return SettingsViewModel(authService: auth, firestoreService: firestore)
    }

    /// 設定を開いたら Firestore の現在値が @Published に反映される。
    func testLoadReflectsFetchedPreferences() async {
        let firestore = MockFirestoreServiceForSettings()
        firestore.fetchUserResult = User(
            id: "u1",
            notifyReactions: false,
            notifyNewPostsFromFollowing: true,
            notifyNewPostsFromEveryone: true
        )
        let sut = makeSUT(currentUser: User(id: "u1"), firestore: firestore)

        await sut.loadNotificationPreferences()

        XCTAssertFalse(sut.notifyReactions)
        XCTAssertTrue(sut.notifyNewPostsFromFollowing)
        XCTAssertTrue(sut.notifyNewPostsFromEveryone)
    }

    /// トグル OFF が targeted update で保存され、UI 値も反映される（カウント等は書かない）。
    func testSetPreferenceSavesViaTargetedUpdate() async {
        let firestore = MockFirestoreServiceForSettings()
        let sut = makeSUT(currentUser: User(id: "u1"), firestore: firestore)

        // 既定 reactions=true を false にする（enabled:false=許可要求を伴わない経路）。
        await sut.setNotificationPreference(.reactions, enabled: false)

        XCTAssertFalse(sut.notifyReactions)
        XCTAssertTrue(firestore.updateCalled)
        XCTAssertEqual(firestore.updatedPrefs?.reactions, false)
    }

    /// 保存に失敗したら楽観的更新を巻き戻し、案内メッセージを出す。
    func testSetPreferenceRevertsOnSaveFailure() async {
        let firestore = MockFirestoreServiceForSettings()
        firestore.updateShouldThrow = true
        let sut = makeSUT(currentUser: User(id: "u1"), firestore: firestore)

        await sut.setNotificationPreference(.reactions, enabled: false)

        XCTAssertTrue(sut.notifyReactions, "保存失敗時は元の true に巻き戻る")
        XCTAssertNotNil(sut.pushNotificationMessage)
    }

    /// 未ログインなら保存せず巻き戻す（許可要求にも到達しない）。
    func testSetPreferenceRevertsWhenNotLoggedIn() async {
        let firestore = MockFirestoreServiceForSettings()
        let sut = makeSUT(currentUser: nil, firestore: firestore)

        await sut.setNotificationPreference(.newPostsFromEveryone, enabled: true)

        XCTAssertFalse(sut.notifyNewPostsFromEveryone, "未ログインは既定 false に巻き戻る")
        XCTAssertFalse(firestore.updateCalled)
    }
}
