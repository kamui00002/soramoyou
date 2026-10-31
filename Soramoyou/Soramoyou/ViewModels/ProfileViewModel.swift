//
//  ProfileViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Combine
import FirebaseFirestore
import Foundation
import os
import UIKit

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.soramoyou.photo-editor",
    category: "ProfileViewModel"
)

@MainActor
class ProfileViewModel: ObservableObject {
    @Published var user: User?
    @Published var userPosts: [Post] = []
    @Published var equippedTools: [EditTool] = []
    @Published var isLoading = false
    @Published var isLoadingPosts = false
    /// 投稿グリッドの続き（次ページ）を読み込み中か
    @Published private(set) var isLoadingMorePosts = false
    /// まだ読んでいない投稿が残っているか（false になったら追加読み込みしない）
    @Published private(set) var hasMorePosts = false
    @Published var errorMessage: String?

    // 編集用の一時的な値
    @Published var editingDisplayName: String = ""
    @Published var editingBio: String = ""
    @Published var editingProfileImage: UIImage?
    @Published var shouldDeleteProfileImage: Bool = false // プロフィール画像を削除するかどうか

    // プロフィールに表示するもの（見せる/見せない）⭐️
    /// 編集画面のスイッチの値（「保存」を押すまでサーバーには書かない）
    @Published var editingSectionVisibility: ProfileSectionVisibility = .default
    /// 編集画面を開いたときに自分の `publicProfiles` から読んだ値の状態
    ///
    /// `.loaded(値)` の値が「保存のときに比べる元」（ここから変わった欄だけを書く）。
    /// `.idle` / `.loading` / `.error` の間は比べる元が無い＝スイッチを押せなくし、保存しても書かない
    /// （読めていない値で上書きしないため）。
    @Published private(set) var sectionVisibilityLoadState: LoadableState<ProfileSectionVisibility> = .idle
    /// 見せる/見せない の読み込みの世代。読み込みのたびに進め、await 中に世代が変わった古い結果は捨てる
    /// （編集画面を閉じてすぐ開き直したとき、前の読み込みの結果で新しい状態を上書きしないため）
    private var sectionVisibilityLoadGeneration = 0

    // 編集装備システムの管理（全27ツールの並び替え）
    @Published var availableTools: [EditTool] = EditTool.allCases
    @Published var selectedTools: [EditTool] = EditTool.allCases // 全ツールを常に選択状態
    @Published var toolsOrder: [String] = []

    /// Auth復元後にuserIdを再取得できるようvarに変更
    private var userId: String?
    /// 外部から指定されたuserIdかどうか（自分のプロフィール判定用）
    private let isExternalUserId: Bool
    private let firestoreService: FirestoreServiceProtocol
    private let storageService: StorageServiceProtocol
    /// 認証サービス（Firebase直参照を排除し、テスタビリティを向上）
    private let authService: AuthServiceProtocol
    /// 画像処理サービス（プロフィール画像をアップロード前に縮小する）
    private let imageService: ImageServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    /// プロフィール画像をアップロードするときの長辺の上限（px）
    static let profileImageMaxDimension: CGFloat = 1024

    /// 投稿グリッドの 1 ページあたりの件数
    static let postsPageSize = 50
    /// 次ページ取得用のカーソル（直前ページで最後に読んだドキュメント）
    private var postsCursor: DocumentSnapshot?
    /// 投稿一覧の取得世代。loadUserPosts のたびに進め、await 中に世代が変わった
    /// 追加読み込みの結果は新しい一覧へ混ぜずに捨てる（PaginatedPostsViewModel と同じ流儀）。
    private var postsGeneration = 0
    /// 投稿作成通知の購読を保持
    private var postCreatedObserver: NSObjectProtocol?

    // 自分のプロフィールかどうか
    var isOwnProfile: Bool {
        guard let userId,
              let currentUserId = authService.currentUser()?.id
        else {
            return false
        }
        return userId == currentUserId
    }

    init(
        userId: String? = nil,
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        storageService: StorageServiceProtocol = StorageService(),
        authService: AuthServiceProtocol = AuthService(),
        imageService: ImageServiceProtocol = ImageService()
    ) {
        self.authService = authService
        self.imageService = imageService
        isExternalUserId = (userId != nil)

        // userIdが指定されていない場合は現在のユーザーIDを使用
        if let userId {
            self.userId = userId
        } else {
            self.userId = authService.currentUser()?.id
        }

        self.firestoreService = firestoreService
        self.storageService = storageService

        // デフォルトで全ツールを選択状態にする
        selectedTools = EditTool.allCases
        toolsOrder = EditTool.allCases.map(\.rawValue)

        // 投稿作成通知を購読（自分のプロフィールの場合のみ投稿一覧を自動更新）☁️
        setupPostCreatedObserver()
    }

    deinit {
        if let observer = postCreatedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 投稿作成通知を監視して投稿一覧を自動更新 ☁️
    private func setupPostCreatedObserver() {
        postCreatedObserver = NotificationCenter.default.addObserver(
            forName: .postCreated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.loadProfile()
                await self.loadUserPosts()
            }
        }
    }

