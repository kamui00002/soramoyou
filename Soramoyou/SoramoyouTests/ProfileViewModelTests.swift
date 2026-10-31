//
//  ProfileViewModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

// Note: FirebaseAuth.Userとの競合を避けるため、Userは Soramoyou.User を参照

@MainActor
final class ProfileViewModelTests: XCTestCase {
    var viewModel: ProfileViewModel!
    var mockFirestoreService: MockFirestoreServiceForProfile!
    var mockStorageService: MockStorageServiceForProfile!

    override func setUp() {
        super.setUp()
        mockFirestoreService = MockFirestoreServiceForProfile()
        mockStorageService = MockStorageServiceForProfile()
    }

    override func tearDown() {
        viewModel = nil
        mockFirestoreService = nil
        mockStorageService = nil
        super.tearDown()
    }

    func testProfileViewModelInitialization() {
        // Given & When
        let viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // Then
        XCTAssertNotNil(viewModel)
        XCTAssertNil(viewModel.user)
        XCTAssertTrue(viewModel.userPosts.isEmpty)
        XCTAssertTrue(viewModel.equippedTools.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadProfile() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When
        await viewModel.loadProfile()

        // Then
        XCTAssertNotNil(viewModel.user)
        XCTAssertEqual(viewModel.user?.id, testUser.id)
        XCTAssertEqual(viewModel.editingDisplayName, testUser.displayName ?? "")
        XCTAssertEqual(viewModel.editingBio, testUser.bio ?? "")
    }

    func testLoadUserPosts() async {
        // Given
        let testUser = createTestUser()
        let testPosts = createTestPosts(userId: testUser.id)
        mockFirestoreService.user = testUser
        mockFirestoreService.userPosts = testPosts
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When
        await viewModel.loadUserPosts()

        // Then
        XCTAssertFalse(viewModel.userPosts.isEmpty)
        XCTAssertEqual(viewModel.userPosts.count, testPosts.count)
    }

    /// ⭐️ 回帰防止: 投稿が 50 件を超えても投稿数が 50 に書き戻されないこと。
    /// 旧実装は「取得した 1 ページ分の件数」を投稿数として保存していた。
    func testLoadUserPosts_自分の投稿数は取得件数でなく集計値になる() async {
        // Given: 画面に並べるのは 2 件だが、実際の投稿は 104 件ある
        let testUser = createTestUser()
        mockFirestoreService.userPosts = createTestPosts(userId: testUser.id)
        mockFirestoreService.recountedPostsCount = 104
        let authService = MockAuthService()
        authService.currentUserValue = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService,
            authService: authService
        )
        viewModel.user = testUser // postsCount = 5（古い値）

        // When
        await viewModel.loadUserPosts()

        // Then: 取得件数（2）ではなく、集計した 104 が表示される
        XCTAssertEqual(mockFirestoreService.recountPostsCountCallCount, 1)
        XCTAssertEqual(viewModel.user?.postsCount, 104)
        XCTAssertEqual(viewModel.userPosts.count, 2)
    }

    /// ⭐️ 他人のプロフィールでは投稿数を数え直さない（書き込み権限も無い）
    func testLoadUserPosts_他人のプロフィールでは投稿数を数え直さない() async {
        let testUser = createTestUser()
        mockFirestoreService.userPosts = createTestPosts(userId: testUser.id)
        let authService = MockAuthService()
        authService.currentUserValue = User(id: "someone-else", email: "other@example.com")
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService,
            authService: authService
        )
        viewModel.user = testUser

        await viewModel.loadUserPosts()

