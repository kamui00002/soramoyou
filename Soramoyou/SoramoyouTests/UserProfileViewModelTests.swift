//
//  UserProfileViewModelTests.swift ⭐️
//  SoramoyouTests
//
//  他ユーザープロフィールの「投稿グリッドが常に空」不具合（欠陥 D）の再発防止テスト。
//
//  検証の要点は 2 つ:
//  1. フォロー状態に応じて **正しい公開範囲** で Firestore に問い合わせていること
//     （未フォロー相手に ['public','followers'] を投げると rules の followers 枝を
//       満たせず「クエリ全体」が denied になり、公開投稿まで巻き添えで消えるため）
//  2. 取得失敗を **握りつぶしていない** こと（旧実装は catch で [] を返すだけだった）
//
//  最小 Mock（fetchVisibleUserPosts / fetchPublicProfile のみ上書き、残りは
//  FirestoreServiceProtocol+TestDefaults）で検証する。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

@MainActor
final class UserProfileViewModelTests: XCTestCase {
    // MARK: - 公開範囲の分岐

    /// 未フォローの相手には `[.public]` だけを要求する（followers を混ぜない）
    func testLoadRequestsPublicOnlyWhenNotFollowing() async {
        // Arrange: フォローしていない状態
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedPosts = [makePost(id: "p1", visibility: .public)]
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: 公開範囲は public のみ
        XCTAssertEqual(firestore.capturedVisibilities, [[.public]],
                       "未フォロー時に followers を混ぜるとクエリ全体が denied になる")
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1"])
        XCTAssertNil(viewModel.errorMessage)
    }