    /// Auth状態が復元された後にuserIdを再取得してプロフィールをリロード
    /// Firebase Auth復元前にProfileViewが初期化された場合の対策
    /// - Returns: true = このメソッド内でロード済み（呼び出し元は再ロード不要）
    ///            false = ロード未実施（呼び出し元でロードが必要）
    func refreshUserIdIfNeeded() async -> Bool {
        // 外部指定のuserIdがある場合はスキップ（呼び出し元でロードが必要）
        guard !isExternalUserId else { return false }

        // userIdがnilの場合、Auth復元後に再取得を試みる
        if userId == nil {
            if let currentUserId = authService.currentUser()?.id {
                userId = currentUserId
                await loadProfile()
                await loadUserPosts()
                return true // このメソッド内でロード済み
            }
        }
        return false // ロード未実施（呼び出し元でロードが必要）
    }

    // MARK: - Load Profile

    /// プロフィール情報を読み込む
    func loadProfile() async {
        guard let userId else {
            // 未ログイン時はエラーを表示しない
            return
        }

        isLoading = true
        errorMessage = nil
        // すべてのパス（early return含む）で確実にローディング状態を解除する
        defer { isLoading = false }

        do {
            // 自分のプロフィールの場合は完全な情報を取得（email, blockedUserIds含む）
            // 他人のプロフィールの場合は公開情報のみ取得
            if isOwnProfile {
                // リトライ可能な操作として実行
                let fetchedUser = try await RetryableOperation.executeIfRetryable { [self] in
                    try await firestoreService.fetchUser(userId: userId)
                }
                user = fetchedUser

                // 編集用の値を設定
                editingDisplayName = fetchedUser.displayName ?? ""
                editingBio = fetchedUser.bio ?? ""

                // 編集装備を読み込む
                await loadEditTools()
            } else {
                // 他人のプロフィールは公開情報のみ取得
                // publicProfiles が存在しない場合（マイグレーション未実施ユーザー）は
                // users コレクションからフォールバック取得する
                do {
                    let publicProfile = try await RetryableOperation.executeIfRetryable { [self] in
                        try await firestoreService.fetchPublicProfile(userId: userId)
                    }

                    // PublicProfileからUserモデルに変換（機密情報はnil）
                    user = User(
                        id: publicProfile.id,
                        email: nil, // 公開情報には含まれない
                        displayName: publicProfile.displayName,
                        photoURL: publicProfile.photoURL,
                        bio: publicProfile.bio,
                        customEditTools: publicProfile.customEditTools,
                        customEditToolsOrder: publicProfile.customEditToolsOrder,
                        followersCount: publicProfile.followersCount,
                        followingCount: publicProfile.followingCount,
                        postsCount: publicProfile.postsCount,
                        blockedUserIds: nil, // 公開情報には含まれない
                        createdAt: publicProfile.createdAt,
                        updatedAt: publicProfile.updatedAt
                    )
                } catch FirestoreServiceError.notFound {
                    // publicProfiles ドキュメント未作成の場合: users コレクションからフォールバック
                    // （マイグレーション未実施の既存ユーザー対応）
                    let fallbackUser = try await RetryableOperation.executeIfRetryable { [self] in
                        try await firestoreService.fetchUser(userId: userId)
                    }
                    // 機密情報（email, blockedUserIds）をマスクして表示
                    user = User(
                        id: fallbackUser.id,
                        email: nil,
                        displayName: fallbackUser.displayName,
                        photoURL: fallbackUser.photoURL,
                        bio: fallbackUser.bio,
                        customEditTools: fallbackUser.customEditTools,
                        customEditToolsOrder: fallbackUser.customEditToolsOrder,
                        followersCount: fallbackUser.followersCount,
                        followingCount: fallbackUser.followingCount,
                        postsCount: fallbackUser.postsCount,
                        blockedUserIds: nil,
                        createdAt: fallbackUser.createdAt,
                        updatedAt: fallbackUser.updatedAt
                    )
                }
            }
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "ProfileViewModel.loadProfile", userId: userId)

            // notFoundエラーや権限エラーの場合はユーザーにエラーを表示しない
            // （新規ユーザーやドキュメント未作成の正常なケース）
            if let firestoreError = error as? FirestoreServiceError {
                switch firestoreError {
                case .notFound:
                    // ドキュメントが存在しない場合はAuth情報からデフォルトUserを生成して表示
                    if isOwnProfile, let currentAuthUser = authService.currentUser() {
                        user = User(
                            id: currentAuthUser.id,
                            email: currentAuthUser.email,
                            displayName: currentAuthUser.displayName ?? "ユーザー",
                            photoURL: nil,
                            bio: nil,
                            customEditTools: nil,
                            customEditToolsOrder: nil,
                            followersCount: 0,
                            followingCount: 0,
                            postsCount: 0,
                            blockedUserIds: nil,
                            createdAt: Date(),
                            updatedAt: Date()
                        )
                        editingDisplayName = user?.displayName ?? ""
                        editingBio = ""

                        // Firestoreにドキュメントを自動作成（バックグラウンド）
                        Task { [weak self] in
                            guard let self else { return }
                            if let newUser = user {
                                try? await firestoreService.updateUser(newUser)
                                try? await firestoreService.createPublicProfile(from: newUser)
                            }
                        }
                    } else if !isOwnProfile {
                        // 他ユーザーのプロフィールが見つからない場合は最小限の情報で表示
                        user = User(
                            id: userId,
                            email: nil,
                            displayName: "ユーザー",
                            photoURL: nil,
                            bio: nil,
                            customEditTools: nil,
                            customEditToolsOrder: nil,
                            followersCount: 0,
                            followingCount: 0,
                            postsCount: 0,
                            blockedUserIds: nil,
                            createdAt: Date(),
                            updatedAt: Date()
                        )
                    }
                    setDefaultEditTools()
                    return
                case let .fetchFailed(underlyingError):
                    // 権限エラーの場合もデフォルトUserを生成してエラーを表示しない
                    if let nsError = underlyingError as NSError?,
                       nsError.domain == "FIRFirestoreErrorDomain",
                       nsError.code == 7
                    { // PERMISSION_DENIED
                        if isOwnProfile, let currentAuthUser = authService.currentUser(), user == nil {
                            user = User(
                                id: currentAuthUser.id,
                                email: currentAuthUser.email,
                                displayName: currentAuthUser.displayName ?? "ユーザー",
                                photoURL: nil,
                                bio: nil,
                                customEditTools: nil,
                                customEditToolsOrder: nil,
                                followersCount: 0,
                                followingCount: 0,
                                postsCount: 0,
                                blockedUserIds: nil,
                                createdAt: Date(),
                                updatedAt: Date()
                            )
                            editingDisplayName = user?.displayName ?? ""
                            editingBio = ""
                        }
                        setDefaultEditTools()
                        return
                    }
                default:
                    break
                }
            }

            // その他のエラーの場合のみユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
    }