        XCTAssertEqual(mockFirestoreService.recountPostsCountCallCount, 0)
        XCTAssertEqual(viewModel.user?.postsCount, 5)
    }

    /// ⭐️ 1 ページ目がページサイズぴったりなら「続きあり」、足りなければ「続きなし」
    func testLoadUserPosts_1ページ目の件数で続きの有無が決まる() async {
        let testUser = createTestUser()
        let imageInfo = ImageInfo(url: "https://example.com/image.jpg", width: 1024, height: 768, order: 0)
        let makePost = { (id: String) in
            Post(id: id, userId: testUser.id, images: [imageInfo], caption: nil, visibility: .public)
        }
        let onePost = makePost("post-single")
        let fullPage = (0 ..< ProfileViewModel.postsPageSize).map { makePost("post-\($0)") }
        mockFirestoreService.userPostPages = [fullPage]
        // 本物の AuthService（Auth.auth()）に触れないようモックを注入する（自分のプロフィール扱い）
        let authService = MockAuthService()
        authService.currentUserValue = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService,
            authService: authService
        )

        await viewModel.loadUserPosts()
        XCTAssertTrue(viewModel.hasMorePosts)

        // 引っ張って更新 → 今度は 1 件しか無い
        mockFirestoreService.userPostPages = [[onePost]]
        mockFirestoreService.fetchUserPostsPageCallCount = 0
        await viewModel.loadUserPosts()
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(viewModel.userPosts.count, 1)
    }

    /// ⭐️ 続き読み込み: 2 ページ目が末尾に追記され、境界の重複は除かれ、最終ページで止まる
    func testLoadMoreUserPosts_2ページ目を追記し重複を除き最終ページで止まる() async {
        let testUser = createTestUser()
        let imageInfo = ImageInfo(url: "https://example.com/image.jpg", width: 1024, height: 768, order: 0)
        let makePost = { (id: String) in
            Post(id: id, userId: testUser.id, images: [imageInfo], caption: nil, visibility: .public)
        }
        let fullPage = (0 ..< ProfileViewModel.postsPageSize).map { makePost("post-\($0)") }
        // 2 ページ目の先頭は 1 ページ目の最後と同じ投稿（ページ境界の重複）
        let lastOfFirstPage = "post-\(ProfileViewModel.postsPageSize - 1)"
        let secondPage = [makePost(lastOfFirstPage), makePost("post-a"), makePost("post-b")]
        mockFirestoreService.userPostPages = [fullPage, secondPage]
        let authService = MockAuthService()
        authService.currentUserValue = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService,
            authService: authService
        )

        await viewModel.loadUserPosts()
        XCTAssertTrue(viewModel.hasMorePosts)

        // When: 末尾まで来たので続きを読む
        let added = await viewModel.loadMoreUserPosts()

        // Then: 重複を除いた 2 件だけが末尾に追記され、続きは無くなる
        XCTAssertEqual(added.map(\.id), ["post-a", "post-b"])
        XCTAssertEqual(viewModel.userPosts.count, ProfileViewModel.postsPageSize + 2)
        XCTAssertEqual(viewModel.userPosts.last?.id, "post-b")
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertFalse(viewModel.isLoadingMorePosts)

        // 続きが無いので、もう一度呼んでも取得しない
        let again = await viewModel.loadMoreUserPosts()
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(mockFirestoreService.fetchUserPostsPageCallCount, 2)
    }

    /// ⭐️ 壊れた投稿を飛ばしたページ: 件数が 1 ページ分を割っても、満杯まで読めていれば続きを読む
    func testLoadMoreUserPosts_壊れた投稿を飛ばしたページでも満杯まで読めていれば続きを読む() async {
        let testUser = createTestUser()
        let imageInfo = ImageInfo(url: "https://example.com/image.jpg", width: 1024, height: 768, order: 0)
        let makePost = { (id: String) in
            Post(id: id, userId: testUser.id, images: [imageInfo], caption: nil, visibility: .public)
        }
        // 1 ページ目は 1 ページ分読んだうち 1 件が壊れていて、表示できるのは 1 件少ない
        let firstPage = (0 ..< ProfileViewModel.postsPageSize - 1).map { makePost("post-\($0)") }
        let secondPage = [makePost("post-a"), makePost("post-b")]
        mockFirestoreService.userPostPages = [firstPage, secondPage]
        mockFirestoreService.userPostPageReadCounts = [ProfileViewModel.postsPageSize, secondPage.count]
        let authService = MockAuthService()
        authService.currentUserValue = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService,
            authService: authService
        )

        await viewModel.loadUserPosts()
        XCTAssertEqual(viewModel.userPosts.count, ProfileViewModel.postsPageSize - 1)
        XCTAssertTrue(viewModel.hasMorePosts, "読んだのは満杯の 1 ページ分なので、続きがある")

        // When: 末尾まで来たので続きを読む
        let added = await viewModel.loadMoreUserPosts()

        // Then: 2 ページ目が読まれ、そこで終わる
        XCTAssertEqual(added.map(\.id), ["post-a", "post-b"])
        XCTAssertFalse(viewModel.hasMorePosts)
        XCTAssertEqual(mockFirestoreService.fetchUserPostsPageCallCount, 2)
    }

    func testUpdateProfile() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        viewModel.editingDisplayName = "Updated Name"
        viewModel.editingBio = "Updated Bio"

        // When
        await viewModel.updateProfile()

        // Then
        XCTAssertEqual(viewModel.user?.displayName, "Updated Name")
        XCTAssertEqual(viewModel.user?.bio, "Updated Bio")
    }

    /// 自己紹介文を空にして保存したら、「空にした」ことが Firestore への書き込みに載ること。
    /// nil にすると toFirestoreData が bio のキーを書かず、users は setData(merge: true)・
    /// publicProfiles は「nil は書かない」なので古い自己紹介文が残り、読み込み直すと戻ってしまう
    /// （2026-10-31 アプリ内のご意見で報告）。
    func testUpdateProfile_自己紹介文を空にして保存すると空が書かれる() async {
        // Given: 自己紹介文（"Test bio"）が保存済みのユーザー
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        viewModel.editingBio = ""

        // When
        await viewModel.updateProfile()

        // Then: users への書き込み内容に空の bio が載る（キーが無いと merge で古い値が残る）
        XCTAssertEqual(viewModel.user?.toFirestoreData()["bio"] as? String, "")
        // Then: 公開プロフィールにも空の bio を渡す（nil は「書かない＝古い値が残る」の意味になる）
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.count, 1)
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.first?.bio, "")
    }

    /// 表示名を空にして保存したら、users と公開プロフィールの両方で表示名を「消す」と指定すること。
    /// nil だけだと toFirestoreData が displayName のキーを書かず、users は setData(merge: true)・
    /// 公開プロフィールは「nil は書かない」なので古い表示名が残る（自己紹介文と同じ穴・2026-11-01 にコードで確認）。
    func testUpdateProfile_表示名を空にして保存すると表示名を消す() async {
        // Given: 表示名（"Test User"）が保存済みのユーザー
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        viewModel.editingDisplayName = ""

        // When
        await viewModel.updateProfile()

        // Then: 手元の表示名は消え（画面は「ユーザー」になる）、users と公開プロフィールの両方へ「消す」を渡す
        XCTAssertNil(viewModel.user?.displayName)
        XCTAssertEqual(mockFirestoreService.updateUserClearingCalls, [[.displayName]])
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.count, 1)
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.first?.clearing, [.displayName])
    }

    /// 表示名がスペースだけ（半角・全角）のときも、空と同じく消すこと。
    /// 画面では空欄に見えるのに「ユーザー」にならないため（Android もスペースだけは空として扱う）。
    func testUpdateProfile_表示名がスペースだけなら空と同じく消す() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        viewModel.editingDisplayName = " 　 "

        // When
        await viewModel.updateProfile()

        // Then
        XCTAssertNil(viewModel.user?.displayName)
        XCTAssertEqual(mockFirestoreService.updateUserClearingCalls, [[.displayName]])
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.first?.clearing, [.displayName])
    }

    /// 表示名を入れて保存したときは何も消さず、入れた値をそのまま書くこと（前後の空白も変えない）。
    func testUpdateProfile_表示名を入れて保存したときは消さない() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        viewModel.editingDisplayName = " 空の人 "

        // When
        await viewModel.updateProfile()

        // Then
        XCTAssertEqual(viewModel.user?.displayName, " 空の人 ")
        XCTAssertEqual(mockFirestoreService.updateUserClearingCalls, [[]])
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.first?.displayName, " 空の人 ")
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.first?.clearing, [])
    }

    /// アイコンを削除して保存したら、users と公開プロフィールの両方でアイコンを「消す」と指定すること。
    /// nil だけだと古い photoURL（Storage では先に消した写真）が残り、壊れた画像を指したままになる。
    func testUpdateProfile_アイコンを削除して保存するとアイコンを消す() async {
        // Given: アイコン（photoURL）が保存済みのユーザー
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        // テストでは自分のプロフィール扱いにならず loadProfile が入力欄を埋めないので、
        // 画面と同じく保存済みの表示名を入れておく（入れないと表示名まで「消す」になる）
        viewModel.editingDisplayName = testUser.displayName ?? ""
        viewModel.shouldDeleteProfileImage = true

        // When
        await viewModel.updateProfile()

        // Then: 手元のアイコンは消え、users と公開プロフィールの両方へ「消す」を渡す（表示名は消さない）
        XCTAssertNil(viewModel.user?.photoURL)
        XCTAssertEqual(viewModel.user?.displayName, "Test User")
        XCTAssertEqual(mockFirestoreService.updateUserClearingCalls, [[.photoURL]])
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.count, 1)
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.first?.clearing, [.photoURL])
    }

    /// プロフィール編集を保存せずに閉じたら、入力（表示名・自己紹介・画像・画像削除の指定）が
    /// 保存済みの値に戻ること。戻さないと次に開いたとき入力途中の値が残る（2026-10-07 シミュレータで実測）。
    func testResetProfileEdit_保存せずに閉じたら入力が保存済みの値に戻る() {
        // Given: 保存済みのプロフィールがあり、入力を途中まで変えた状態
        let testUser = createTestUser()
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        viewModel.user = testUser
        viewModel.editingDisplayName = "入力途中の名前"
        viewModel.editingBio = "入力途中の自己紹介"
        viewModel.editingProfileImage = UIImage()
        viewModel.shouldDeleteProfileImage = true

        // When
        viewModel.resetProfileEdit()

        // Then: 保存済みの値に戻り、画像の変更・削除の指定も取り消される
        XCTAssertEqual(viewModel.editingDisplayName, "Test User")
        XCTAssertEqual(viewModel.editingBio, "Test bio")
        XCTAssertNil(viewModel.editingProfileImage)
        XCTAssertFalse(viewModel.shouldDeleteProfileImage)
        // 保存はしない（保存済みのプロフィールは変わらず、公開プロフィールへの書き込みも無い）
        XCTAssertEqual(viewModel.user?.displayName, "Test User")
        XCTAssertTrue(mockFirestoreService.updatePublicProfileFieldsCalls.isEmpty)
    }

    /// 表示名・自己紹介が未設定（nil）のユーザーでは、戻した後の入力は空になること。
    func testResetProfileEdit_未設定の項目は空に戻る() {
        // Given
        var testUser = createTestUser()
        testUser.displayName = nil
        testUser.bio = nil
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        viewModel.user = testUser
        viewModel.editingDisplayName = "入力途中"
        viewModel.editingBio = "入力途中"

        // When
        viewModel.resetProfileEdit()

        // Then
        XCTAssertEqual(viewModel.editingDisplayName, "")
        XCTAssertEqual(viewModel.editingBio, "")
    }

    func testUpdateProfileWithImage() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        let testImage = UIImage(systemName: "photo")!
        viewModel.editingProfileImage = testImage
        viewModel.editingDisplayName = "Updated Name"

        // When
        await viewModel.updateProfile()

        // Then
        XCTAssertNotNil(mockStorageService.uploadedImage)
        XCTAssertEqual(viewModel.user?.displayName, "Updated Name")
    }

    /// 回帰テスト ⭐️: 大きい写真を選んでも、長辺 1024px 以下に縮小してから送ること
    ///
    /// 以前は元の解像度のまま送っていたため、JPEG にすると 5MB を超えて
    /// 「画像サイズが大きすぎます」で保存できないことがあった（1.11.0 で 5 人）。
    func testUpdateProfileResizesLargeImageBeforeUpload() async throws {
        // Given: 3000×2000px の写真（scale 1 ＝ size がそのままピクセル数）
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let largeImage = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        viewModel.editingProfileImage = largeImage

        // When
        await viewModel.updateProfile()

        // Then: 送られた画像の長辺が上限（1024px）まで縮んでいる
        let uploaded = try XCTUnwrap(mockStorageService.uploadedImage)
        let longSidePixels = max(uploaded.size.width, uploaded.size.height) * uploaded.scale
        XCTAssertEqual(longSidePixels, ProfileViewModel.profileImageMaxDimension, accuracy: 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 回帰テスト ⭐️: 「画像が大きすぎる」は何度送っても必ず失敗するので、再試行せず 1 回で諦めること
    ///
    /// 以前は systemError 扱いで 3 回再試行し、そのあいだ待たされたうえでエラーになっていた。
    func testUpdateProfileDoesNotRetryImageTooLarge() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        mockStorageService.uploadError = StorageServiceError.imageTooLarge
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        viewModel.editingProfileImage = UIImage(systemName: "photo")!

        // When
        await viewModel.updateProfile()

        // Then
        XCTAssertEqual(mockStorageService.uploadCallCount, 1)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// 上のテストの対照: 通信などで起きる他の保存エラーは、今まで通り再試行すること
    /// （分類の変更が「画像が大きすぎる」以外に広がっていないことの確認）
    func testUpdateProfileStillRetriesOtherStorageErrors() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        mockStorageService.uploadError = StorageServiceError.uploadFailed(
            NSError(domain: "test", code: -1)
        )
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        viewModel.editingProfileImage = UIImage(systemName: "photo")!

        // When
        await viewModel.updateProfile()

        // Then: 初回 1 回＋再試行 3 回で合計 4 回
        // （RetryableOperation.executeIfRetryable がまず 1 回試し、失敗すると ErrorHandler.retry が
        //   maxAttempts=3 回試す。この回数は今回の変更前から同じ）
        XCTAssertEqual(mockStorageService.uploadCallCount, 4)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// 回帰テスト ⭐️: プロフィール更新が publicProfiles のフォローカウンタを書き換えないこと
    ///
    /// PublicProfile 全体書き込みは、クライアントが持つ古い followersCount /
    /// followingCount で Cloud Functions が保った真値を潰すため経路ごと廃止した
    /// （メソッド自体を型から削除済み＝呼び出しはコンパイラが構造的に禁止する）。
    /// ここでは残った唯一の経路であるターゲット更新が、編集対象フィールドだけを
    /// 渡していることを確認する。
    func testUpdateProfileDoesNotWriteFollowCounters() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        viewModel.editingDisplayName = "Updated Name"
        viewModel.editingBio = "Updated Bio"

        // When
        await viewModel.updateProfile()

        // Then: 編集対象フィールドだけがターゲット更新される
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.count, 1)
        let call = mockFirestoreService.updatePublicProfileFieldsCalls.first
        XCTAssertEqual(call?.userId, testUser.id)
        XCTAssertEqual(call?.displayName, "Updated Name")
        XCTAssertEqual(call?.bio, "Updated Bio")
        XCTAssertEqual(call?.photoURL, testUser.photoURL)

        // Then: 既存ドキュメントがある場合は新規作成にフォールバックしない
        XCTAssertFalse(mockFirestoreService.createPublicProfileCalled)
    }

    /// publicProfiles ドキュメント未作成（マイグレーション未実施）ユーザーは
    /// notFound を受けて createPublicProfile にフォールバックすること ⭐️
    func testUpdateProfileFallsBackToCreateWhenPublicProfileMissing() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        mockFirestoreService.updatePublicProfileFieldsError = FirestoreServiceError.notFound
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        viewModel.editingDisplayName = "Updated Name"

        // When
        await viewModel.updateProfile()

        // Then
        XCTAssertTrue(mockFirestoreService.createPublicProfileCalled)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// notFound 以外の失敗では新規作成にフォールバックせず、エラーとして見せること ⭐️
    ///
    /// `updatePublicProfileFields` は「更新失敗 → publicProfiles の存在確認 →
    /// 不在なら notFound ／ 存在するなら updateFailed」という構造になっている。
    /// updateFailed は「ドキュメントは在るのに書けなかった」＝ createPublicProfile で
    /// 作り直すと Cloud Functions が保つカウンタを古い値で潰しかねないため、
    /// フォールバック経路に流してはいけない。
    func testUpdateProfileDoesNotFallBackToCreateOnUpdateFailure() async {
        // Given: 更新が updateFailed（存在するが書き込めなかった）で失敗する
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        mockFirestoreService.updatePublicProfileFieldsError = FirestoreServiceError.updateFailed(
            NSError(
                domain: "FIRFirestoreErrorDomain",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "permission denied"]
            )
        )
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        viewModel.editingDisplayName = "Updated Name"

        // When
        await viewModel.updateProfile()

        // Then: 新規作成へのフォールバックは notFound のときだけ
        XCTAssertFalse(
            mockFirestoreService.createPublicProfileCalled,
            "updateFailed で createPublicProfile に流すと、サーバーが保つカウンタを潰しかねない"
        )

        // Then: 失敗を握りつぶさずユーザーに見せる
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// 回帰テスト ⭐️: 保存できたら、他の画面（そらとも）へ新しい表示名とアイコンを知らせる
    ///
    /// 以前は知らせなかったため、そらとものタイムラインは再起動するまで古い表示名のままだった。
    func testUpdateProfilePostsProfileUpdatedNotification() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        viewModel.editingDisplayName = "天名"

        let notified = expectation(forNotification: .profileUpdated, object: nil) { notification in
            let userInfo = notification.userInfo
            return userInfo?[Notification.profileUpdatedUserIdKey] as? String == testUser.id
                && userInfo?[Notification.profileUpdatedDisplayNameKey] as? String == "天名"
                && userInfo?[Notification.profileUpdatedPhotoURLKey] as? String == testUser.photoURL
        }

        // When
        await viewModel.updateProfile()

        // Then
        await fulfillment(of: [notified], timeout: 1)
    }

    /// 公開プロフィールを書けなかったときは知らせない（そらともの表示だけ新しい名前になる、を防ぐ）
    func testUpdateProfileDoesNotPostProfileUpdatedNotificationOnFailure() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        mockFirestoreService.updatePublicProfileFieldsError = FirestoreServiceError.updateFailed(
            NSError(domain: "FIRFirestoreErrorDomain", code: 7)
        )
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()
        viewModel.editingDisplayName = "天名"

        let notified = expectation(forNotification: .profileUpdated, object: nil)
        notified.isInverted = true

        // When
        await viewModel.updateProfile()

        // Then
        XCTAssertNotNil(viewModel.errorMessage)
        await fulfillment(of: [notified], timeout: 0.5)
    }

    func testLoadEditTools() async {
        // Given
        let testUser = createTestUser(
            customEditTools: ["exposure", "brightness", "contrast"],
            customEditToolsOrder: ["exposure", "brightness", "contrast"]
        )
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When
        await viewModel.loadProfile()

        // Then
        XCTAssertFalse(viewModel.equippedTools.isEmpty)
        XCTAssertEqual(viewModel.equippedTools.count, 3)
    }

    func testUpdateEditTools() async {
        // Given
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        // 5個のツールを選択（最小値）
        viewModel.selectedTools = Array(EditTool.allCases.prefix(5))

        // When
        await viewModel.updateEditTools()

        // Then
        XCTAssertEqual(viewModel.equippedTools.count, 5)
        XCTAssertTrue(mockFirestoreService.updateEditToolsCalled)
    }

    func testUpdateEditToolsAllToolsOrder() async {
        // Given - 全ツール表示モードではバリデーションエラーなし
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        await viewModel.loadProfile()

        // When - 全ツールの順序を保存
        viewModel.selectedTools = EditTool.allCases
        await viewModel.updateEditTools()

        // Then - エラーなし
        XCTAssertNil(viewModel.errorMessage)
    }

    func testMoveEditTool() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )
        viewModel.selectedTools = EditTool.allCases
        let firstTool = viewModel.selectedTools[0]

        // When - 先頭のツールを2番目に移動
        viewModel.moveEditTool(from: IndexSet(integer: 0), to: 2)

        // Then - 先頭のツールが移動している
        XCTAssertEqual(viewModel.selectedTools[1], firstTool)
    }

    func testSelectedToolsContainsAll27Tools() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // Then - 全27ツールが常に選択状態
        XCTAssertEqual(viewModel.selectedTools.count, EditTool.allCases.count)
    }

    func testIsValidEditToolsSelectionAlwaysTrue() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // Then - 全ツール表示のため常にtrue
        XCTAssertTrue(viewModel.isValidEditToolsSelection)
    }

    func testIsValidEditToolsSelection_legacy() {
        // Given
        viewModel = ProfileViewModel(
            userId: "test-user-id",
            firestoreService: mockFirestoreService,
            storageService: mockStorageService
        )

        // When & Then - 全ツール表示のため常に有効
        XCTAssertTrue(viewModel.isValidEditToolsSelection)
        viewModel.selectedTools = Array(EditTool.allCases.prefix(9))
        XCTAssertTrue(viewModel.isValidEditToolsSelection)
    }

    // MARK: - プロフィールに表示するもの（見せる/見せない）⭐️

    /// 編集画面を開いたら、自分の公開プロフィールの値を読み、スイッチを押せる状態にする
    func testLoadSectionVisibilityForEdit_公開プロフィールの値を読む() async {
        let testUser = setUpOwnProfile()
        mockFirestoreService.publicProfile = PublicProfile(
            id: testUser.id,
            sectionVisibility: ProfileSectionVisibility(
                showsRecommendedSkies: false,
                showsSkyCalendar: true,
                showsFavorites: false
            )
        )

        await viewModel.loadSectionVisibilityForEdit()

        XCTAssertFalse(viewModel.editingSectionVisibility.showsRecommendedSkies)
        XCTAssertTrue(viewModel.editingSectionVisibility.showsSkyCalendar)
        XCTAssertFalse(viewModel.editingSectionVisibility.showsFavorites)
        XCTAssertTrue(viewModel.canEditSectionVisibility)
        XCTAssertFalse(viewModel.sectionVisibilityLoadFailed)
    }

    /// 公開プロフィールの文書がまだ無い（notFound）→ 既定値で押せる状態にする
    /// （押せなくすると、その人は永久に ON にできない）
    func testLoadSectionVisibilityForEdit_文書が無ければ既定値で押せる() async {
        setUpOwnProfile()
        mockFirestoreService.fetchPublicProfileError = FirestoreServiceError.notFound
        // 前に開いたときの値が残っていても、既定値に置き換わることを確かめるため、既定値と逆の値から始める
        viewModel.editingSectionVisibility = ProfileSectionVisibility(
            showsRecommendedSkies: false,
            showsSkyCalendar: true,
            showsFavorites: true
        )

        await viewModel.loadSectionVisibilityForEdit()

        XCTAssertTrue(viewModel.editingSectionVisibility.showsRecommendedSkies)
        XCTAssertFalse(viewModel.editingSectionVisibility.showsSkyCalendar)
        XCTAssertFalse(viewModel.editingSectionVisibility.showsFavorites)
        XCTAssertTrue(viewModel.canEditSectionVisibility)
        XCTAssertFalse(viewModel.sectionVisibilityLoadFailed)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// notFound 以外で読めなかった → 押せない状態・「読み込めませんでした」。
    /// 編集画面の alert（errorMessage）は出さず、「保存」も押せるまま（isLoading を立てない）
    func testLoadSectionVisibilityForEdit_読み込みに失敗したら押せない() async {
        setUpOwnProfile()
        // 再試行しない種類のエラーにする（FirestoreServiceError.fetchFailed だと 1 秒・2 秒待って再試行するため）
        mockFirestoreService.fetchPublicProfileError = NSError(domain: "test", code: 14)

        await viewModel.loadSectionVisibilityForEdit()

        XCTAssertFalse(viewModel.canEditSectionVisibility)
        XCTAssertTrue(viewModel.sectionVisibilityLoadFailed)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    /// 保存: 読み込んだ値から変わった欄だけを書く（渡った辞書を直に比べる）。
    /// 書けたら、同じ画面でもう一度「保存」しても同じ欄を書き直さない
    func testUpdateProfile_変わった欄だけを書く() async {
        let testUser = setUpOwnProfile()
        // 項目なし＝既定値（おすすめ＝見せる・カレンダー＝見せない・お気に入り＝見せない）
        mockFirestoreService.publicProfile = PublicProfile(id: testUser.id)
        await viewModel.loadSectionVisibilityForEdit()
        viewModel.editingSectionVisibility.showsSkyCalendar = true

        await viewModel.updateProfile()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(mockFirestoreService.updateProfileSectionVisibilityUserIds, ["test-user-id"])
        XCTAssertEqual(mockFirestoreService.updateProfileSectionVisibilitySections, [[.skyCalendar: true]])
        XCTAssertEqual(mockFirestoreService.createPublicProfileIfMissingCallCount, 0)

        // もう一度保存しても、もう書いた欄は書き直さない
        await viewModel.updateProfile()

        XCTAssertEqual(mockFirestoreService.updateProfileSectionVisibilitySections, [[.skyCalendar: true]])
    }

    /// 3 つとも変えたら、3 つとも 1 回の書き込みで渡る（欄ごとの値も直に）
    func testUpdateProfile_3つとも変えたら3つとも1回で書く() async {
        let testUser = setUpOwnProfile()
        mockFirestoreService.publicProfile = PublicProfile(id: testUser.id)
        await viewModel.loadSectionVisibilityForEdit()
        viewModel.editingSectionVisibility = ProfileSectionVisibility(
            showsRecommendedSkies: false,
            showsSkyCalendar: true,
            showsFavorites: true
        )

        await viewModel.updateProfile()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            mockFirestoreService.updateProfileSectionVisibilitySections,
            [[.recommendedSkies: false, .skyCalendar: true, .favorites: true]]
        )
    }

    /// 変わっていなければ書かない（切り替えて戻した＝読んだときと同じ値）。表示名などの保存は今までどおり
    func testUpdateProfile_変わっていなければ書かない() async {
        let testUser = setUpOwnProfile()
        mockFirestoreService.publicProfile = PublicProfile(
            id: testUser.id,
            sectionVisibility: ProfileSectionVisibility(
                showsRecommendedSkies: true,
                showsSkyCalendar: true,
                showsFavorites: false
            )
        )
        await viewModel.loadSectionVisibilityForEdit()
        viewModel.editingSectionVisibility.showsFavorites = true
        viewModel.editingSectionVisibility.showsFavorites = false

        await viewModel.updateProfile()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(mockFirestoreService.updateProfileSectionVisibilitySections, [])
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.count, 1)
    }

    /// 公開プロフィールの文書が無い（notFound）→ 無いときだけ作って（createPublicProfileIfMissing）→ もう一度書く。
    /// 呼ばれた順と、2 回とも同じ欄を書くことを直に確かめる
    func testUpdateProfile_文書が無ければ作ってから書き直す() async {
        setUpOwnProfile()
        mockFirestoreService.fetchPublicProfileError = FirestoreServiceError.notFound
        await viewModel.loadSectionVisibilityForEdit()
        viewModel.editingSectionVisibility.showsFavorites = true
        mockFirestoreService.updateProfileSectionVisibilityErrors = [FirestoreServiceError.notFound]

        await viewModel.updateProfile()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(mockFirestoreService.sectionVisibilityWriteLog, ["update", "createIfMissing", "update"])
        XCTAssertEqual(mockFirestoreService.updateProfileSectionVisibilitySections, [[.favorites: true], [.favorites: true]])
        XCTAssertEqual(mockFirestoreService.createPublicProfileIfMissingCallCount, 1)
        // 丸ごと上書きの createPublicProfile には流さない（別の端末が同時に作った値を消さないため）
        XCTAssertFalse(mockFirestoreService.createPublicProfileCalled)
    }

    /// 読み込みに失敗したときは、スイッチの値がどうであっても書かない（読めていない値で上書きしない）。
    /// 表示名などの保存は今までどおり行う
    func testUpdateProfile_読み込みに失敗したときは書かない() async {
        setUpOwnProfile()
        mockFirestoreService.fetchPublicProfileError = NSError(domain: "test", code: 14)
        await viewModel.loadSectionVisibilityForEdit()
        // 押せない状態でも、値が既定値から変わっていたとする
        viewModel.editingSectionVisibility = ProfileSectionVisibility(
            showsRecommendedSkies: false,
            showsSkyCalendar: true,
            showsFavorites: true
        )

        await viewModel.updateProfile()

        XCTAssertEqual(mockFirestoreService.updateProfileSectionVisibilitySections, [])
        XCTAssertEqual(mockFirestoreService.sectionVisibilityWriteLog, [])
        XCTAssertEqual(mockFirestoreService.updatePublicProfileFieldsCalls.count, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// まだ読んでいない（編集画面の読み込みが走る前）も書かない
    func testUpdateProfile_まだ読んでいなければ書かない() async {
        setUpOwnProfile()
        viewModel.editingSectionVisibility = ProfileSectionVisibility(
            showsRecommendedSkies: false,
            showsSkyCalendar: true,
            showsFavorites: true
        )

        await viewModel.updateProfile()

        XCTAssertEqual(mockFirestoreService.updateProfileSectionVisibilitySections, [])
        XCTAssertNil(viewModel.errorMessage)
    }

    /// 見せる/見せない の書き込みに失敗 → errorMessage に出す。比べる元は変えないので、
    /// もう一度「保存」すると同じ欄を書き直す
    func testUpdateProfile_見せる見せないの書き込みに失敗したらエラーを出し次の保存で書き直す() async {
        let testUser = setUpOwnProfile()
        mockFirestoreService.publicProfile = PublicProfile(id: testUser.id)
        await viewModel.loadSectionVisibilityForEdit()
        viewModel.editingSectionVisibility.showsSkyCalendar = true
        // 再試行しない種類のエラーにする（待たないため）
        mockFirestoreService.updateProfileSectionVisibilityErrors = [NSError(domain: "test", code: 7)]

        await viewModel.updateProfile()

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(mockFirestoreService.updateProfileSectionVisibilitySections, [[.skyCalendar: true]])

        // When: もう一度保存する（今度は書ける）
        viewModel.errorMessage = nil
        await viewModel.updateProfile()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(
            mockFirestoreService.updateProfileSectionVisibilitySections,
            [[.skyCalendar: true], [.skyCalendar: true]]
        )
    }

    /// 見せる/見せない の書き込みに失敗しても、表示名とアイコンはもう保存できているので、
    /// そらともへの通知（.profileUpdated）は出す
    func testUpdateProfile_見せる見せないの書き込みに失敗しても表示名の通知は出す() async {
        let testUser = setUpOwnProfile()
        mockFirestoreService.publicProfile = PublicProfile(id: testUser.id)
        await viewModel.loadSectionVisibilityForEdit()
        viewModel.editingSectionVisibility.showsFavorites = true
        viewModel.editingDisplayName = "天名"
        mockFirestoreService.updateProfileSectionVisibilityErrors = [NSError(domain: "test", code: 7)]
        let notified = expectation(forNotification: .profileUpdated, object: nil) { notification in
            notification.userInfo?[Notification.profileUpdatedDisplayNameKey] as? String == "天名"
        }

        await viewModel.updateProfile()

        XCTAssertNotNil(viewModel.errorMessage)
        await fulfillment(of: [notified], timeout: 1)
    }

    /// 保存せずに閉じたら、見せる/見せない のスイッチも読み込んだ値に戻る
    func testResetProfileEdit_見せる見せないも読み込んだ値に戻る() async {
        let testUser = setUpOwnProfile()
        mockFirestoreService.publicProfile = PublicProfile(
            id: testUser.id,
            sectionVisibility: ProfileSectionVisibility(
                showsRecommendedSkies: true,
                showsSkyCalendar: true,
                showsFavorites: false
            )
        )
        await viewModel.loadSectionVisibilityForEdit()
        viewModel.editingSectionVisibility = ProfileSectionVisibility(
            showsRecommendedSkies: false,
            showsSkyCalendar: false,
            showsFavorites: true
        )

        viewModel.resetProfileEdit()

        XCTAssertTrue(viewModel.editingSectionVisibility.showsRecommendedSkies)
        XCTAssertTrue(viewModel.editingSectionVisibility.showsSkyCalendar)
        XCTAssertFalse(viewModel.editingSectionVisibility.showsFavorites)
        XCTAssertEqual(mockFirestoreService.updateProfileSectionVisibilitySections, [])
    }

    // MARK: - Helper Methods

    /// 自分のプロフィールの ViewModel を `viewModel` に用意する（見せる/見せない のテスト用）⭐️
    ///
    /// 本物の AuthService（Auth.auth()）に触れないようモックを注入し、保存済みのユーザーを入れておく
    /// （updateProfile は `user` が無いと何もしないため）。
    @discardableResult
    private func setUpOwnProfile() -> User {
        let testUser = createTestUser()
        mockFirestoreService.user = testUser
        let authService = MockAuthService()
        authService.currentUserValue = testUser
        viewModel = ProfileViewModel(
            userId: testUser.id,
            firestoreService: mockFirestoreService,
            storageService: mockStorageService,
            authService: authService
        )
        viewModel.user = testUser
        return testUser
    }

    private func createTestUser(
        customEditTools: [String]? = nil,
        customEditToolsOrder: [String]? = nil
    ) -> User {
        User(
            id: "test-user-id",
            email: "test@example.com",
            displayName: "Test User",
            photoURL: "https://example.com/photo.jpg",
            bio: "Test bio",
            customEditTools: customEditTools,
            customEditToolsOrder: customEditToolsOrder,
            followersCount: 10,
            followingCount: 20,
            postsCount: 5
        )
    }

    private func createTestPosts(userId: String) -> [Post] {
        let imageInfo = ImageInfo(
            url: "https://example.com/image.jpg",
            width: 1024,
            height: 768,
            order: 0
        )

        return [
            Post(
                id: UUID().uuidString,
                userId: userId,
                images: [imageInfo],
                caption: "Test caption",
                visibility: .public
            ),
            Post(
                id: UUID().uuidString,
                userId: userId,
                images: [imageInfo],
                caption: "Test caption 2",
                visibility: .public
            ),
        ]
    }
}

// MARK: - Mock Services

class MockFirestoreServiceForProfile: FirestoreServiceProtocol {
    var user: User?
    var userPosts: [Post] = []
    var updateEditToolsCalled = false
    /// ターゲット更新（updatePublicProfileFields）に渡された引数の記録 ⭐️
    var updatePublicProfileFieldsCalls: [(userId: String, displayName: String?, photoURL: String?, bio: String?, clearing: Set<ProfileClearableField>)] = []
    /// updateUser(_:clearing:) に渡された「消す項目」の記録（呼ばれた順）⭐️
    var updateUserClearingCalls: [Set<ProfileClearableField>] = []
    /// updatePublicProfileFields が投げるエラー（notFound フォールバック検証用） ⭐️
    var updatePublicProfileFieldsError: Error?
    /// createPublicProfile が呼ばれたか（フォールバック検証用） ⭐️
    var createPublicProfileCalled = false
    /// fetchPublicProfile が返す公開プロフィール（nil なら fetchPublicProfileError を投げる）⭐️
    var publicProfile: PublicProfile?
    /// fetchPublicProfile が投げるエラー（publicProfile が nil のとき。nil なら今までどおり notFound）⭐️
    var fetchPublicProfileError: Error?
    /// updateProfileSectionVisibility に渡された userId（呼ばれた順）⭐️
    var updateProfileSectionVisibilityUserIds: [String] = []
    /// updateProfileSectionVisibility に渡された欄と値（呼ばれた順）⭐️
    var updateProfileSectionVisibilitySections: [[ProfileSection: Bool]] = []
    /// updateProfileSectionVisibility が投げるエラー（呼ばれるたびに先頭から 1 つ使う・空なら成功）⭐️
    var updateProfileSectionVisibilityErrors: [Error] = []
    /// createPublicProfileIfMissing が呼ばれた回数 ⭐️
    var createPublicProfileIfMissingCallCount = 0
    /// 見せる/見せない の保存で呼ばれた順（"update" = updateProfileSectionVisibility・"createIfMissing" = createPublicProfileIfMissing）⭐️
    var sectionVisibilityWriteLog: [String] = []

    func fetchUser(userId _: String) async throws -> User {
        guard let user else {
            throw FirestoreServiceError.notFound
        }
        return user
    }

    func updateUser(_ user: User) async throws -> User {
        user
    }

    func updateUser(_ user: User, clearing fields: Set<ProfileClearableField>) async throws -> User {
        updateUserClearingCalls.append(fields)
        return user
    }

    func updateEditTools(userId _: String, tools _: [EditTool], order _: [String]) async throws {
        updateEditToolsCalled = true
    }

    func fetchUserPosts(userId _: String, limit _: Int, lastDocument _: DocumentSnapshot?) async throws -> [Post] {
        userPosts
    }

    /// fetchUserPostsPage が返すページ（未設定なら userPosts を 1 ページで返す）⭐️
    var userPostPages: [[Post]]?
    /// userPostPages の各ページで Firestore から実際に読んだドキュメント数（壊れた投稿も含む）。
    /// 壊れた投稿を飛ばしたページの再現用。未設定ならページの投稿数と同じ（＝壊れた投稿なし）
    var userPostPageReadCounts: [Int]?
    /// fetchUserPostsPage が呼ばれた回数
    var fetchUserPostsPageCallCount = 0
    /// recountPostsCount が返す「全投稿数」（nil なら userPosts.count）⭐️
    var recountedPostsCount: Int?
    /// recountPostsCount が呼ばれた回数
    var recountPostsCountCallCount = 0

    func fetchUserPostsPage(userId _: String, limit: Int, lastDocument _: DocumentSnapshot?) async throws -> PostPage {
        defer { fetchUserPostsPageCallCount += 1 }
        // 本番（PostPage(posts:snapshot:limit:)）と同じく、読んだ件数で続きの有無を決める
        guard let pages = userPostPages else {
            return PostPage(posts: userPosts, lastDocument: nil, isExhausted: userPosts.count < limit)
        }
        let index = fetchUserPostsPageCallCount
        let page = index < pages.count ? pages[index] : []
        let readCount = userPostPageReadCounts.flatMap { index < $0.count ? $0[index] : nil } ?? page.count
        return PostPage(posts: page, lastDocument: nil, isExhausted: readCount < limit)
    }

    func recountPostsCount(userId _: String) async throws -> Int {
        recountPostsCountCallCount += 1
        return recountedPostsCount ?? userPosts.count
    }

    // その他のメソッドは空実装
    func createPost(_ post: Post) async throws -> Post { post }
    func fetchPosts(limit _: Int, lastDocument _: DocumentSnapshot?) async throws -> [Post] { [] }
    func fetchPostsWithSnapshot(limit _: Int, lastDocument _: DocumentSnapshot?) async throws -> PostPage { PostPage(posts: [], lastDocument: nil, isExhausted: true) }
    func fetchPost(postId _: String) async throws -> Post { throw FirestoreServiceError.notFound }
    func deletePost(postId _: String, userId _: String) async throws {}
    func saveDraft(_ draft: Draft) async throws -> Draft { draft }
    func fetchDrafts(userId _: String) async throws -> [Draft] { [] }
    func loadDraft(draftId _: String) async throws -> Draft { throw FirestoreServiceError.notFound }
    func deleteDraft(draftId _: String) async throws {}
    func searchByHashtag(_: String) async throws -> [Post] { [] }
    func searchByColor(_: String, threshold _: Double?) async throws -> [Post] { [] }
    func searchByTimeOfDay(_: TimeOfDay) async throws -> [Post] { [] }
    func searchBySkyType(_: SkyType) async throws -> [Post] { [] }
    func searchPosts(
        hashtag _: String?,
        color _: String?,
        timeOfDay _: TimeOfDay?,
        skyType _: SkyType?,
        colorThreshold _: Double?,
        limit _: Int
    ) async throws -> [Post] { [] }
    func fetchPublicProfile(userId _: String) async throws -> PublicProfile {
        if let publicProfile {
            return publicProfile
        }
        throw fetchPublicProfileError ?? FirestoreServiceError.notFound
    }

    func updatePublicProfileFields(userId: String, displayName: String?, photoURL: String?, bio: String?, clearing fields: Set<ProfileClearableField>) async throws {
        updatePublicProfileFieldsCalls.append((userId: userId, displayName: displayName, photoURL: photoURL, bio: bio, clearing: fields))
        if let error = updatePublicProfileFieldsError {
            throw error
        }
    }

    func createPublicProfile(from _: User) async throws { createPublicProfileCalled = true }

    func updateProfileSectionVisibility(userId: String, sections: [ProfileSection: Bool]) async throws {
        sectionVisibilityWriteLog.append("update")
        updateProfileSectionVisibilityUserIds.append(userId)
        updateProfileSectionVisibilitySections.append(sections)
        if !updateProfileSectionVisibilityErrors.isEmpty {
            throw updateProfileSectionVisibilityErrors.removeFirst()
        }
    }

    func createPublicProfileIfMissing(from _: User) async throws {
        sectionVisibilityWriteLog.append("createIfMissing")
        createPublicProfileIfMissingCallCount += 1
    }

    func deleteUserData(userId _: String) async throws {}
    func reportPost(postId _: String, reporterId _: String, reportedUserId _: String, reason _: String) async throws {}
    func blockUser(userId _: String, blockedUserId _: String) async throws {}
    func unblockUser(userId _: String, blockedUserId _: String) async throws {}
    func fetchBlockedUserIds(userId _: String) async throws -> [String] { [] }
}

class MockStorageServiceForProfile: StorageServiceProtocol {
    var uploadedImage: UIImage?
    /// uploadImage で投げるエラー（nil なら成功）
    var uploadError: Error?
    /// uploadImage が呼ばれた回数（再試行の有無の確認用）
    var uploadCallCount = 0

    func uploadImage(_ image: UIImage, path _: String) async throws -> URL {
        uploadCallCount += 1
        if let uploadError {
            throw uploadError
        }
        uploadedImage = image
        return URL(string: "https://example.com/uploaded.jpg")!
    }

    func uploadThumbnail(_: UIImage, path _: String) async throws -> URL {
        URL(string: "https://example.com/thumbnail.jpg")!
    }

    func deleteImage(path _: String) async throws {}
    func uploadProgress(path _: String) -> AsyncStream<Double> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
