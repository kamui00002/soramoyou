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
        firestore: MockFirestoreServiceForSettings,
        soratomo: MockSoratomoProfileService = MockSoratomoProfileService()
    ) -> SettingsViewModel {
        let auth = MockAuthService()
        auth.currentUserValue = currentUser
        return SettingsViewModel(authService: auth, firestoreService: firestore, soratomoProfileService: soratomo)
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

    // MARK: - そらとも通知（tasks 14.2）⭐️
    //
    // ⚠️ 共有のモック MockSoratomoProfileService は、既定で失敗（.unknown）を返す。成功の経路では先に .success(()) を入れる。
    // ⚠️ ON にする経路は実の PushNotificationManager（通知の許可）に触れるので、既定の ON → OFF の経路で確かめる。

    /// 計装の pref の値: そらともは "soratomo"、既存の 3 つは値を変えない（要件 14.6）。
    func testPrefKeyValuesIncludingSoratomo() {
        let sut = makeSUT(currentUser: User(id: "u1"), firestore: MockFirestoreServiceForSettings())

        XCTAssertEqual(sut.prefKey(.soratomo), "soratomo")
        XCTAssertEqual(sut.prefKey(.reactions), "reactions")
        XCTAssertEqual(sut.prefKey(.newPostsFromFollowing), "following")
        XCTAssertEqual(sut.prefKey(.newPostsFromEveryone), "everyone")
    }

    /// そらとも通知の既定値は ON（利用者モデルの既定と同じ）。
    func testSoratomoDefaultsToOn() {
        let sut = makeSUT(currentUser: User(id: "u1"), firestore: MockFirestoreServiceForSettings())

        XCTAssertTrue(sut.notifySoratomo)
    }

    /// 設定を開いたら、保存済みの OFF はそのまま OFF、未保存（nil）は ON として読む。
    func testLoadReflectsSoratomoPreference() async {
        let firestore = MockFirestoreServiceForSettings()
        firestore.fetchUserResult = User(id: "u1", notifySoratomo: false)
        let sut = makeSUT(currentUser: User(id: "u1"), firestore: firestore)
        await sut.loadNotificationPreferences()
        XCTAssertFalse(sut.notifySoratomo, "保存済みの OFF を読む")

        let firestoreUnset = MockFirestoreServiceForSettings()
        firestoreUnset.fetchUserResult = User(id: "u1", notifySoratomo: nil)
        let sutUnset = makeSUT(currentUser: User(id: "u1"), firestore: firestoreUnset)
        sutUnset.notifySoratomo = false
        await sutUnset.loadNotificationPreferences()
        XCTAssertTrue(sutUnset.notifySoratomo, "未保存は ON として読む")
    }

    /// そらとも通知の切り替えは、そらとものサービスへだけ保存する（既存の 3 つの保存は呼ばない）。
    func testSoratomoToggleSavesViaSoratomoProfileService() async {
        let firestore = MockFirestoreServiceForSettings()
        let soratomo = MockSoratomoProfileService()
        soratomo.setNotifySoratomoResult = .success(())
        let sut = makeSUT(currentUser: User(id: "u1"), firestore: firestore, soratomo: soratomo)

        await sut.setNotificationPreference(.soratomo, enabled: false)

        XCTAssertFalse(sut.notifySoratomo)
        XCTAssertEqual(soratomo.setNotifySoratomoCalls.count, 1)
        XCTAssertEqual(soratomo.setNotifySoratomoCalls.first?.uid, "u1")
        XCTAssertEqual(soratomo.setNotifySoratomoCalls.first?.enabled, false)
        XCTAssertFalse(firestore.updateCalled, "既存の 3 つの保存は呼ばない")
        XCTAssertNil(sut.pushNotificationMessage)
        // 既存の 3 つの値は動かない
        XCTAssertTrue(sut.notifyReactions)
        XCTAssertTrue(sut.notifyNewPostsFromFollowing)
        XCTAssertFalse(sut.notifyNewPostsFromEveryone)
    }

    /// 既存の 3 つの切り替えは、これまでどおり updateNotificationPreferences へ保存し、そらとものサービスは呼ばない。
    func testExistingPreferencesDoNotCallSoratomoService() async {
        let firestore = MockFirestoreServiceForSettings()
        let soratomo = MockSoratomoProfileService()
        let sut = makeSUT(currentUser: User(id: "u1"), firestore: firestore, soratomo: soratomo)

        await sut.setNotificationPreference(.reactions, enabled: false)
        XCTAssertEqual(firestore.updatedPrefs?.reactions, false)
        XCTAssertEqual(firestore.updatedPrefs?.following, true)
        XCTAssertEqual(firestore.updatedPrefs?.everyone, false)

        await sut.setNotificationPreference(.newPostsFromFollowing, enabled: false)
        XCTAssertEqual(firestore.updatedPrefs?.reactions, false)
        XCTAssertEqual(firestore.updatedPrefs?.following, false)
        XCTAssertEqual(firestore.updatedPrefs?.everyone, false)

        XCTAssertTrue(soratomo.setNotifySoratomoCalls.isEmpty, "既存の 3 つはそらとものサービスへ行かない")
        XCTAssertTrue(sut.notifySoratomo, "そらとも通知の値は動かない")
    }

    /// そらとも通知の保存に失敗したら、元の ON に戻して案内を出す（既存の 3 つと同じ）。
    func testSoratomoToggleRevertsOnSaveFailure() async {
        let firestore = MockFirestoreServiceForSettings()
        let soratomo = MockSoratomoProfileService()
        soratomo.setNotifySoratomoResult = .failure(.network)
        let sut = makeSUT(currentUser: User(id: "u1"), firestore: firestore, soratomo: soratomo)

        await sut.setNotificationPreference(.soratomo, enabled: false)

        XCTAssertTrue(sut.notifySoratomo, "保存失敗時は元の true に巻き戻る")
        XCTAssertNotNil(sut.pushNotificationMessage)
        XCTAssertFalse(firestore.updateCalled)
    }

    /// 未ログインなら、そらとも通知も保存せずに戻す。
    func testSoratomoToggleRevertsWhenNotLoggedIn() async {
        let firestore = MockFirestoreServiceForSettings()
        let soratomo = MockSoratomoProfileService()
        soratomo.setNotifySoratomoResult = .success(())
        let sut = makeSUT(currentUser: nil, firestore: firestore, soratomo: soratomo)

        await sut.setNotificationPreference(.soratomo, enabled: false)

        XCTAssertTrue(sut.notifySoratomo)
        XCTAssertTrue(soratomo.setNotifySoratomoCalls.isEmpty)
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
    /// 同じ削除が走る。このテストが確かめるのは「ViewModel が 2 回目の削除を必ず呼び直す」
    /// ことまで。既に消えたデータへの再実行でも壊れない（冪等）ことはモックでは検証できず、
    /// **Firestore 側の性質として前提にする**:
    ///
    /// Firestore の delete は存在しない文書に対しても成功し、rules の `isOwner` は
    /// `resource` を見ないため、2 回目も許可される。follows のドレインは取得が空になれば
    /// 即座に終わる。この前提が崩れると退会が「再認証してもずっと失敗する」状態になる。
    ///
    /// ※ #142 以降、1 回目で Firestore まで消えるこの経路を通るのは email を持たない匿名ユーザーだけ
    ///   （このテストの `User(id:)` も email なし）。メール/パスワードのユーザーは退会ボタンの時点では
    ///   データに触らず、先に再認証を求める（下の「本人確認を先に済ませる」のテスト群を参照）。
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

    // MARK: - 退会: 本人確認を先に済ませる（#142）

    /// ⭐️ メール/パスワードのユーザーは、退会ボタンの時点ではデータに一切触らず、
    /// まずパスワード入力（再認証）を求める。
    ///
    /// なぜ: 以前は「データを全部消す → Auth を消す」の順で、Auth 削除だけが
    /// requiresRecentLogin で弾かれることがあった。その後の再認証をキャンセル・失敗すると
    /// 「データは消えたのに Auth だけ残る」状態になる（本番で 4 件）。
    func testAccountDeletionForEmailUserAsksForPasswordWithoutTouchingData() async {
        let firestore = MockFirestoreServiceForSettings()
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1", email: "a@example.com")
        let sut = SettingsViewModel(authService: auth, firestoreService: firestore)

        let succeeded = await sut.performAccountDeletion()

        XCTAssertFalse(succeeded)
        XCTAssertTrue(sut.showingReauthentication, "先にパスワード入力を求める")
        XCTAssertTrue(firestore.deletedUserIds.isEmpty, "本人確認が済むまでデータは消さない")
        XCTAssertFalse(auth.deleteAccountCalled, "本人確認が済むまで Auth も消さない")
        XCTAssertNil(sut.deleteAccountError, "エラーではなく、パスワード入力の案内を出す")
    }

    /// ⭐️ メールユーザーの退会の全体: 退会ボタン → パスワード入力 → 再認証 → データ → Auth。
    /// データ削除は再認証が通ったあとの 1 回だけで、「データ → Auth」の順も変えない。
    func testEmailUserDeletesDataOnlyAfterReauthentication() async {
        let firestore = MockFirestoreServiceForSettings()
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1", email: "a@example.com")
        firestore.authForOrderCheck = auth
        let sut = SettingsViewModel(authService: auth, firestoreService: firestore)

        let first = await sut.performAccountDeletion()
        XCTAssertFalse(first)
        XCTAssertTrue(sut.showingReauthentication)

        let second = await sut.performReauthAndDelete(email: "a@example.com", password: "pw")

        XCTAssertTrue(second)
        XCTAssertEqual(firestore.deletedUserIds, ["u1"], "データ削除は再認証後の 1 回だけ")
        XCTAssertEqual(auth.deleteAccountCallCount, 1)
        XCTAssertEqual(firestore.authWasDeletedBeforeFirestore, false, "データ → Auth の順は変えない")
        XCTAssertNil(sut.deleteAccountError)
    }

    /// ⭐️ 匿名ユーザー（email なし）は従来どおり、退会ボタンでそのままデータ → Auth の順に消す。
    /// 匿名はパスワードを持たず再認証できないので、先にパスワードを求めても先へ進めないため。
    func testAccountDeletionForAnonymousUserDeletesDirectly() async {
        let firestore = MockFirestoreServiceForSettings()
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "anon", email: nil)
        firestore.authForOrderCheck = auth
        let sut = SettingsViewModel(authService: auth, firestoreService: firestore)

        let succeeded = await sut.performAccountDeletion()

        XCTAssertTrue(succeeded)
        XCTAssertFalse(sut.showingReauthentication, "匿名にはパスワード入力を出さない")
        XCTAssertEqual(firestore.deletedUserIds, ["anon"])
        XCTAssertTrue(auth.deleteAccountCalled)
        XCTAssertEqual(firestore.authWasDeletedBeforeFirestore, false)
    }

    /// ⭐️ 再認証に失敗したら、データにも Auth にも触らない（既存の挙動を固定する）。
    /// パスワード間違いのあとに諦めても「データだけ消えた」状態を作らないため。
    func testReauthAndDeleteDoesNotTouchDataWhenReauthenticationFails() async {
        let firestore = MockFirestoreServiceForSettings()
        let auth = MockAuthService()
        auth.currentUserValue = User(id: "u1", email: "a@example.com")
        auth.reauthenticateError = AuthError.wrongPassword
        let sut = SettingsViewModel(authService: auth, firestoreService: firestore)

        let succeeded = await sut.performReauthAndDelete(email: "a@example.com", password: "wrong")

        XCTAssertFalse(succeeded)
        XCTAssertTrue(firestore.deletedUserIds.isEmpty, "再認証に失敗したらデータは消さない")
        XCTAssertFalse(auth.deleteAccountCalled, "再認証に失敗したら Auth も消さない")
        XCTAssertNotNil(sut.deleteAccountError, "失敗はユーザーに伝える")
    }
}