    /// 編集装備を読み込む（内部用）
    /// 全27ツールの順序のみを管理
    private func loadEditTools() async {
        guard userId != nil,
              let user
        else {
            return
        }

        // customEditToolsOrderから順序を復元
        if let toolsOrderFromUser = user.customEditToolsOrder,
           !toolsOrderFromUser.isEmpty
        {
            // 順序に従ってEditToolを取得
            var orderedTools: [EditTool] = []
            for toolId in toolsOrderFromUser {
                if let tool = EditTool(rawValue: toolId) {
                    orderedTools.append(tool)
                }
            }

            // 順序に含まれていないツールも追加（後ろに追加）
            for tool in EditTool.allCases {
                if !orderedTools.contains(tool) {
                    orderedTools.append(tool)
                }
            }

            equippedTools = orderedTools
            selectedTools = orderedTools
            toolsOrder = orderedTools.map(\.rawValue)
        } else {
            // デフォルトは全ツールをそのままの順序で
            setDefaultEditTools()
        }
    }

    /// 編集装備設定のみを読み込む（EditToolsSettingsView用）
    /// エラーが発生してもアラートを表示せず、デフォルトのツールを使用する
    func loadEditToolsSettings() async {
        guard let userId else {
            // 未ログイン時はデフォルトのツールを使用
            setDefaultEditTools()
            return
        }

        isLoading = true
        // すべてのパスで確実にローディング状態を解除する
        defer { isLoading = false }

        do {
            // ユーザードキュメントの取得を試みる
            let fetchedUser = try await RetryableOperation.executeIfRetryable { [self] in
                try await firestoreService.fetchUser(userId: userId)
            }
            user = fetchedUser

            // 編集装備を読み込む
            await loadEditTools()
        } catch {
            // エラーが発生した場合はデフォルトのツールを使用
            // エラーメッセージは表示しない（EditToolsSettingsViewでは不要）
            ErrorHandler.logError(error, context: "ProfileViewModel.loadEditToolsSettings", userId: userId)
            setDefaultEditTools()
        }
    }

    /// デフォルトの編集装備を設定（全27ツール）
    private func setDefaultEditTools() {
        let allTools = EditTool.allCases
        equippedTools = allTools
        selectedTools = allTools
        toolsOrder = allTools.map(\.rawValue)
    }

    // MARK: - Load Posts