    /// フォロー中の相手には `[.public, .followers]` を要求する
    func testLoadRequestsPublicAndFollowersWhenFollowing() async {
        // Arrange: フォロー中
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedPosts = [
            makePost(id: "p1", visibility: .public),
            makePost(id: "p2", visibility: .followers),
        ]
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: followers 限定投稿も要求し、結果をそのまま表示する（手元 filter で消さない）
        XCTAssertEqual(firestore.capturedVisibilities, [[.public, .followers]])
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"],
                       "フォロワー限定投稿を手元で除外してはいけない")
    }

    /// 投稿取得はフォロー状態が確定した **後** に 1 回だけ実行される
    func testLoadFetchesPostsOnceAfterFollowStateResolved() async {
        // Arrange
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: 並列実行して未フォロー扱いのクエリを投げていないこと
        XCTAssertEqual(firestore.capturedVisibilities.count, 1)
        XCTAssertEqual(firestore.capturedVisibilities.first, [.public, .followers])
    }

    // MARK: - エラーを握りつぶさない

    /// 取得失敗時に errorMessage を設定する（旧実装は [] を返すだけで無言だった）
    func testLoadSurfacesFetchErrorInsteadOfSwallowing() async {
        // Arrange: 投稿取得が失敗する
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedPostsError = NSError(
            domain: "test", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: posts が空なのは旧実装でも同じなので、errorMessage で判定する
        XCTAssertNotNil(viewModel.errorMessage,
                        "取得失敗を握りつぶすと「常に空」不具合が本番で見えなくなる")
        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
    }

    /// フォロー状態の取得失敗を可視化しつつ、安全側（public のみ）に降格すること ⭐️
    ///
    /// `isFollowing` は投稿クエリの visibility 集合を決める入力なので、取得失敗を
    /// 無言で「未フォロー」に倒すとフォロワー限定投稿が理由も分からず不可視に消え、
    /// 「rules の followers 枝が通るか」を確かめる R1 プローブの誤読も生む。
    /// 降格はするが errorMessage には必ず出す、という約束を固定する。
    func testLoadSurfacesIsFollowingErrorAndFallsBackToPublicOnly() async {
        // Arrange: フォロー中の相手だが、フォロー状態の取得に失敗する
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: true)
        follows.isFollowingError = NSError(
            domain: "test", code: 14,
            userInfo: [NSLocalizedDescriptionKey: "unavailable"]
        )
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: 失敗を握りつぶさない
        XCTAssertNotNil(viewModel.errorMessage,
                        "isFollowing の失敗を無言で未フォローに倒すと、原因不明のまま投稿が消える")

        // Assert: 降格挙動は維持（証明できる public だけを要求する）
        XCTAssertEqual(firestore.capturedVisibilities, [[.public]],
                       "取得できなかったフォロー状態を根拠に followers を混ぜてはいけない")
        XCTAssertFalse(viewModel.isFollowing)
    }

    // MARK: - フォロー操作後の再取得

    /// フォロー成功後は新しい公開範囲で投稿を取り直す
    func testToggleFollowRefetchesPostsWithFollowersVisibility() async {
        // Arrange: 未フォロー状態でロード済み
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)
        await viewModel.load()
        XCTAssertEqual(firestore.capturedVisibilities, [[.public]])

        // Act: フォローする
        await viewModel.toggleFollow()

        // Assert: 2 回目のクエリは followers を含む
        XCTAssertEqual(firestore.capturedVisibilities,
                       [[.public], [.public, .followers]],
                       "フォロー直後にフォロワー限定投稿が見えるようにならない")
        XCTAssertTrue(viewModel.isFollowing)
    }

    /// フォロー解除後は public のみで取り直す（フォロワー限定投稿を残さない）
    func testToggleUnfollowRefetchesPostsWithPublicOnly() async {
        // Arrange: フォロー中の状態でロード済み
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)
        await viewModel.load()

        // Act: フォロー解除
        await viewModel.toggleFollow()

        // Assert: 2 回目のクエリは public のみ
        XCTAssertEqual(firestore.capturedVisibilities,
                       [[.public, .followers], [.public]])
        XCTAssertFalse(viewModel.isFollowing)
    }

    /// フォローが断られたら日本語の文を出し、フォロー中にしない ⭐️（C 項目 2）
    func testToggleFollowShowsJapaneseMessageWhenFollowIsNotAllowed() async {
        // Arrange: 未フォロー状態でロード済み。フォローはサーバーに断られる
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: false)
        follows.followError = FollowRepositoryError.followNotAllowed
        let viewModel = makeViewModel(firestore: firestore, follows: follows)
        await viewModel.load()

        // Act: フォローする
        await viewModel.toggleFollow()

        // Assert: 文は日本語のまま画面に届き、フォロー中にはならない
        XCTAssertEqual(viewModel.errorMessage, "フォローできませんでした")
        XCTAssertFalse(viewModel.isFollowing)
    }

    // MARK: - ブロック（C 項目 3）

    /// ブロックすると、自分→相手の向きで 1 回だけ保存し、一覧に伝える通知（.userBlocked）を相手の ID 付きで送る ⭐️
    func testBlockUserSavesOnceAndNotifiesWithTargetId() async {
        // Arrange: ログイン中（me）で、他人（target）のプロフィールを見ている
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)
        let notified = expectation(forNotification: .userBlocked, object: nil) { notification in
            notification.userInfo?[Notification.blockedUserIdKey] as? String == "target"
        }

        // Act
        let blocked = await viewModel.blockUser()

        // Assert: 保存は 1 回だけ・向きは自分→相手。成功を返す（View はこれを見て画面を閉じる）
        await fulfillment(of: [notified], timeout: 1)
        XCTAssertEqual(firestore.blockCalls, [["me", "target"]])
        XCTAssertTrue(blocked)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 保存に失敗したら通知を送らず、文を出して閉じない（一覧から消したのに実際はブロックされていない、を防ぐ）
    func testBlockUserFailureShowsErrorWithoutNotifying() async {
        // Arrange: ブロックの保存が失敗する
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedBlockUserError = FirestoreServiceError.notFound
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)
        let notified = expectation(forNotification: .userBlocked, object: nil)
        notified.isInverted = true

        // Act
        let blocked = await viewModel.blockUser()

        // Assert
        await fulfillment(of: [notified], timeout: 0.3)
        XCTAssertFalse(blocked, "失敗したのに閉じると、ブロックできたように見える")
        XCTAssertNotNil(viewModel.errorMessage, "失敗はエラーとして画面に出す")
    }

    /// ログインしていないときは保存しない
    func testBlockUserDoesNothingWhenSignedOut() async {
        // Arrange: ログインしていない
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows, ownUserId: nil)

        // Act
        let blocked = await viewModel.blockUser()

        // Assert
        XCTAssertTrue(firestore.blockCalls.isEmpty)
        XCTAssertFalse(blocked)
    }

    /// 自分のプロフィールでは保存しない（自分をブロックの一覧に入れない）
    func testBlockUserDoesNothingOnOwnProfile() async {
        // Arrange: 見ているのが自分のプロフィール
        let firestore = MockFirestoreServiceForUserProfile()
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows, ownUserId: "target")

        // Act
        let blocked = await viewModel.blockUser()

        // Assert
        XCTAssertTrue(firestore.blockCalls.isEmpty)
        XCTAssertFalse(blocked)
    }

    // MARK: - 入口の出し方（空カレンダー・お気に入りの空）⭐️ 1.18.0 PR-B

    /// フォロー中で、持ち主が ON → 入口のボタン
    func testEntryIsOpenWhenFollowingAndOwnerTurnedOn() async {
        // Arrange: 持ち主が 3 つとも ON・フォロー中
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert
        XCTAssertEqual(viewModel.skyCalendarEntryState, .open)
        XCTAssertEqual(viewModel.favoritesEntryState, .open)
    }

    /// ログイン中・フォローしていない・持ち主が ON →「フォローすると〜が見られます」の 1 行
    func testEntryIsFollowToSeeWhenNotFollowingAndOwnerTurnedOn() async {
        // Arrange
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: フォロワーでない人に中身への入口は出さない（ルールでも読めない）
        XCTAssertEqual(viewModel.skyCalendarEntryState, .followToSee)
        XCTAssertEqual(viewModel.favoritesEntryState, .followToSee)
    }

    /// 持ち主が OFF → フォロー中でも出さない
    func testEntryIsHiddenWhenOwnerTurnedOffEvenIfFollowing() async {
        // Arrange
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOff
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert
        XCTAssertEqual(viewModel.skyCalendarEntryState, .hidden)
        XCTAssertEqual(viewModel.favoritesEntryState, .hidden)
    }

    /// 持ち主が OFF → フォローしていなくても「フォローすると〜」は出さない（フォローしても見られないため）
    func testEntryIsHiddenWhenOwnerTurnedOffAndNotFollowing() async {
        // Arrange
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOff
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert
        XCTAssertEqual(viewModel.skyCalendarEntryState, .hidden)
        XCTAssertEqual(viewModel.favoritesEntryState, .hidden)
    }

    /// 欄ごとに別々に決まる: フォロー中で、カレンダーだけ ON → カレンダーは入口・お気に入りは出さない
    func testEntryOnlySkyCalendarTurnedOnWhileFollowing() async {
        // Arrange
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = ProfileSectionVisibility(
            showsRecommendedSkies: true,
            showsSkyCalendar: true,
            showsFavorites: false
        )
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert
        XCTAssertEqual(viewModel.skyCalendarEntryState, .open)
        XCTAssertEqual(viewModel.favoritesEntryState, .hidden)
    }

    /// 欄ごとに別々に決まる: フォローしていなくて、お気に入りだけ ON → カレンダーは出さない・お気に入りは「フォローすると〜」
    func testEntryOnlyFavoritesTurnedOnWhileNotFollowing() async {
        // Arrange
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = ProfileSectionVisibility(
            showsRecommendedSkies: true,
            showsSkyCalendar: false,
            showsFavorites: true
        )
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert
        XCTAssertEqual(viewModel.skyCalendarEntryState, .hidden)
        XCTAssertEqual(viewModel.favoritesEntryState, .followToSee)
    }

    /// 項目が無い人（今いる人全員）の既定値: カレンダーとお気に入りは出さない・おすすめの空は出す
    func testEntryIsHiddenAndRecommendedShownWithDefaultVisibility() async {
        // Arrange: 項目なし（既定値）・フォロー中
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = .default
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: 今いる人の見え方は変わらない（おすすめの空だけが出る）
        XCTAssertEqual(viewModel.skyCalendarEntryState, .hidden)
        XCTAssertEqual(viewModel.favoritesEntryState, .hidden)
        XCTAssertTrue(viewModel.showsRecommendedSkies)
    }

    /// ゲスト（ログインしていない）・持ち主が ON →「フォローすると〜が見られます」の 1 行 ⭐️ 1.18.0 PR-B
    /// （2026-10-24 利用者の決定でゲストにも出す。押しても何も起きない 1 行で、ログインのきっかけにする）
    func testEntryIsFollowToSeeForGuestWhenOwnerTurnedOn() async {
        // Arrange: ログインしていない・持ち主が 3 つとも ON
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows, ownUserId: nil)

        // Act
        await viewModel.load()

        // Assert: 入口のボタン（.open）は出さず、「フォローすると〜」の 1 行だけ
        XCTAssertEqual(viewModel.skyCalendarEntryState, .followToSee)
        XCTAssertEqual(viewModel.favoritesEntryState, .followToSee)
    }

    /// ゲストは `isFollowing` が true になっても入口のボタン（.open）にならない ⭐️ 1.18.0 PR-B
    ///
    /// 上のテストはゲストの `isFollowing` が false のままなので、`entryState(for:)` のゲストの判定を
    /// 消しても（下の `isFollowing ? .open : .followToSee` に流れても）同じ `.followToSee` で緑のまま。
    /// ゲストの判定が `isFollowing` を見ずに決めていることを、ここで固定する。
    func testEntryIsFollowToSeeForGuestEvenIfIsFollowingBecomesTrue() async {
        // Arrange: ログインしていない・持ち主が 3 つとも ON
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows, ownUserId: nil)
        await viewModel.load()

        // Act: どんな道であれ、ゲストの isFollowing が true になった
        viewModel.isFollowing = true

        // Assert: それでも入口のボタンは出さない（フォロワーでないので中身はルールでも読めない）
        XCTAssertEqual(viewModel.skyCalendarEntryState, .followToSee)
        XCTAssertEqual(viewModel.favoritesEntryState, .followToSee)
    }

    /// ゲスト・持ち主が OFF → 出さない（フォローしても見られないので「フォローすると〜」も出さない）⭐️ 1.18.0 PR-B
    func testEntryIsHiddenForGuestWhenOwnerTurnedOff() async {
        // Arrange: ログインしていない・持ち主が 3 つとも OFF
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOff
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows, ownUserId: nil)

        // Act
        await viewModel.load()

        // Assert
        XCTAssertEqual(viewModel.skyCalendarEntryState, .hidden)
        XCTAssertEqual(viewModel.favoritesEntryState, .hidden)
    }

    /// ゲスト・プロフィールが取れなかった → 出さない（持ち主が ON か分からないため。ゲストの判定より先に見る）⭐️ 1.18.0 PR-B
    func testEntryIsHiddenForGuestWhenProfileFailedToLoad() async {
        // Arrange: ログインしていない・プロフィールの取得が失敗する
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        firestore.stubbedPublicProfileError = NSError(
            domain: "test", code: 14,
            userInfo: [NSLocalizedDescriptionKey: "unavailable"]
        )
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows, ownUserId: nil)

        // Act
        await viewModel.load()

        // Assert
        XCTAssertNil(viewModel.publicProfile)
        XCTAssertEqual(viewModel.skyCalendarEntryState, .hidden)
        XCTAssertEqual(viewModel.favoritesEntryState, .hidden)
    }

    /// 自分のプロフィール → 持ち主（自分）が ON でも出さない（自分の分はプロフィールタブの入口から見る）
    func testEntryIsHiddenOnOwnProfile() async {
        // Arrange: 見ているのが自分のプロフィール
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows, ownUserId: "target")

        // Act
        await viewModel.load()

        // Assert
        XCTAssertEqual(viewModel.skyCalendarEntryState, .hidden)
        XCTAssertEqual(viewModel.favoritesEntryState, .hidden)
    }

    /// プロフィールが取れなかった → 出さない・おすすめの空も読まない（持ち主が ON か分からないため）
    func testEntryIsHiddenWhenProfileFailedToLoad() async {
        // Arrange: プロフィールの取得が失敗する（フォロー中）
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        firestore.stubbedPublicProfileError = NSError(
            domain: "test", code: 14,
            userInfo: [NSLocalizedDescriptionKey: "unavailable"]
        )
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert
        XCTAssertNil(viewModel.publicProfile)
        XCTAssertEqual(viewModel.skyCalendarEntryState, .hidden)
        XCTAssertEqual(viewModel.favoritesEntryState, .hidden)
        XCTAssertFalse(viewModel.showsRecommendedSkies)
    }

    /// 読み込む前（プロフィール未取得）→ 出さない・おすすめの空も出さない
    func testEntryIsHiddenBeforeLoad() {
        // Arrange: load を呼ばない
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Assert
        XCTAssertEqual(viewModel.skyCalendarEntryState, .hidden)
        XCTAssertEqual(viewModel.favoritesEntryState, .hidden)
        XCTAssertFalse(viewModel.showsRecommendedSkies)
    }

    /// フォロー状態が読めなかった → 安全側（フォローしていない扱い）で「フォローすると〜」。入口は開かない
    func testEntryIsFollowToSeeWhenIsFollowingFailed() async {
        // Arrange: フォロー中の相手だが、フォロー状態の取得に失敗する
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        let follows = MockFollowRepository(isFollowingResult: true)
        follows.isFollowingError = NSError(
            domain: "test", code: 14,
            userInfo: [NSLocalizedDescriptionKey: "unavailable"]
        )
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert
        XCTAssertEqual(viewModel.skyCalendarEntryState, .followToSee)
        XCTAssertEqual(viewModel.favoritesEntryState, .followToSee)
    }

    /// フォロー解除の後は、入口のボタン →「フォローすると〜」に変わる
    func testEntryChangesFromOpenToFollowToSeeAfterUnfollow() async {
        // Arrange: 持ち主が ON・フォロー中でロード済み
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)
        await viewModel.load()
        XCTAssertEqual(viewModel.skyCalendarEntryState, .open)
        XCTAssertEqual(viewModel.favoritesEntryState, .open)

        // Act: フォロー解除
        await viewModel.toggleFollow()

        // Assert
        XCTAssertFalse(viewModel.isFollowing)
        XCTAssertEqual(viewModel.skyCalendarEntryState, .followToSee)
        XCTAssertEqual(viewModel.favoritesEntryState, .followToSee)
    }

    /// フォローした後は、「フォローすると〜」→ 入口のボタンに変わる
    func testEntryChangesFromFollowToSeeToOpenAfterFollow() async {
        // Arrange: 持ち主が ON・フォローしていない状態でロード済み
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)
        await viewModel.load()
        XCTAssertEqual(viewModel.skyCalendarEntryState, .followToSee)
        XCTAssertEqual(viewModel.favoritesEntryState, .followToSee)

        // Act: フォローする
        await viewModel.toggleFollow()

        // Assert
        XCTAssertTrue(viewModel.isFollowing)
        XCTAssertEqual(viewModel.skyCalendarEntryState, .open)
        XCTAssertEqual(viewModel.favoritesEntryState, .open)
    }

    /// フォローが断られたら入口は開かない（「フォローすると〜」のまま）
    func testEntryStaysFollowToSeeWhenFollowIsNotAllowed() async {
        // Arrange: 持ち主が ON・フォローしていない。フォローはサーバーに断られる
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        let follows = MockFollowRepository(isFollowingResult: false)
        follows.followError = FollowRepositoryError.followNotAllowed
        let viewModel = makeViewModel(firestore: firestore, follows: follows)
        await viewModel.load()

        // Act
        await viewModel.toggleFollow()

        // Assert
        XCTAssertEqual(viewModel.skyCalendarEntryState, .followToSee)
        XCTAssertEqual(viewModel.favoritesEntryState, .followToSee)
    }

    // MARK: - おすすめの空の見せる/見せない ⭐️ 1.18.0 PR-B

    /// 持ち主がおすすめの空を OFF → 欄を出さない（View はこれを見て読み込みもしない）
    func testRecommendedSkiesHiddenWhenOwnerTurnedOff() async {
        // Arrange: おすすめの空だけ OFF（ほかの 2 つは ON）
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = ProfileSectionVisibility(
            showsRecommendedSkies: false,
            showsSkyCalendar: true,
            showsFavorites: true
        )
        let follows = MockFollowRepository(isFollowingResult: true)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert: おすすめの空だけが消え、ほかの 2 つの入口には影響しない
        XCTAssertFalse(viewModel.showsRecommendedSkies)
        XCTAssertEqual(viewModel.skyCalendarEntryState, .open)
        XCTAssertEqual(viewModel.favoritesEntryState, .open)
    }

    /// 持ち主がおすすめの空を ON → 欄を出す（フォローしていなくても出す＝見せる相手はプロフィールを開ける全員）
    func testRecommendedSkiesShownWhenOwnerTurnedOnEvenIfNotFollowing() async {
        // Arrange: おすすめの空だけ ON・フォローしていない
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = ProfileSectionVisibility(
            showsRecommendedSkies: true,
            showsSkyCalendar: false,
            showsFavorites: false
        )
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows)

        // Act
        await viewModel.load()

        // Assert
        XCTAssertTrue(viewModel.showsRecommendedSkies)
    }

    /// ゲストにもおすすめの空は出す（見せる相手はプロフィールを開ける全員・今と同じ）
    func testRecommendedSkiesShownForGuest() async {
        // Arrange: ログインしていない・おすすめの空は ON
        let firestore = MockFirestoreServiceForUserProfile()
        firestore.stubbedSectionVisibility = Self.allOn
        let follows = MockFollowRepository(isFollowingResult: false)
        let viewModel = makeViewModel(firestore: firestore, follows: follows, ownUserId: nil)

        // Act
        await viewModel.load()

        // Assert
        XCTAssertTrue(viewModel.showsRecommendedSkies)
    }

    // MARK: - Helpers

    /// 3 つとも ON（見せる）
    private static let allOn = ProfileSectionVisibility(
        showsRecommendedSkies: true,
        showsSkyCalendar: true,
        showsFavorites: true
    )

    /// 3 つとも OFF（見せない）
    private static let allOff = ProfileSectionVisibility(
        showsRecommendedSkies: false,
        showsSkyCalendar: false,
        showsFavorites: false
    )

    private func makeViewModel(
        firestore: MockFirestoreServiceForUserProfile,
        follows: MockFollowRepository,
        ownUserId: String? = "me"
    ) -> UserProfileViewModel {
        UserProfileViewModel(
            targetUserId: "target",
            ownUserId: ownUserId,
            firestoreService: firestore,
            followRepository: follows
        )
    }

    private func makePost(id: String, visibility: Visibility) -> Post {
        Post(id: id, userId: "target", images: [], visibility: visibility)
    }
}

