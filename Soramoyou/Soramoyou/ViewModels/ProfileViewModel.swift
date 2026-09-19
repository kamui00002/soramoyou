//
//  ProfileViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import Combine
import FirebaseFirestore
import UIKit
import os

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

    // 編集装備システムの管理（全27ツールの並び替え）
    @Published var availableTools: [EditTool] = EditTool.allCases
    @Published var selectedTools: [EditTool] = EditTool.allCases  // 全ツールを常に選択状態
    @Published var toolsOrder: [String] = []

    /// Auth復元後にuserIdを再取得できるようvarに変更
    private var userId: String?
    /// 外部から指定されたuserIdかどうか（自分のプロフィール判定用）
    private let isExternalUserId: Bool
    private let firestoreService: FirestoreServiceProtocol
    private let storageService: StorageServiceProtocol
    /// 認証サービス（Firebase直参照を排除し、テスタビリティを向上）
    private let authService: AuthServiceProtocol
    private var cancellables = Set<AnyCancellable>()

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
        guard let userId = userId,
              let currentUserId = authService.currentUser()?.id else {
            return false
        }
        return userId == currentUserId
    }

    init(
        userId: String? = nil,
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        storageService: StorageServiceProtocol = StorageService(),
        authService: AuthServiceProtocol = AuthService()
    ) {
        self.authService = authService
        self.isExternalUserId = (userId != nil)

        // userIdが指定されていない場合は現在のユーザーIDを使用
        if let userId = userId {
            self.userId = userId
        } else {
            self.userId = authService.currentUser()?.id
        }

        self.firestoreService = firestoreService
        self.storageService = storageService

        // デフォルトで全ツールを選択状態にする
        self.selectedTools = EditTool.allCases
        self.toolsOrder = EditTool.allCases.map { $0.rawValue }

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
            guard let self = self else { return }
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
                return true  // このメソッド内でロード済み
            }
        }
        return false  // ロード未実施（呼び出し元でロードが必要）
    }
    
    // MARK: - Load Profile
    
    /// プロフィール情報を読み込む
    func loadProfile() async {
        guard let userId = userId else {
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
                    try await self.firestoreService.fetchUser(userId: userId)
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
                        try await self.firestoreService.fetchPublicProfile(userId: userId)
                    }

                    // PublicProfileからUserモデルに変換（機密情報はnil）
                    user = User(
                        id: publicProfile.id,
                        email: nil,  // 公開情報には含まれない
                        displayName: publicProfile.displayName,
                        photoURL: publicProfile.photoURL,
                        bio: publicProfile.bio,
                        customEditTools: publicProfile.customEditTools,
                        customEditToolsOrder: publicProfile.customEditToolsOrder,
                        followersCount: publicProfile.followersCount,
                        followingCount: publicProfile.followingCount,
                        postsCount: publicProfile.postsCount,
                        blockedUserIds: nil,  // 公開情報には含まれない
                        createdAt: publicProfile.createdAt,
                        updatedAt: publicProfile.updatedAt
                    )
                } catch FirestoreServiceError.notFound {
                    // publicProfiles ドキュメント未作成の場合: users コレクションからフォールバック
                    // （マイグレーション未実施の既存ユーザー対応）
                    let fallbackUser = try await RetryableOperation.executeIfRetryable { [self] in
                        try await self.firestoreService.fetchUser(userId: userId)
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
                            guard let self = self else { return }
                            if let newUser = self.user {
                                try? await self.firestoreService.updateUser(newUser)
                                try? await self.firestoreService.createPublicProfile(from: newUser)
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
                case .fetchFailed(let underlyingError):
                    // 権限エラーの場合もデフォルトUserを生成してエラーを表示しない
                    if let nsError = underlyingError as NSError?,
                       nsError.domain == "FIRFirestoreErrorDomain",
                       nsError.code == 7 { // PERMISSION_DENIED
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
              let user = user else {
            return
        }

        // customEditToolsOrderから順序を復元
        if let toolsOrderFromUser = user.customEditToolsOrder,
           !toolsOrderFromUser.isEmpty {
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
            self.toolsOrder = orderedTools.map { $0.rawValue }
        } else {
            // デフォルトは全ツールをそのままの順序で
            setDefaultEditTools()
        }
    }

    /// 編集装備設定のみを読み込む（EditToolsSettingsView用）
    /// エラーが発生してもアラートを表示せず、デフォルトのツールを使用する
    func loadEditToolsSettings() async {
        guard let userId = userId else {
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
                try await self.firestoreService.fetchUser(userId: userId)
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
        toolsOrder = allTools.map { $0.rawValue }
    }
    
    // MARK: - Load Posts
    
    /// ユーザーの投稿一覧を読み込む ☁️
    func loadUserPosts() async {
        guard let userId = userId else {
            logger.warning("loadUserPosts: userId is nil, skipping")
            return
        }

        let currentAuthId = authService.currentUser()?.id
        logger.debug("loadUserPosts: userId=\(userId, privacy: .private), authId=\(currentAuthId ?? "nil", privacy: .private), isOwnProfile=\(self.isOwnProfile)")

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
                try await self.firestoreService.fetchUserPostsPage(
                    userId: userId,
                    limit: Self.postsPageSize,
                    lastDocument: nil
                )
            }
            guard generation == postsGeneration else { return }
            let posts = page.posts
            postsCursor = page.lastDocument
            // 1 ページ分きっちり取れたなら、続きがある可能性がある
            hasMorePosts = posts.count >= Self.postsPageSize

            logger.info("loadUserPosts: fetched \(posts.count) posts")

            // 他ユーザーのプロフィールの場合は公開投稿のみフィルタリング
            if !isOwnProfile {
                userPosts = posts.filter { $0.visibility == .public }
                logger.debug("loadUserPosts: filtered to \(self.userPosts.count) public posts (not own profile)")
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
                case .fetchFailed(let underlyingError):
                    if let nsError = underlyingError as NSError?,
                       nsError.domain == "FIRFirestoreErrorDomain" {
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
        guard let userId = userId,
              var updatedUser = user else {
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
                        try await self.storageService.deleteImage(path: path)
                    }
                }
                photoURL = nil
            } else if let profileImage = editingProfileImage {
                // 新しい画像をアップロード（リトライ可能）
                // storage.rules のパス形式: users/{userId}/profile/{imageId}
                let imagePath = "users/\(userId)/profile/profile.jpg"
                let uploadedURL = try await RetryableOperation.executeIfRetryable { [self] in
                    try await self.storageService.uploadImage(profileImage, path: imagePath)
                }
                photoURL = uploadedURL.absoluteString
            }
            
            // ユーザー情報を更新
            updatedUser.displayName = editingDisplayName.isEmpty ? nil : editingDisplayName
            updatedUser.bio = editingBio.isEmpty ? nil : editingBio
            updatedUser.photoURL = photoURL
            updatedUser.updatedAt = Date()
            
            // Firestoreに更新（リトライ可能）
            let savedUser = try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.updateUser(updatedUser)
            }
            user = savedUser

            // 公開プロフィールも更新（他のユーザーから閲覧可能な情報）
            // ⚠️ PublicProfile 全体を書くと followersCount / followingCount まで
            //    クライアントの古い値で上書きしてしまい、Cloud Functions が保っている
            //    真値をプロフィール編集のたびに潰す。そのため編集対象フィールド
            //    （表示名・アイコン・自己紹介）だけを updateData するメソッドを使う。
            do {
                try await RetryableOperation.executeIfRetryable { [self] in
                    try await self.firestoreService.updatePublicProfileFields(
                        userId: savedUser.id,
                        displayName: savedUser.displayName,
                        photoURL: savedUser.photoURL,
                        bio: savedUser.bio
                    )
                }
            } catch FirestoreServiceError.notFound {
                // publicProfiles ドキュメントが未作成のユーザー（マイグレーション未実施）は
                // updateData が NOT_FOUND になるため、新規作成にフォールバックする。
                // ドキュメントが存在しない ＝ サーバーが保つカウンタも存在しないので、
                // ここで User 由来の値ごと作成しても真値を潰すことはない。
                try await RetryableOperation.executeIfRetryable { [self] in
                    try await self.firestoreService.createPublicProfile(from: savedUser)
                }
            }

            // 編集用の値をリセット
            editingProfileImage = nil
            shouldDeleteProfileImage = false
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
                try await self.firestoreService.fetchUserPostsPage(
                    userId: userId,
                    limit: Self.postsPageSize,
                    lastDocument: cursor
                )
            }
            guard generation == postsGeneration else { return [] }

            postsCursor = page.lastDocument
            hasMorePosts = page.posts.count >= Self.postsPageSize

            // 他人のプロフィールは初回と同じく公開投稿だけに絞る
            let visible = isOwnProfile ? page.posts : page.posts.filter { $0.visibility == .public }
            // 念のため重複を除く（ページ境界の前後で同じ投稿が 2 回並ばないように）
            let existingIds = Set(userPosts.map(\.id))
            let newPosts = visible.filter { !existingIds.contains($0.id) }
            userPosts.append(contentsOf: newPosts)
            logger.info("loadMoreUserPosts: appended \(newPosts.count) posts (hasMore=\(self.hasMorePosts))")
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
        guard let userId = userId else {
            errorMessage = "ユーザーIDが取得できません"
            return
        }

        isLoading = true
        errorMessage = nil
        // すべてのパスで確実にローディング状態を解除する
        defer { isLoading = false }

        do {
            // 選択されたツールの順序を取得
            let toolsOrder = selectedTools.map { $0.rawValue }
            
            // リトライ可能な操作として実行
            try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.updateEditTools(
                    userId: userId,
                    tools: self.selectedTools,
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
}