    /// ユーザーの投稿一覧を読み込む ☁️
    func loadUserPosts() async {
        guard let userId else {
            logger.warning("loadUserPosts: userId is nil, skipping")
            return
        }

        let currentAuthId = authService.currentUser()?.id
        // ⚠️ Logger の文字列にプロパティを直に書くと `self.` が要るが、整形フック（swiftformat）がその `self.` を
        //    消してビルドが壊れる。先にローカルへ取ってから渡す（publicCount・hasMore も同じ理由）
        let isOwn = isOwnProfile
        logger.debug("loadUserPosts: userId=\(userId, privacy: .private), authId=\(currentAuthId ?? "nil", privacy: .private), isOwnProfile=\(isOwn)")

        isLoadingPosts = true
        // エラーメッセージはリセットしない（loadProfileで設定されている可能性があるため）
        // すべてのパス（early return含む）で確実にローディング状態を解除する
        defer { isLoadingPosts = false }

        // 新しい取得世代を開始（読み込み途中の追加ページがあれば、それは捨てられる）
        postsGeneration += 1
        let generation = postsGeneration

        do {
            // リトライ可能な操作として実行
            let page = try await RetryableOperation.executeIfRetryable { [self] in
                try await firestoreService.fetchUserPostsPage(
                    userId: userId,
                    limit: Self.postsPageSize,
                    lastDocument: nil
                )
            }
            guard generation == postsGeneration else { return }
            let posts = page.posts
            postsCursor = page.lastDocument
            // 1 ページ分きっちり読めたなら、続きがある可能性がある。
            // 件数（posts.count）でなく isExhausted で判定する: 壊れた投稿を飛ばしたページは
            // 件数が 1 ページ分を割るため、件数で見ると続きがあるのに打ち切ってしまう
            hasMorePosts = !page.isExhausted

            logger.info("loadUserPosts: fetched \(posts.count) posts")

            // 他ユーザーのプロフィールの場合は公開投稿のみフィルタリング
            if !isOwnProfile {
                userPosts = posts.filter { $0.visibility == .public }
                let publicCount = userPosts.count
                logger.debug("loadUserPosts: filtered to \(publicCount) public posts (not own profile)")
            } else {
                userPosts = posts
            }

            // 投稿数の補正は自分のプロフィールだけ行う。
            // ⚠️ 旧実装は「取得した件数（最大 50）」を正しい投稿数として保存していたため、
            //    投稿が 50 件を超えると postsCount が 50 に書き戻されていた。
            //    取得件数は画面に並べる 1 ページ分でしかないので、件数の根拠に使わない。
            //    代わりに count() 集計で全件を数え直す（取得上限に左右されない）。
            if isOwnProfile {
                // 一覧は表示済みなので、数え直し（集計 2 本＋書き込み 2 本）を待つ間は
                // 「読み込み中」を解除しておく。解除しないと、その間に末尾まで
                // スクロールしたときの続き読み込みが !isLoadingPosts ガードで捨てられ、
                // スクロールし直すまで次のページが出ない（defer の再代入は無害）。
                isLoadingPosts = false
                await refreshOwnPostsCount(userId: userId)
            }
        } catch {
            // エラーをログに記録（デバッグ用に詳細を出力）
            logger.error("loadUserPosts error: \(error.localizedDescription)")
            ErrorHandler.logError(error, context: "ProfileViewModel.loadUserPosts", userId: userId)

            if let firestoreError = error as? FirestoreServiceError {
                switch firestoreError {
                case .notFound:
                    // 投稿がない場合は正常
                    logger.debug("loadUserPosts: notFound (no posts yet)")
                    return
                case let .fetchFailed(underlyingError):
                    if let nsError = underlyingError as NSError?,
                       nsError.domain == "FIRFirestoreErrorDomain"
                    {
                        logger.error("loadUserPosts: Firestore error code=\(nsError.code), desc=\(nsError.localizedDescription)")
                        // 権限エラー（code 7）やインデックス未作成（code 9）はサイレントに処理
                        // 新規ユーザーや権限設定中の場合にエラーダイアログを表示しない
                        if nsError.code == 7 || nsError.code == 9 {
                            logger.warning("loadUserPosts: permission/index error (code \(nsError.code)), silently handled")
                            return
                        }
                    }
                default:
                    break
                }
            }

            // その他のエラーの場合のみユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
    }

    // MARK: - Update Profile

    /// プロフィール情報を更新
    func updateProfile() async {
        guard let userId,
              var updatedUser = user
        else {
            errorMessage = "ユーザー情報が取得できません"
            return
        }

        isLoading = true
        errorMessage = nil
        // すべてのパスで確実にローディング状態を解除する
        defer { isLoading = false }

        do {
            // プロフィール画像の処理
            var photoURL = updatedUser.photoURL

            if shouldDeleteProfileImage {
                // 既存の画像を削除（リトライ可能）
                if photoURL != nil {
                    // Storageから画像を削除（storage.rules のパス形式: users/{userId}/profile/{imageId}）
                    let path = "users/\(userId)/profile/profile.jpg"
                    try? await RetryableOperation.executeIfRetryable { [self] in
                        try await storageService.deleteImage(path: path)
                    }
                }
                photoURL = nil
            } else if let profileImage = editingProfileImage {
                // アイコンは小さく表示するだけなので、送る前に長辺 1024px まで縮小する。
                // ⚠️ 以前は選んだ写真を元の解像度のまま送っていたため、StorageService が JPEG にすると
                //    5MB を超えて「画像サイズが大きすぎます」で保存できないことがあった
                //    （1.11.0 で 5 人。Crashlytics の初出は 1.5.4）。
                //    投稿側（PostViewModel）が送る前に 2048px へ縮小しているのと同じ考え方。
                let maxSide = Self.profileImageMaxDimension
                let resizedImage = try await imageService.resizeImage(
                    profileImage,
                    maxSize: CGSize(width: maxSide, height: maxSide)
                )
                // 新しい画像をアップロード（リトライ可能）
                // storage.rules のパス形式: users/{userId}/profile/{imageId}
                let imagePath = "users/\(userId)/profile/profile.jpg"
                let uploadedURL = try await RetryableOperation.executeIfRetryable { [self] in
                    try await storageService.uploadImage(resizedImage, path: imagePath)
                }
                photoURL = uploadedURL.absoluteString
            }

            // ユーザー情報を更新
            // 表示名が空、またはスペースだけ（全角を含む）なら「消した」とみなす。
            // 画面では空欄に見えるのに「ユーザー」にならないのを防ぐため（Android もスペースだけは空として扱う）。
            // trim は判定にだけ使い、中身のある名前は前後の空白も変えずにそのまま書く。
            let isDisplayNameCleared = editingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            updatedUser.displayName = isDisplayNameCleared ? nil : editingDisplayName
            // 自己紹介は空でも nil にせず空文字のまま書く。
            // ⚠️ nil にすると toFirestoreData が bio のキーを書かず、users の setData(merge: true) と
            //    publicProfiles の updatePublicProfileFields（nil は書かない）で古い自己紹介文が残り、
            //    読み込み直すと戻ってしまう（2026-10-31 アプリ内のご意見で報告・本番で再現）。
            updatedUser.bio = editingBio
            updatedUser.photoURL = photoURL
            updatedUser.updatedAt = Date()

            // 消す項目（nil だけでは「書かない＝前の値のまま」になるので明示する）
            // ⚠️ 表示名・アイコンは "" でなくキーごと消す。読む側は全画面で「キーが無い」を新規ユーザーと同じく
            //    「ユーザー」と人型の印で出すが、"" だと名前が空欄になり、写真が無いのに「画像を削除」が出る。
            var clearedFields: Set<ProfileClearableField> = []
            if isDisplayNameCleared {
                clearedFields.insert(.displayName)
            }
            if shouldDeleteProfileImage {
                clearedFields.insert(.photoURL)
            }

            // Firestoreに更新（リトライ可能）
            let savedUser = try await RetryableOperation.executeIfRetryable { [self] in
                try await firestoreService.updateUser(updatedUser, clearing: clearedFields)
            }
            user = savedUser

            // 公開プロフィールも更新（他のユーザーから閲覧可能な情報）
            // ⚠️ PublicProfile 全体を書くと followersCount / followingCount まで
            //    クライアントの古い値で上書きしてしまい、Cloud Functions が保っている
            //    真値をプロフィール編集のたびに潰す。そのため編集対象フィールド
            //    （表示名・アイコン・自己紹介）だけを updateData するメソッドを使う。
            do {
                try await RetryableOperation.executeIfRetryable { [self] in
                    try await firestoreService.updatePublicProfileFields(
                        userId: savedUser.id,
                        displayName: savedUser.displayName,
                        photoURL: savedUser.photoURL,
                        bio: savedUser.bio,
                        clearing: clearedFields
                    )
                }
            } catch FirestoreServiceError.notFound {
                // publicProfiles ドキュメントが未作成のユーザー（マイグレーション未実施）は
                // updateData が NOT_FOUND になるため、新規作成にフォールバックする。
                // ドキュメントが存在しない ＝ サーバーが保つカウンタも存在しないので、
                // ここで User 由来の値ごと作成しても真値を潰すことはない。
                try await RetryableOperation.executeIfRetryable { [self] in
                    try await firestoreService.createPublicProfile(from: savedUser)
                }
            }

            // 公開プロフィールまで書けたら、他の画面（そらとも）へ新しい表示名とアイコンを知らせる ⭐️
            // そらともの覚え（SoratomoProfileStore）は一度取った人を読み直さないため、知らせないと
            // 再起動するまで古い表示名のままだった。書けなかったときは送らない（`.userBlocked` と同じ考え方）
            var profileUserInfo: [String: Any] = [Notification.profileUpdatedUserIdKey: savedUser.id]
            if let displayName = savedUser.displayName {
                profileUserInfo[Notification.profileUpdatedDisplayNameKey] = displayName
            }
            if let photoURL = savedUser.photoURL {
                profileUserInfo[Notification.profileUpdatedPhotoURLKey] = photoURL
            }
            NotificationCenter.default.post(name: .profileUpdated, object: nil, userInfo: profileUserInfo)

            // 編集用の値をリセット
            editingProfileImage = nil
            shouldDeleteProfileImage = false

            // プロフィールに表示するもの（見せる/見せない）を、変わった欄だけ書く ⭐️
            // ⚠️ この位置（いちばん最後）に置く理由:
            //    1. 公開プロフィールの書き込み（上の updatePublicProfileFields と、その notFound のときの
            //       createPublicProfile）より後にする。createPublicProfile は setData の丸ごと上書きで、
            //       先に見せる/見せないを書くとここで消える。
            //    2. `.profileUpdated` の通知より後にする。表示名とアイコンはもう保存できているので、
            //       見せる/見せないの書き込みが失敗しても、そらともへの通知を止める理由が無い。
            //    3. 画像の指定のリセットより後にする。ここで失敗すると errorMessage が出て編集画面は閉じない
            //       （ProfileEditView.saveProfile）。もう一度「保存」を押したとき、画像を送り直さずに済む。
            //    失敗は下の catch で既存の errorMessage に出る（比べる元は変えないので、もう一度押せば書き直す）。
            try await saveSectionVisibilityIfChanged(savedUser: savedUser)
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "ProfileViewModel.updateProfile", userId: userId)
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
    }

    /// 投稿グリッドの続き（次の 1 ページ）を読み込む ⭐️
    ///
    /// グリッド／リストの最後の投稿が画面に出たときに View から呼ぶ。
    /// - Returns: 今回追加した投稿（いいね・お気に入り状態の確認に使う）。追加が無ければ空配列。
    @discardableResult
    func loadMoreUserPosts() async -> [Post] {
        guard hasMorePosts, !isLoadingMorePosts, !isLoadingPosts,
              let userId else { return [] }
        // カーソルは guard で要求しない（FollowListViewModel.loadMore と同じ流儀）。
        // 本番では hasMorePosts == true ⇔ 直前ページを 50 件読めた ⇔ カーソルあり なので挙動は同じで、
        // テストでは作れない DocumentSnapshot が無くても続き読み込みを検証できる。
        let cursor = postsCursor

        // このページが属する取得世代。await 中に loadUserPosts（引っ張って更新など）が
        // 走ったら、古いカーソルで取ったページを新しい一覧へ混ぜないよう捨てる。
        let generation = postsGeneration
        isLoadingMorePosts = true
        // 世代不一致で早期 return しても追加読み込みが恒久ブロックされないよう、必ず解除する。
        defer { isLoadingMorePosts = false }

        do {
            let page = try await RetryableOperation.executeIfRetryable { [self] in
                try await firestoreService.fetchUserPostsPage(
                    userId: userId,
                    limit: Self.postsPageSize,
                    lastDocument: cursor
                )
            }
            guard generation == postsGeneration else { return [] }

            postsCursor = page.lastDocument
            // 続きの有無は件数でなく isExhausted で判定する（loadUserPosts と同じ理由）
            hasMorePosts = !page.isExhausted

            // 他人のプロフィールは初回と同じく公開投稿だけに絞る
            let visible = isOwnProfile ? page.posts : page.posts.filter { $0.visibility == .public }
            // 念のため重複を除く（ページ境界の前後で同じ投稿が 2 回並ばないように）
            let existingIds = Set(userPosts.map(\.id))
            let newPosts = visible.filter { !existingIds.contains($0.id) }
            userPosts.append(contentsOf: newPosts)
            let hasMore = hasMorePosts
            logger.info("loadMoreUserPosts: appended \(newPosts.count) posts (hasMore=\(hasMore))")
            return newPosts
        } catch {
            // 追加読み込みの失敗はダイアログを出さない（一覧は既に見えているため）。
            // hasMorePosts は維持するので、もう一度スクロールすれば再試行される。
            logger.error("loadMoreUserPosts error: \(error.localizedDescription)")
            ErrorHandler.logError(error, context: "ProfileViewModel.loadMoreUserPosts", userId: userId)
            return []
        }
    }

    /// 自分の投稿数を count() 集計で数え直し、表示と Firestore の両方を正しい値にする ⭐️
    ///
    /// 数え直しに失敗しても投稿一覧の表示は妨げない（ログだけ残し、表示中の値を維持する）。
    private func refreshOwnPostsCount(userId: String) async {
        do {
            let total = try await firestoreService.recountPostsCount(userId: userId)
            // User は struct（値型）のため user?.postsCount = x は @Published に反映されない。
            // いったん取り出して代入し直すことで ObservableObject の変更通知を確実に発行する。
            if var updatedUser = user, updatedUser.postsCount != total {
                logger.debug("refreshOwnPostsCount: \(updatedUser.postsCount) → \(total)")
                updatedUser.postsCount = total
                user = updatedUser
            }
        } catch {
            logger.error("refreshOwnPostsCount error: \(error.localizedDescription)")
            ErrorHandler.logError(error, context: "ProfileViewModel.refreshOwnPostsCount", userId: userId)
        }
    }

    // MARK: - Delete Post

    /// 投稿を削除する（自分の投稿のみ）
    /// - Parameter post: 削除する投稿
    func deletePost(_ post: Post) async {
        guard let userId = authService.currentUser()?.id else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Firestoreから投稿を削除（postsCount はサービス側で数え直される）
            try await RetryableOperation.executeIfRetryable {
                try await self.firestoreService.deletePost(postId: post.id, userId: userId)
            }

            // Firebase Storageから画像を並列削除（ベストエフォート）
            await storageService.deletePostImages(post)

            // ローカルの投稿配列からも削除
            userPosts.removeAll { $0.id == post.id }

            // postsCountをローカルでも更新
            if var updatedUser = user {
                updatedUser.postsCount = max(0, updatedUser.postsCount - 1)
                user = updatedUser
            }
        } catch {
            ErrorHandler.logError(error, context: "ProfileViewModel.deletePost", userId: userId)
            errorMessage = error.userFriendlyMessage
        }
    }