// MARK: - Mocks

/// `fetchVisibleUserPosts` / `fetchPublicProfile` / `blockUser` のみ上書きする最小 Mock。
/// 残りは FirestoreServiceProtocol+TestDefaults（fatalError）で満たす。
final class MockFirestoreServiceForUserProfile: FirestoreServiceProtocol {
    /// 呼び出しごとに要求された公開範囲を記録する（呼び出し回数の検証も兼ねる）
    private(set) var capturedVisibilities: [[Visibility]] = []
    var stubbedPosts: [Post] = []
    var stubbedPostsError: Error?

    func fetchVisibleUserPosts(
        userId _: String,
        visibilities: [Visibility],
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> [Post] {
        capturedVisibilities.append(visibilities)
        if let stubbedPostsError { throw stubbedPostsError }
        return stubbedPosts
    }

    // MARK: 見せる/見せない（1.18.0・PR-B）⭐️

    /// fetchPublicProfile が返すプロフィールの見せる/見せない（既定は項目なし＝`.default` と同じ値）
    var stubbedSectionVisibility: ProfileSectionVisibility = .default
    /// fetchPublicProfile を失敗させたいときに設定する（プロフィールが取れなかったときを再現する）
    var stubbedPublicProfileError: Error?

    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        if let stubbedPublicProfileError { throw stubbedPublicProfileError }
        return PublicProfile(id: userId, displayName: "テストユーザー", sectionVisibility: stubbedSectionVisibility)
    }

