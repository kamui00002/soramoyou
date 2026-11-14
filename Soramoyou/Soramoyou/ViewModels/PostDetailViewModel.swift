//
//  PostDetailViewModel.swift
//  Soramoyou
//
//  投稿詳細画面のViewModel
//

import Foundation

/// 投稿詳細画面のViewModel
@MainActor
class PostDetailViewModel: ObservableObject {
    /// 投稿者の公開プロフィール。
    /// ⚠️ `User`（`users` コレクション）ではなく `PublicProfile`（`publicProfiles`）を保持する。
    /// `users` は Firestore Security Rules で `isOwner` 制限がかかっており、
    /// 他人のドキュメントは読めないため（HomeViewModel / UserProfileViewModel と同じ方針）。
    @Published var author: PublicProfile?
    @Published var isLoadingAuthor = false
    @Published var errorMessage: String?
    /// 通報・ブロック処理のエラー
    @Published var reportError: String?
    /// 投稿削除処理のエラー
    @Published var deleteError: String?

    private let firestoreService: FirestoreServiceProtocol
    private let authService: AuthServiceProtocol
    private let storageService: StorageServiceProtocol

    init(firestoreService: FirestoreServiceProtocol = FirestoreService(),
         authService: AuthServiceProtocol = AuthService(),
         storageService: StorageServiceProtocol = StorageService())
    {
        self.firestoreService = firestoreService
        self.authService = authService
        self.storageService = storageService
    }

    /// 投稿の最新状態を取り直す。
    ///
    /// 再編集（投稿済み画像の上書き更新）は同じ postId のドキュメントを新しい画像URL・
    /// 公開範囲・レシピで置き換えるが、投稿詳細画面が保持する `post` スナップショットは
    /// 自動更新されない。放置すると、再編集後に戻ってきた投稿詳細から共有カードを
    /// 書き出すと削除済みの旧Storage画像をDLしたり、旧 visibility を基準に
    /// 位置情報の既定表示が決まってしまう（統合レビューで発見）。
    /// `.postCreated` 通知（再編集の保存完了時にも発火）を受けて呼び出す想定。
    /// - Parameter postId: 取り直す投稿のID
    /// - Returns: 取得できた最新の投稿。失敗時は nil（呼び出し側は直前の post を保持し、表示を壊さない）
    func refreshPost(postId: String) async -> Post? {
        do {
            return try await firestoreService.fetchPost(postId: postId)
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.refreshPost")
            return nil
        }
    }

    /// 投稿者情報（公開プロフィール）を読み込む。
    ///
    /// ⚠️ 参照先は必ず `publicProfiles`（`fetchPublicProfile`）にすること。
    /// `fetchUser` が読む `users` コレクションは `firestore.rules` の
    /// `allow read: if isOwner(userId)` により **他人のドキュメントでは権限エラーになる**。
    /// その結果、他人の投稿詳細では取得が必ず失敗し、描画側の
    /// `if let user = viewModel.author` が偽になって著者ブロックごと無言で消えていた。
    ///
    /// 失敗時は `errorMessage` に載せず `ErrorHandler.logError` のみに留める。
    /// この画面には `errorMessage` を監視してアラートを出す導線が無く、
    /// セットしても誰にも見えないため。ただし原因追跡のためログは必ず残す。
    /// - Parameter userId: 投稿者のユーザーID
    func loadAuthor(userId: String) async {
        isLoadingAuthor = true

        do {
            author = try await firestoreService.fetchPublicProfile(userId: userId)
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.loadAuthor")
        }

        isLoadingAuthor = false
    }

    // MARK: - Report & Block

    /// ログインしているか（uid があるか）⭐️
    ///
    /// ゲスト（ログインしていない人）は通報もブロックも送れない（`firestore.rules` の reports の create は
    /// 認証済みだけ）。画面はこれが false のとき、通報理由の選択やブロックの確認に進まずに
    /// 「ログインが必要です」の案内を出す。
    /// 判定の基準は下の `submitReport` / `blockPostAuthor` の guard と同じ「uid があるか」にそろえる
    /// （`AuthViewModel.isGuest` は見ない。ログイン中に uid が取れないときも、送れないので同じ扱いにするため）。
    var isSignedIn: Bool {
        authService.currentUser()?.id != nil
    }