    // MARK: - Edit Tools Management

    /// 編集装備の順序を更新（Firestoreに保存）
    func updateEditTools() async {
        guard let userId else {
            errorMessage = "ユーザーIDが取得できません"
            return
        }

        isLoading = true
        errorMessage = nil
        // すべてのパスで確実にローディング状態を解除する
        defer { isLoading = false }

        do {
            // 選択されたツールの順序を取得
            let toolsOrder = selectedTools.map(\.rawValue)

            // リトライ可能な操作として実行
            try await RetryableOperation.executeIfRetryable { [self] in
                try await firestoreService.updateEditTools(
                    userId: userId,
                    tools: selectedTools,
                    order: toolsOrder
                )
            }

            // ローカルの状態を更新
            equippedTools = selectedTools
            self.toolsOrder = toolsOrder

            // ユーザー情報を再読み込み
            await loadProfile()
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "ProfileViewModel.updateEditTools", userId: userId)
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
    }

    /// 編集装備の順序を変更（ドラッグ&ドロップ）
    func moveEditTool(from source: IndexSet, to destination: Int) {
        selectedTools.move(fromOffsets: source, toOffset: destination)
    }

    /// 編集装備の選択をリセット（現在保存されている順序に戻す）
    func resetEditTools() {
        selectedTools = equippedTools
    }