    // MARK: ブロック（C 項目 3）⭐️

    /// blockUser を失敗させたいときに設定する
    var stubbedBlockUserError: Error?
    /// blockUser に渡された [自分, 相手] の組（呼び出し回数と向きの検証を兼ねる）
    private(set) var blockCalls: [[String]] = []

    func blockUser(userId: String, blockedUserId: String) async throws {
        blockCalls.append([userId, blockedUserId])
        if let stubbedBlockUserError { throw stubbedBlockUserError }
    }
}

/// フォロー状態を固定で返し、follow/unfollow で切り替える最小 Mock。
/// `FollowRepositoryProtocol` は Sendable 継承のため `@unchecked Sendable` を付ける
/// （テストは @MainActor 上でのみ触るので実質的な競合は起きない）。
final class MockFollowRepository: FollowRepositoryProtocol, @unchecked Sendable {
    private var isFollowingResult: Bool
    /// isFollowing が投げるエラー（フォロー状態の取得失敗を再現する）
    var isFollowingError: Error?
    /// follow が投げるエラー（サーバーがフォローを断ったときを再現する）
    var followError: Error?

    init(isFollowingResult: Bool) {
        self.isFollowingResult = isFollowingResult
    }

    func follow(_: String, by _: String) async throws {
        if let followError { throw followError }
        isFollowingResult = true
    }

    func unfollow(_: String, by _: String) async throws {
        isFollowingResult = false
    }

    func isFollowing(_: String, by _: String) async throws -> Bool {
        if let isFollowingError { throw isFollowingError }
        return isFollowingResult
    }
}