    /// 通報を送信する
    ///
    /// ⚠️ 成功の表示（「通報しました」）は、この返り値だけで決めること。以前は画面が
    ///    「reportError が空＝送れた」と判定していたため、ゲストが通報すると下の guard で何も送らずに抜けても
    ///    reportError が空のままで、送っていないのに「通報しました」が出ていた。
    /// - Returns: 送れたら true。ゲスト（uid が無い）は送らずに false（reportError は空のまま。案内は画面が
    ///   `isSignedIn` を見て先に出す）。送信に失敗したら false で、reportError に理由を入れる。
    func submitReport(post: Post, reason: ReportReason) async -> Bool {
        // 前の失敗の理由を先に消す。残したままだと、今回の結果と前回の失敗が混ざって見える
        reportError = nil
        guard let reporterId = authService.currentUser()?.id else { return false }

        do {
            try await firestoreService.reportPost(
                postId: post.id ?? "",
                reporterId: reporterId,
                reportedUserId: post.userId,
                reason: reason.rawValue
            )
            return true
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.submitReport", userId: reporterId)
            reportError = error.userFriendlyMessage
            return false
        }
    }

    /// 投稿者をブロック
    ///
    /// ⚠️ 画面を閉じるかどうかは、この返り値だけで決めること（通報と同じ理由。以前はゲストが押すと
    ///    何も保存せずに、ブロックできたように画面が閉じていた）。
    /// - Returns: 保存できたら true。ゲスト（uid が無い）は保存せずに false（reportError は空のまま）。
    ///   保存に失敗したら false で、reportError に理由を入れる。
    func blockPostAuthor(post: Post) async -> Bool {
        // 前の失敗の理由を先に消す（通報と同じ）
        reportError = nil
        guard let currentUserId = authService.currentUser()?.id else { return false }

        do {
            try await firestoreService.blockUser(userId: currentUserId, blockedUserId: post.userId)
            // ブロックできたら、開いている一覧（ホーム・ForYou・タグ・ギャラリー）に伝えて、
            // その人の投稿を消してもらう ⭐️（詳細画面を閉じても、一覧は引っ張って更新するまで
            // その人の投稿を出し続けていた）。失敗したときは送らない（一覧から消したのに実際は
            // ブロックされていない、を防ぐ）
            NotificationCenter.default.post(
                name: .userBlocked,
                object: nil,
                userInfo: [Notification.blockedUserIdKey: post.userId]
            )
            return true
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.blockPostAuthor", userId: currentUserId)
            reportError = error.userFriendlyMessage
            return false
        }
    }

    // MARK: - Delete Post

    /// ログイン中のユーザーが自分の投稿かどうか
    func isOwnPost(_ post: Post) -> Bool {
        guard let currentUserId = authService.currentUser()?.id else { return false }
        return post.userId == currentUserId
    }

    /// 投稿を削除する（自分の投稿のみ）。成功時は true を返す。
    /// 削除失敗時は deleteError にメッセージをセットして false を返す。
    /// - Parameter post: 削除する投稿
    /// - Returns: 削除成功なら true
    func deletePost(_ post: Post) async -> Bool {
        guard let userId = authService.currentUser()?.id else {
            deleteError = "ログインが必要です"
            return false
        }
        deleteError = nil

        do {
            try await RetryableOperation.executeIfRetryable {
                try await self.firestoreService.deletePost(postId: post.id, userId: userId)
            }

            // Storage 画像の削除（ベストエフォート・並列実行）
            await storageService.deletePostImages(post)
            return true
        } catch {
            ErrorHandler.logError(error, context: "PostDetailViewModel.deletePost", userId: userId)
            deleteError = error.userFriendlyMessage
            return false
        }
    }
}

// MARK: - ブロック通知 ☁️

extension Notification.Name {
    /// 投稿者をブロックした時に送信される通知 ☁️
    ///
    /// userInfo の `Notification.blockedUserIdKey` に、ブロックした相手のユーザー ID（String）が入る。
    /// ホーム・ForYou・タグ・ギャラリーの一覧（`PaginatedPostsViewModel`）が受け取り、
    /// 表示中の投稿と以降のページからその人の投稿を除く（投稿詳細でブロックしても、
    /// 一覧が引っ張って更新するまでその人の投稿を出し続けていた不具合の対策）。
    static let userBlocked = Notification.Name("com.soramoyou.userBlocked")
}

extension Notification {
    /// `.userBlocked` の userInfo で、ブロックした相手のユーザー ID を入れるキー
    static let blockedUserIdKey = "blockedUserId"
}