    /// プロフィール編集の入力を保存済みの値に戻す（キャンセル・シートを閉じたとき用）
    ///
    /// 入力欄（表示名・自己紹介・画像）の値はシートではなくこの ViewModel が持っているため、
    /// 保存せずに閉じても戻さないと、次に開いたとき入力途中の値が残ってしまう。
    /// 編集装備の `resetEditTools()` と同じく、保存済みの状態（`user`）を正として戻す。
    func resetProfileEdit() {
        editingDisplayName = user?.displayName ?? ""
        editingBio = user?.bio ?? ""
        editingProfileImage = nil
        shouldDeleteProfileImage = false
        // 見せる/見せない のスイッチも、読み込んだ値（保存できたらその値）に戻す ⭐️
        // （読めていないときは比べる元が無いので触らない。次に開いたとき読み直す）
        if let loaded = sectionVisibilityLoadState.data {
            editingSectionVisibility = loaded
        }
    }

    // MARK: - プロフィールに表示するもの（見せる/見せない）⭐️

    /// スイッチを押せるか（自分の公開プロフィールから値を読めたとき＝文書が無くて既定値にしたときも含む）
    var canEditSectionVisibility: Bool {
        sectionVisibilityLoadState.isLoaded
    }

    /// 読み込みに失敗したか（編集画面の節を押せなくして「読み込めませんでした」を出す）
    var sectionVisibilityLoadFailed: Bool {
        sectionVisibilityLoadState.isError
    }

