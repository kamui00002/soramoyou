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

    // MARK: - 退会（アカウント削除）用

    /// 設定すると deleteUserData がこのエラーを投げる
    var deleteUserDataError: Error?
    /// deleteUserData に渡された userId の記録
    private(set) var deletedUserIds: [String] = []

    /// 順序検証用の Auth モック参照（設定すると下の記録が有効になる）
    weak var authForOrderCheck: MockAuthService?
    /// deleteUserData が呼ばれた時点で、既に Auth 削除が走っていたか。
    /// 「Firestore → Auth」の順序を本当に守っているかは、両方が呼ばれた事実だけでは分からない。
    private(set) var authWasDeletedBeforeFirestore: Bool?

    func deleteUserData(userId: String) async throws {
        if let auth = authForOrderCheck {
            authWasDeletedBeforeFirestore = auth.deleteAccountCalled
        }
        deletedUserIds.append(userId)
        if let deleteUserDataError {
            throw deleteUserDataError
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

    // MARK: - 退会（アカウント削除）

    /// ⭐️ Firestore のデータ削除に失敗したら、Auth アカウントは消さない。
    ///
    /// なぜこの順序が重要か: publicProfiles / follows の rules は
    /// 「本人（isOwner / followerId・followeeId が自分）」にしか delete を許していない。
    /// 先に Auth を消すと本人として認証できなくなり、残ったデータは
    /// クライアントからは二度と消せない孤児データになる。
    func testAccountDeletionKeepsAuthAccountWhenFirestoreDeletionFails() async {
        let firestore = MockFirestoreServiceForSettings()
        firestore.deleteUserDataError = NSError(domain: "MockFirestoreServiceForSettings", code: -3)
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1")
        let sut = SettingsViewModel(authService: auth, firestoreService: firestore)

        let succeeded = await sut.performAccountDeletion()

        XCTAssertFalse(succeeded)
        XCTAssertEqual(firestore.deletedUserIds, ["u1"], "Firestore の削除は試みる")
        XCTAssertFalse(auth.deleteAccountCalled, "Firestore 削除に失敗したら Auth アカウントは残す")
        XCTAssertNotNil(sut.deleteAccountError, "失敗はユーザーに伝える")
    }

    /// 正常系: Firestore のデータを消してから Auth アカウントを消す。
    func testAccountDeletionDeletesFirestoreDataThenAuthAccount() async {
        let firestore = MockFirestoreServiceForSettings()
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1")
        let sut = SettingsViewModel(authService: auth, firestoreService: firestore)

        firestore.authForOrderCheck = auth

        let succeeded = await sut.performAccountDeletion()

        XCTAssertTrue(succeeded)
        XCTAssertEqual(firestore.deletedUserIds, ["u1"])
        XCTAssertTrue(auth.deleteAccountCalled)
        XCTAssertNil(sut.deleteAccountError)
        XCTAssertEqual(
            firestore.authWasDeletedBeforeFirestore, false,
            "Firestore を消す時点では Auth アカウントがまだ生きている必要がある（rules が本人にしか delete を許さないため）"
        )
    }

    /// ⭐️ 再認証が要求された場合: 1 回目で Firestore は消え、再認証後にもう一度
    /// 同じ削除が走る。既に消えたデータへの再実行でも壊れない（冪等）ことを確かめる。
    ///
    /// Firestore の delete は存在しない文書に対しても成功し、rules の `isOwner` は
    /// `resource` を見ないため、2 回目も許可される。follows のドレインは取得が空になれば
    /// 即座に終わる。この前提が崩れると退会が「再認証してもずっと失敗する」状態になる。
    func testReauthAndDeleteRerunsDeletionIdempotently() async {
        let firestore = MockFirestoreServiceForSettings()
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1")
        // 1 回目の Auth 削除だけ「最近ログインしていない」で失敗させる
        auth.deleteAccountErrorOnce = AuthError.requiresRecentLogin
        let sut = SettingsViewModel(authService: auth, firestoreService: firestore)

        // 1 回目: Firestore は消えるが Auth 削除で弾かれ、再認証シートが出る
        let first = await sut.performAccountDeletion()
        XCTAssertFalse(first)
        XCTAssertTrue(sut.showingReauthentication, "再認証を促す")
        XCTAssertEqual(firestore.deletedUserIds, ["u1"])

        // 2 回目: 再認証後。同じ削除がもう一度走っても成功する
        let second = await sut.performReauthAndDelete(email: "a@example.com", password: "pw")
        XCTAssertTrue(second)
        XCTAssertEqual(firestore.deletedUserIds, ["u1", "u1"], "再認証後も Firestore 削除を必ずやり直す")
        XCTAssertEqual(auth.deleteAccountCallCount, 2)
    }

    /// 未ログインなら Firestore も Auth も触らない。
    func testAccountDeletionDoesNothingWhenNotLoggedIn() async {
        let firestore = MockFirestoreServiceForSettings()
        let auth = MockAuthService()
        auth.currentUserValue = nil
        let sut = SettingsViewModel(authService: auth, firestoreService: firestore)

        let succeeded = await sut.performAccountDeletion()

        XCTAssertFalse(succeeded)
        XCTAssertTrue(firestore.deletedUserIds.isEmpty)
        XCTAssertFalse(auth.deleteAccountCalled)
    }
}