    /// 編集画面を開いたときに、今の見せる/見せない を自分の `publicProfiles` から読む ⭐️
    ///
    /// - 読めた → その値（項目が無い欄は既定値・`PublicProfile.init(from:)`）でスイッチを押せる状態にする
    /// - `FirestoreServiceError.notFound`（公開プロフィールの文書がまだ無い旧アカウント）→ 既定値で押せる状態にする。
    ///   ⚠️ ここを押せなくすると、その人は永久に ON にできない。保存のときに `updateProfile` の公開プロフィールの
    ///   書き込み（無ければ作る）の後に書くので、文書はそこでできる。
    /// - それ以外の失敗 → 押せない状態にする（読めていない値で上書きしないため）。
    ///   `errorMessage` には入れない（入れると編集画面の alert が出る。節の中の「読み込めませんでした」で知らせる）。
    ///   `isLoading` も立てない（立てると「保存」ボタンまで押せなくなる。表示名などの保存は妨げない）。
    /// - 再試行（RetryableOperation）で包むのは loadProfile の公開プロフィールの読み込みと同じ。
    ///   一時的な通信の失敗で節が押せないままになるのを減らすため（notFound は再試行しない分類なので 1 回で抜ける）。
    func loadSectionVisibilityForEdit() async {
        sectionVisibilityLoadGeneration += 1
        let generation = sectionVisibilityLoadGeneration

        guard let userId else {
            // 未ログイン（Auth の復元前など）は読めない＝押せない状態にする
            sectionVisibilityLoadState = .error(FirestoreServiceError.unauthorized)
            return
        }

        sectionVisibilityLoadState = .loading

        do {
            let profile = try await RetryableOperation.executeIfRetryable { [self] in
                try await firestoreService.fetchPublicProfile(userId: userId)
            }
            guard generation == sectionVisibilityLoadGeneration else { return }
            editingSectionVisibility = profile.sectionVisibility
            sectionVisibilityLoadState = .loaded(profile.sectionVisibility)
        } catch FirestoreServiceError.notFound {
            guard generation == sectionVisibilityLoadGeneration else { return }
            // 文書がまだ無い人は、項目が無い人と同じ既定値（おすすめ＝見せる・カレンダーとお気に入り＝見せない）
            editingSectionVisibility = .default
            sectionVisibilityLoadState = .loaded(.default)
        } catch {
            guard generation == sectionVisibilityLoadGeneration else { return }
            ErrorHandler.logError(error, context: "ProfileViewModel.loadSectionVisibilityForEdit", userId: userId)
            sectionVisibilityLoadState = .error(error)
        }
    }

    /// 見せる/見せない を、読み込んだ値から変わった欄だけ書く（`updateProfile` の最後から呼ぶ）⭐️
    ///
    /// - 読めていない（比べる元が無い）なら書かない＝読めていない値で上書きしない
    /// - 変わった欄が無ければ呼ばない
    /// - 公開プロフィールの文書が無い（notFound）なら、無いときだけ作って（`createPublicProfileIfMissing`）から書き直す。
    ///   丸ごと上書きの `createPublicProfile` を使わないのは、別の端末が同時に作った値を消さないため
    ///   （`RecommendationManager.addWithProfileFallback` と同じ形。ここは保存した `savedUser` が手元にあるので読み直さない）。
    /// - 書けたら、比べる元を今の値にし、欄ごとに `profile_visibility_changed` を送る（UID は送らない）
    /// - Throws: 書き込みの失敗（呼び出し側の `updateProfile` が errorMessage に出す）
    private func saveSectionVisibilityIfChanged(savedUser: User) async throws {
        guard let loaded = sectionVisibilityLoadState.data else { return }

        let edited = editingSectionVisibility
        let changedSections = edited.changedSections(from: loaded)
        guard !changedSections.isEmpty else { return }

        // 再試行の閉包に渡すので let で作る（可変の値を閉包に捕まえさせない）
        let sections = Dictionary(uniqueKeysWithValues: changedSections.map { section in
            (section, edited.isShown(section))
        })

        do {
            try await RetryableOperation.executeIfRetryable { [self] in
                try await firestoreService.updateProfileSectionVisibility(userId: savedUser.id, sections: sections)
            }
        } catch FirestoreServiceError.notFound {
            try await RetryableOperation.executeIfRetryable { [self] in
                try await firestoreService.createPublicProfileIfMissing(from: savedUser)
            }
            try await RetryableOperation.executeIfRetryable { [self] in
                try await firestoreService.updateProfileSectionVisibility(userId: savedUser.id, sections: sections)
            }
        }

        // 書けた値を、次に比べる元にする（同じ画面でもう一度「保存」しても同じ欄を書き直さない）
        sectionVisibilityLoadState = .loaded(edited)

        for section in changedSections {
            LoggingService.shared.logEvent("profile_visibility_changed", parameters: [
                "section": section.rawValue,
                "enabled": edited.isShown(section),
            ])
        }
    }

    // MARK: - Validation

    /// 編集装備の選択が有効かどうか（常にtrue - 全ツール表示のため）
    var isValidEditToolsSelection: Bool {
        true
    }

    /// プロフィール編集が有効かどうか
    var isValidProfileEdit: Bool {
        // 表示名と自己紹介の長さチェック（任意）
        let displayNameValid = editingDisplayName.count <= 50
        let bioValid = editingBio.count <= 200

        return displayNameValid && bioValid
    }
}

// MARK: - 投稿作成通知 ☁️

extension Notification.Name {
    /// 新しい投稿が作成された時に送信される通知
    static let postCreated = Notification.Name("com.soramoyou.postCreated")

    /// 自分のプロフィール（表示名・アイコン）を保存した時に送信される通知 ☁️
    ///
    /// userInfo の `Notification.profileUpdatedUserIdKey` に保存したユーザーの ID（String）、
    /// `Notification.profileUpdatedDisplayNameKey` / `Notification.profileUpdatedPhotoURLKey` に
    /// 保存した表示名・アイコンの URL（String）が入る。未設定（nil）のときはキーごと入れない。
    /// そらともの表示名・アイコンの覚え（`SoratomoProfileStore`）が受け取り、持っている値を差し替える
    /// （プロフィール編集で名前を変えても、そらとものタイムラインは再起動するまで古い名前のままだった不具合の対策）。
    static let profileUpdated = Notification.Name("com.soramoyou.profileUpdated")
}

extension Notification {
    /// `.profileUpdated` の userInfo で、保存したユーザーの ID を入れるキー
    static let profileUpdatedUserIdKey = "profileUpdatedUserId"
    /// `.profileUpdated` の userInfo で、保存した表示名を入れるキー（未設定ならキーごと無い）
    static let profileUpdatedDisplayNameKey = "profileUpdatedDisplayName"
    /// `.profileUpdated` の userInfo で、保存したアイコンの URL を入れるキー（未設定ならキーごと無い）
    static let profileUpdatedPhotoURLKey = "profileUpdatedPhotoURL"
}
