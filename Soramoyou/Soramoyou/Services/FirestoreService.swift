//
//  FirestoreService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import FirebaseFirestore
import Foundation

protocol FirestoreServiceProtocol {
    // Posts
    func createPost(_ post: Post) async throws -> Post
    /// 既存投稿を上書き更新する（再編集）。likesCount/commentsCount/createdAt/userId は保持して呼ぶこと
    /// （Firestore ルール isValidPostUpdate がカウント不変を要求するため）。postsCount は加算しない。
    func updatePost(_ post: Post) async throws -> Post
    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post]
    func fetchPostsWithSnapshot(limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?)
    /// ギャラリータブ用: 時間帯／空の種類の絞り込みと並び替え（新着/人気）に対応したページング取得
    func fetchPostsWithSnapshot(
        timeOfDay: TimeOfDay?,
        skyType: SkyType?,
        sortField: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?)
    func fetchPost(postId: String) async throws -> Post
    func deletePost(postId: String, userId: String) async throws
    func fetchUserPosts(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post]
    /// 自分のプロフィールのグリッド用: 次ページのカーソル（最後のドキュメント）も一緒に返す ⭐️
    func fetchUserPostsPage(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?)
    /// 他ユーザーのプロフィール用: 閲覧可能な公開範囲だけに絞って投稿を取得する ⭐️
    /// - Important: `fetchUserPosts` は公開範囲で絞らないため、他人のプロフィールで使うと
    ///   Firestore Security Rules が「private も含みうるクエリ」と判断してクエリ全体が
    ///   permission-denied になる。他人のプロフィールでは必ず本メソッドを使う。
    /// - Parameter visibilities: 呼び出し側が「rules で読めると証明できる」公開範囲だけを渡すこと。
    func fetchVisibleUserPosts(
        userId: String,
        visibilities: [Visibility],
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> [Post]
    
    // Drafts
    func saveDraft(_ draft: Draft) async throws -> Draft
    func fetchDrafts(userId: String) async throws -> [Draft]
    func loadDraft(draftId: String) async throws -> Draft
    func deleteDraft(draftId: String) async throws

    // Users (機密情報含む - 所有者のみ)
    func fetchUser(userId: String) async throws -> User
    func updateUser(_ user: User) async throws -> User
    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws
    /// 通知の配信プレフ3つ（＋updatedAt）だけを更新するターゲット更新。
    /// User 全体を書く updateUser と違い、followersCount 等の他フィールドを古い値で巻き戻さない。
    func updateNotificationPreferences(userId: String, notifyReactions: Bool, notifyNewPostsFromFollowing: Bool, notifyNewPostsFromEveryone: Bool) async throws
    /// 投稿数を count() 集計で数え直し、users（全投稿）と publicProfiles（公開投稿のみ）へ保存する ⭐️
    /// - Returns: 全投稿数（本人のプロフィールに表示する値）
    @discardableResult
    func recountPostsCount(userId: String) async throws -> Int
    /// ハッシュタグをフォローする（users/{uid}.followedTags へ arrayUnion）⭐️
    /// ⚠️ 30件の上限チェックは呼び出し側で行うこと（arrayUnion は上限を知らない）。
    func followTag(userId: String, tag: String) async throws
    /// ハッシュタグのフォローを解除する（users/{uid}.followedTags から arrayRemove）⭐️
    func unfollowTag(userId: String, tag: String) async throws

    // Public Profiles (公開情報のみ - 認証済みユーザー)
    func fetchPublicProfile(userId: String) async throws -> PublicProfile
    /// プロフィール編集で本人が変更できる公開情報だけをターゲット更新する。
    /// PublicProfile 全体を書くと followersCount / followingCount
    /// （Cloud Functions が真値を代入する）を古い値で潰すため、
    /// 公開プロフィールの更新経路はこのメソッドに限定する。
    func updatePublicProfileFields(userId: String, displayName: String?, photoURL: String?, bio: String?) async throws
    func createPublicProfile(from user: User) async throws

    // Recommended Skies（私のおすすめの空）⭐️
    /// おすすめの空に投稿を追加する（トランザクションで上限と重複を守る）
    /// - Returns: 追加結果（追加後／現在の一覧を含む）
    /// - Throws: 公開プロフィールが無ければ `FirestoreServiceError.notFound`
    ///   （呼び出し側が `createPublicProfile` してから再試行できるようにするため）
    func addRecommendedPost(postId: String, userId: String) async throws -> RecommendedSkies.AddResult
    /// おすすめの空から投稿を外す（トランザクションで最新の一覧から外す）
    /// - Returns: 外した後の一覧（公開プロフィールが無ければ空配列）
    func removeRecommendedPosts(_ postIds: Set<String>, userId: String) async throws -> [String]
    /// おすすめの空の中で投稿を前後に動かす（トランザクションで最新の一覧に対して動かす）
    /// - Returns: 動かした後の一覧（公開プロフィールが無ければ空配列）
    func moveRecommendedPost(_ postId: String, by offset: Int, userId: String) async throws -> [String]
    /// 公開プロフィールが無いときだけ作成する（既にあれば何もしない・トランザクション）
    func createPublicProfileIfMissing(from user: User) async throws

    // Account
    func deleteUserData(userId: String) async throws

    // Report / Block
    func reportPost(postId: String, reporterId: String, reportedUserId: String, reason: String) async throws
    func blockUser(userId: String, blockedUserId: String) async throws
    func unblockUser(userId: String, blockedUserId: String) async throws
    func fetchBlockedUserIds(userId: String) async throws -> [String]

    /// 指定した投稿群に付いた「いいね」を取得する ⭐️
    ///
    /// 「あなたの投稿に反応した人」一覧のためのメソッド。呼び出し側は **自分の投稿の ID** を渡す。
    /// - Parameter postIds: 対象の投稿 ID（Firestore の `in` 上限により最大 30 件）
    /// - Returns: いいね（新しい順への並べ替えは呼び出し側の責任）
    func fetchLikes(forPostIds postIds: [String]) async throws -> [Like]

    /// 指定期間に押された「いいね」を新しい順に取得する（いいねランキングの集計用）⭐️
    ///
    /// - Parameters:
    ///   - start: 期間の開始（含む）
    ///   - end: 期間の終了（含む）
    ///   - limit: 読み取り上限（新しい順に読むので、超えた分は期間の古い側が切り捨てられる）
    /// - Returns: いいね（createdAt の新しい順）
    func fetchLikes(from start: Date, to end: Date, limit: Int) async throws -> [Like]

    // Search
    func searchByHashtag(_ hashtag: String) async throws -> [Post]
    func searchByColor(_ color: String, threshold: Double?) async throws -> [Post]
    func searchByTimeOfDay(_ timeOfDay: TimeOfDay) async throws -> [Post]
    func searchBySkyType(_ skyType: SkyType) async throws -> [Post]
    func searchPosts(
        hashtag: String?,
        color: String?,
        timeOfDay: TimeOfDay?,
        skyType: SkyType?,
        colorThreshold: Double?,
        limit: Int
    ) async throws -> [Post]

    // Likes
    /// いいねの追加/解除を明示指定で書く（冪等。既にその状態なら書かない）。戻り値は書き込み後の likesCount
    func setLike(postId: String, userId: String, isLiked: Bool) async throws -> Int
    func checkLikeStatus(postId: String, userId: String) async throws -> Bool
    func batchCheckLikeStatus(postIds: [String], userId: String) async throws -> Set<String>

    // Favorites（私のお気に入りの空）⭐️
    /// お気に入りの追加/解除を明示指定で書く（冪等。既にその状態なら何もしないのと同じ結果）
    func setFavorite(postId: String, userId: String, isFavorited: Bool) async throws
    /// 表示中の投稿群のうちお気に入り済みの postId を返す（1件ずつ get・likes と同じ方式）
    func batchCheckFavoriteStatus(postIds: [String], userId: String) async throws -> Set<String>
    /// 自分のお気に入りを新しい順に1ページ返す。`after` は前ページ末尾の createdAt（nil=先頭）
    func fetchFavorites(userId: String, limit: Int, after: Date?) async throws -> [Favorite]

    // Comments
    func fetchComments(postId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> (comments: [Comment], lastDocument: DocumentSnapshot?)
    func addComment(postId: String, userId: String, content: String, authorName: String?, authorPhotoURL: String?) async throws -> Comment
    func deleteComment(commentId: String, postId: String, userId: String) async throws

    // Feedback
    func submitFeedback(_ feedback: Feedback) async throws
}

class FirestoreService: FirestoreServiceProtocol {
    private let db: Firestore
    /// 認証サービス（Firebase直参照を排除し、テスタビリティを向上）
    private let authService: AuthServiceProtocol

    // コレクション参照
    private var postsCollection: CollectionReference {
        db.collection("posts")
    }

    private var draftsCollection: CollectionReference {
        db.collection("drafts")
    }

    private var usersCollection: CollectionReference {
        db.collection("users")
    }

    private var publicProfilesCollection: CollectionReference {
        db.collection("publicProfiles")
    }

    /// フォロー関係コレクション（ドキュメントID: {followerId}_{followeeId}）⭐️
    /// 退会時に自分が絡む関係を両方向とも消すために参照する。
    /// ⚠️ rules は list に `request.query.limit <= 50` を課しているため、
    ///    このコレクションへのクエリは必ず `limit(to:)` を付けること。
    private var followsCollection: CollectionReference {
        db.collection("follows")
    }

    /// `follows` の list 上限（firestore.rules の `request.query.limit <= 50` に合わせる）
    private static let followsPageSize = 50

    private var likesCollection: CollectionReference {
        db.collection("likes")
    }

    /// 退会時に likes / comments を取りに行く 1 ページの件数 ⭐️
    /// rules の list は `isAuthenticated()` のみで上限は無いが、follows と同じ
    /// 「上限つきで取って消す」を繰り返す形に揃える（1 回の取得が肥大しないように）。
    private static let reactionsPageSize = 50

    /// お気に入りサブコレクション参照（users/{userId}/favorites）⭐️
    /// サブコレクションにすることで、一覧クエリが `order(by: createdAt)` 1本になり
    /// 複合インデックスが不要になる（index 欠落による「件数だけ増えて中身が出ない」事故の構造的な予防）。
    private func favoritesCollection(userId: String) -> CollectionReference {
        usersCollection.document(userId).collection("favorites")
    }

    /// `fetchLikes` の読み取り上限（暴走防止の非常弁。正確な上位 N 件ではない）
    private static let likesFetchLimit = 500

    private var commentsCollection: CollectionReference {
        db.collection("comments")
    }

    init(db: Firestore = Firestore.firestore(), authService: AuthServiceProtocol = AuthService()) {
        self.db = db
        self.authService = authService
    }

    // MARK: - Posts

    func createPost(_ post: Post) async throws -> Post {
        do {
            let data = post.toFirestoreData()
            let docRef = postsCollection.document(post.id)

            try await docRef.setData(data)

            // 投稿数は +1 せず数え直す（publicProfiles は公開投稿だけを数えるため、
            // 公開範囲を見ずに +1 すると非公開投稿の分だけズレる）
            await recountPostsCountLogged(userId: post.userId)

            // 作成された投稿を返す（IDは既に設定されている）
            return post
        } catch let error as FirestoreServiceError {
            throw error
        } catch {
            throw FirestoreServiceError.createFailed(error)
        }
    }

    /// 既存投稿を上書き更新（再編集）。同じ docId に setData で全置換する。
    /// 呼び出し側で likesCount/commentsCount/createdAt/userId を保持済みであること（ルール要件）。
    /// 新規作成ではないので postsCount のインクリメントは行わない。
    func updatePost(_ post: Post) async throws -> Post {
        do {
            let data = post.toFirestoreData()
            try await postsCollection.document(post.id).setData(data)
            // 再編集で公開範囲（公開⇄非公開）が変わりうるので、公開投稿数を数え直す
            await recountPostsCountLogged(userId: post.userId)
            return post
        } catch let error as FirestoreServiceError {
            throw error
        } catch {
            throw FirestoreServiceError.createFailed(error)
        }
    }

    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] {
        do {
            var query: Query = postsCollection
                .whereField("visibility", isEqualTo: Visibility.public.rawValue)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)

            // ページネーション: lastDocumentが指定されている場合は、そのドキュメントの後に続くドキュメントを取得
            if let lastDocument {
                query = query.start(afterDocument: lastDocument)
            }

            let snapshot = try await query.getDocuments()

            return PostDocumentDecoder.decodePosts(snapshot.documents, source: "public_posts")
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    /// 投稿を取得（DocumentSnapshotも返す）
    func fetchPostsWithSnapshot(limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        do {
            var query: Query = postsCollection
                .whereField("visibility", isEqualTo: Visibility.public.rawValue)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)

            // ページネーション: lastDocumentが指定されている場合は、そのドキュメントの後に続くドキュメントを取得
            if let lastDocument {
                query = query.start(afterDocument: lastDocument)
            }

            let snapshot = try await query.getDocuments()

            // 壊れた投稿は 1 件だけ飛ばし、ページ全体は落とさない。
            // 次ページの起点は飛ばした分も含めた snapshot.documents.last のまま（下で返す）
            let posts = PostDocumentDecoder.decodePosts(snapshot.documents, source: "home_feed")

            // 最後のドキュメントを取得
            let lastDoc = snapshot.documents.last

            return (posts: posts, lastDocument: lastDoc)
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    /// ギャラリータブ用: 絞り込み（時間帯／空の種類）＋並び替え（新着/人気）＋ページング取得
    ///
    /// クエリ構築は `PostQueryBuilder.buildGalleryQuery` に委譲し、
    /// FirestoreService はデータ取得のみに集中する。
    func fetchPostsWithSnapshot(
        timeOfDay: TimeOfDay?,
        skyType: SkyType?,
        sortField: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        do {
            let query = PostQueryBuilder.buildGalleryQuery(
                collection: postsCollection,
                timeOfDay: timeOfDay,
                skyType: skyType,
                sortField: sortField,
                limit: limit,
                lastDocument: lastDocument
            )

            let snapshot = try await query.getDocuments()

            // 壊れた投稿は 1 件だけ飛ばし、ページ全体は落とさない。
            // 次ページの起点は飛ばした分も含めた snapshot.documents.last のまま（下で返す）
            let posts = PostDocumentDecoder.decodePosts(snapshot.documents, source: "gallery")

            return (posts: posts, lastDocument: snapshot.documents.last)
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    func fetchPost(postId: String) async throws -> Post {
        do {
            let document = try await postsCollection.document(postId).getDocument()

            guard document.exists,
                  let data = document.data()
            else {
                throw FirestoreServiceError.notFound
            }

            return try Post(from: data)
        } catch let error as FirestoreServiceError {
            throw error
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    func deletePost(postId: String, userId: String) async throws {
        do {
            // 投稿の所有者を確認
            let document = try await postsCollection.document(postId).getDocument()
            guard let data = document.data(),
                  let postUserId = data["userId"] as? String
            else {
                throw FirestoreServiceError.notFound
            }

            // 認可チェック: 自分の投稿のみ削除可能
            guard postUserId == userId else {
                throw FirestoreServiceError.unauthorized
            }

            try await postsCollection.document(postId).delete()

            // 投稿数は −1 せず数え直す（createPost と同じ理由）
            await recountPostsCountLogged(userId: userId)
        } catch let error as FirestoreServiceError {
            throw error
        } catch {
            throw FirestoreServiceError.deleteFailed(error)
        }
    }

    func fetchUserPosts(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] {
        do {
            var query: Query = postsCollection
                .whereField("userId", isEqualTo: userId)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)

            // ページネーション
            if let lastDocument {
                query = query.start(afterDocument: lastDocument)
            }

            let snapshot = try await query.getDocuments()

            return PostDocumentDecoder.decodePosts(snapshot.documents, source: "user_posts")
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    /// 自分の投稿を 1 ページ分取得し、次ページ用のカーソルも返す ⭐️
    ///
    /// `fetchUserPosts` と同じクエリ形状（userId 等値 + createdAt 降順）なので、
    /// 既存の複合インデックスでそのまま動く（新規インデックス不要）。
    /// - Returns: 投稿と「このページの最後のドキュメント」。ページが空なら lastDocument は nil。
    func fetchUserPostsPage(
        userId: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        do {
            var query: Query = postsCollection
                .whereField("userId", isEqualTo: userId)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)

            if let lastDocument {
                query = query.start(afterDocument: lastDocument)
            }

            let snapshot = try await query.getDocuments()
            // ⚠️ compactMap { try? } で黙って落とさない（tech-spec のルール）。
            //    壊れたドキュメントは 1 件だけスキップし、パスを必ずログに残す。
            let posts: [Post] = snapshot.documents.compactMap { document in
                do {
                    return try Post(from: document.data())
                } catch {
                    print("❌ 投稿デコード失敗 path=\(document.reference.path) error=\(error.localizedDescription)")
                    return nil
                }
            }
            // カーソルはデコード失敗分も含めた「実際に読んだ最後の 1 件」にする
            // （デコード後の配列で決めると、壊れたドキュメントが末尾にあるとき同じページを読み直す）
            return (posts, snapshot.documents.last)
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }
    
    /// 指定ユーザーの投稿のうち、指定した公開範囲のものだけを取得する ⭐️
    ///
    /// Firestore Security Rules は「フィルタ」ではなく「静的な証明」であり、
    /// クエリが返しうる結果集合の中に 1 件でも読めない可能性があるドキュメントが
    /// 含まれると **クエリ全体** が permission-denied になる。
    /// そのため他ユーザーのプロフィールでは `visibility` をクエリ側で必ず絞り込む。
    ///
    /// - Parameters:
    ///   - userId: 対象ユーザーの ID
    ///   - visibilities: 取得したい公開範囲（呼び出し側が rules を満たせるものだけを渡す）
    ///   - limit: 取得件数の上限
    ///   - lastDocument: ページネーション用の直前ページ末尾ドキュメント。
    ///     ⚠️ 同一の visibilities 集合で取得したカーソルのみ有効（要素 1 件は isEqualTo・
    ///     複数件は in とクエリ形状が変わるため、フォロー状態が変わったらカーソルは破棄すること）
    /// - Returns: 新しい順（createdAt 降順）の投稿配列
    /// - Note: 複合インデックス `visibility ASC + userId ASC + createdAt DESC` が必要。
    ///   `firestore.indexes.json` に追加済みだが **deploy は別作業**（未 deploy だと
    ///   permission-denied ではなく failed-precondition のインデックス欠落エラーになる）。
    ///   等値フィールドの並び順は既存 posts インデックス（visibility を先頭に置く形）に
    ///   合わせているが、確定値は初回実行時のエラーに含まれるインデックス作成リンクが正。
    func fetchVisibleUserPosts(
        userId: String,
        visibilities: [Visibility],
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> [Post] {
        // 空配列を渡された場合、Firestore の `in` は空配列を受け付けずクラッシュするため
        // クエリを投げずに空を返す（「読めるものが何も無い」＝正しい結果）。
        guard !visibilities.isEmpty else { return [] }
        
        do {
            let rawValues = visibilities.map { $0.rawValue }
            var query: Query = postsCollection
            
            // ⚠️ 1 件だけなら `in` ではなく `isEqualTo` を使う。
            //    `in` は要素数 1 でも「論理和クエリ」として扱われ、rules の評価経路が
            //    既存の公開一覧（`visibility == 'public'`）と変わってしまう。
            //    本 PR は「rules が followers 枝で通るか」を確かめる実験を兼ねるため、
            //    未フォロー時（public のみ）は既知の安全な形と完全に同じ形にして
            //    失敗したときの原因を一意に切り分けられるようにする。
            if rawValues.count == 1 {
                query = query.whereField("visibility", isEqualTo: rawValues[0])
            } else {
                query = query.whereField("visibility", in: rawValues)
            }
            
            query = query
                .whereField("userId", isEqualTo: userId)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)
            
            // ページネーション
            if let lastDocument = lastDocument {
                query = query.start(afterDocument: lastDocument)
            }
            
            let snapshot = try await query.getDocuments()
            
            // ⚠️ 壊れたドキュメント 1 件でクエリ全体を落とさない。
            //    ここで throw すると「rules 拒否 / インデックス欠落 / 不正データ」が
            //    すべて同じ fetchFailed に潰れ、失敗原因の切り分け（followers 枝が
            //    rules を通るかを確かめる R1 プローブ）ができなくなる。
            //    デコードに失敗したドキュメントはパスをログに残し 1 件だけスキップする。
            return snapshot.documents.compactMap { document in
                do {
                    return try Post(from: document.data())
                } catch {
                    print("❌ 投稿デコード失敗 path=\(document.reference.path) error=\(error.localizedDescription)")
                    return nil
                }
            }
        } catch {
            // クエリ全体の失敗（権限・インデックス欠落・ネットワーク）は呼び出し側に伝播する。
            throw FirestoreServiceError.fetchFailed(error)
        }
    }
    
    // MARK: - Drafts

    func saveDraft(_ draft: Draft) async throws -> Draft {
        do {
            let data = draft.toFirestoreData()
            let docRef = draftsCollection.document(draft.id)

            try await docRef.setData(data)

            return draft
        } catch {
            throw FirestoreServiceError.createFailed(error)
        }
    }

    func fetchDrafts(userId: String) async throws -> [Draft] {
        do {
            let snapshot = try await draftsCollection
                .whereField("userId", isEqualTo: userId)
                .order(by: "updatedAt", descending: true)
                .getDocuments()

            return try snapshot.documents.compactMap { document in
                try Draft(from: document.data())
            }
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    func loadDraft(draftId: String) async throws -> Draft {
        do {
            let document = try await draftsCollection.document(draftId).getDocument()

            guard document.exists,
                  let data = document.data()
            else {
                throw FirestoreServiceError.notFound
            }

            return try Draft(from: data)
        } catch let error as FirestoreServiceError {
            throw error
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    func deleteDraft(draftId: String) async throws {
        do {
            try await draftsCollection.document(draftId).delete()
        } catch {
            throw FirestoreServiceError.deleteFailed(error)
        }
    }

    // MARK: - Users

    func fetchUser(userId: String) async throws -> User {
        do {
            let document = try await usersCollection.document(userId).getDocument()

            guard document.exists,
                  let data = document.data()
            else {
                throw FirestoreServiceError.notFound
            }

            return try User(from: data)
        } catch let error as FirestoreServiceError {
            throw error
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    func updateUser(_ user: User) async throws -> User {
        do {
            let data = user.toFirestoreData()
            let docRef = usersCollection.document(user.id)

            try await docRef.setData(data, merge: true)

            return user
        } catch {
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    func updateNotificationPreferences(userId: String, notifyReactions: Bool, notifyNewPostsFromFollowing: Bool, notifyNewPostsFromEveryone: Bool) async throws {
        do {
            // 通知プレフ3つ＋updatedAt だけを更新（updateData）。User 全体を書かないので
            // followersCount 等を古い値で巻き戻さない。ドキュメントは所有者のプロフィールで必ず存在する。
            try await usersCollection.document(userId).updateData([
                "notifyReactions": notifyReactions,
                "notifyNewPostsFromFollowing": notifyNewPostsFromFollowing,
                "notifyNewPostsFromEveryone": notifyNewPostsFromEveryone,
                "updatedAt": Timestamp(date: Date()),
            ])
        } catch {
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws {
        do {
            let docRef = usersCollection.document(userId)
            let toolsStrings = tools.map(\.rawValue)

            // まずドキュメントの存在を確認
            let document = try await docRef.getDocument()

            if document.exists {
                // ドキュメントが存在する場合はupdateData()で更新
                try await docRef.updateData([
                    "customEditTools": toolsStrings,
                    "customEditToolsOrder": order,
                ])
            } else {
                // ドキュメントが存在しない場合は、必要なフィールドを含めて作成
                // AuthServiceProtocol経由で現在のユーザー情報を取得
                guard let currentUser = authService.currentUser() else {
                    throw FirestoreServiceError.updateFailed(NSError(domain: "FirestoreService", code: -1, userInfo: [NSLocalizedDescriptionKey: "ユーザーがログインしていません"]))
                }

                // 匿名ユーザー（Anonymous Auth）はemailがnilのため、
                // emailフィールドはnilでない場合のみ含める
                var newUserData: [String: Any] = [
                    "id": userId,
                    "createdAt": Timestamp(date: Date()),
                    "customEditTools": toolsStrings,
                    "customEditToolsOrder": order,
                ]

                if let email = currentUser.email {
                    newUserData["email"] = email
                }

                try await docRef.setData(newUserData)
            }
        } catch let error as FirestoreServiceError {
            throw error
        } catch {
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    /// 投稿数を count() 集計で数え直して保存する ⭐️
    ///
    /// 旧実装（syncPostsCount）は「画面用に取得した最新 50 件」の件数をそのまま保存していたため、
    /// 投稿が 50 件を超えると postsCount が 50 に書き戻されていた。
    /// count() はドキュメントの中身を読まずに件数だけをサーバーで数えるので、取得上限に左右されない。
    ///
    /// - users.postsCount: 全投稿（本人だけが見る値。非公開・フォロワー限定を含む）
    /// - publicProfiles.postsCount: 公開投稿のみ（他人に見せる値。非公開投稿の件数を漏らさない）
    ///
    /// どちらのクエリも等値フィルタだけなので複合インデックスは不要。
    /// Security Rules 上も「userId == 自分」は isOwner で、「visibility == public」は公開枝で証明できる。
    /// - Returns: 全投稿数
    @discardableResult
    func recountPostsCount(userId: String) async throws -> Int {
        do {
            let ownPosts = postsCollection.whereField("userId", isEqualTo: userId)
            let allSnapshot = try await ownPosts.count.getAggregation(source: .server)
            let publicSnapshot = try await ownPosts
                .whereField("visibility", isEqualTo: Visibility.public.rawValue)
                .count.getAggregation(source: .server)
            let allCount = allSnapshot.count.intValue
            let publicCount = publicSnapshot.count.intValue

            try await usersCollection.document(userId).updateData(["postsCount": allCount])
            // publicProfiles が存在しない場合はエラーを無視（マイグレーション未実施ユーザー対応）
            // ⚠️ ただし黙って落とさない。今はここが publicProfiles.postsCount の唯一の書き込み経路なので、
            //    未作成以外の理由（通信・権限など）で失敗し続けても気づけるようログに残す。
            //    users 側は保存済みなので throw はしない（呼び出し元の契約は変えない）。
            do {
                try await publicProfilesCollection.document(userId).updateData(["postsCount": publicCount])
            } catch {
                print("⚠️ publicProfiles.postsCount 更新失敗 userId=\(userId) error=\(error.localizedDescription)")
            }
            return allCount
        } catch {
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    /// 投稿の作成・更新・削除のついでに数え直す。
    /// 投稿そのものは成功しているので、数え直しの失敗で呼び出し元を失敗扱いにはしない
    /// （次にプロフィールを開いたときに再度数え直される）。ただし必ずログに残す。
    private func recountPostsCountLogged(userId: String) async {
        do {
            try await recountPostsCount(userId: userId)
        } catch {
            print("⚠️ 投稿数の数え直しに失敗 userId=\(userId) error=\(error.localizedDescription)")
        }
    }

    // MARK: - Followed Tags ⭐️

    /// ハッシュタグをフォローする
    ///
    /// `users/{uid}.followedTags` に arrayUnion で追加する。既にフォロー済みの場合は
    /// arrayUnion が重複を作らないため何度呼んでも安全（冪等）。
    ///
    /// ⚠️ 上限（`User.maxFollowedTags` = 30件）のチェックはここでは行わない。
    ///    arrayUnion は配列長を知らないため、呼び出し側で現在値を取得して判定すること。
    /// ⚠️ タグは正規化しない。保存済み `posts.hashtags` と完全一致させる必要がある。
    ///
    /// firestore.rules: users の所有者 update が既に許可済みのため、ルール追加は不要
    /// （id / email を変更しないので `isOwner` 条件を満たす。updateEditTools と同じ経路）。
    func followTag(userId: String, tag: String) async throws {
        do {
            try await usersCollection.document(userId).updateData([
                "followedTags": FieldValue.arrayUnion([tag]),
                "updatedAt": Timestamp(date: Date()),
            ])
        } catch {
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    /// ハッシュタグのフォローを解除する
    ///
    /// `users/{uid}.followedTags` から arrayRemove で取り除く。
    /// 未フォローのタグを渡しても何も起きない（冪等）。
    func unfollowTag(userId: String, tag: String) async throws {
        do {
            try await usersCollection.document(userId).updateData([
                "followedTags": FieldValue.arrayRemove([tag]),
                "updatedAt": Timestamp(date: Date()),
            ])
        } catch {
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    // MARK: - Search

    func searchByHashtag(_ hashtag: String) async throws -> [Post] {
        do {
            let snapshot = try await postsCollection
                .whereField("hashtags", arrayContains: hashtag)
                .whereField("visibility", isEqualTo: Visibility.public.rawValue)
                .order(by: "createdAt", descending: true)
                .getDocuments()

            return PostDocumentDecoder.decodePosts(snapshot.documents, source: "search_hashtag")
        } catch {
            throw FirestoreServiceError.searchFailed(error)
        }
    }

    func searchByColor(_ color: String, threshold: Double? = nil) async throws -> [Post] {
        do {
            // まず、色を含む投稿を取得（完全一致）
            let snapshot = try await postsCollection
                .whereField("skyColors", arrayContains: color)
                .whereField("visibility", isEqualTo: Visibility.public.rawValue)
                .order(by: "createdAt", descending: true)
                .getDocuments()

            var posts = PostDocumentDecoder.decodePosts(snapshot.documents, source: "search_color")

            // 閾値が指定されている場合は、ColorMatchingでRGB距離フィルタリングを適用
            if let threshold {
                posts = ColorMatching.filterPostsByColorDistance(
                    posts: posts, targetColor: color, threshold: threshold
                )
            }

            return posts
        } catch {
            throw FirestoreServiceError.searchFailed(error)
        }
    }

    func searchByTimeOfDay(_ timeOfDay: TimeOfDay) async throws -> [Post] {
        do {
            let snapshot = try await postsCollection
                .whereField("timeOfDay", isEqualTo: timeOfDay.rawValue)
                .whereField("visibility", isEqualTo: Visibility.public.rawValue)
                .order(by: "createdAt", descending: true)
                .getDocuments()

            return PostDocumentDecoder.decodePosts(snapshot.documents, source: "search_time_of_day")
        } catch {
            throw FirestoreServiceError.searchFailed(error)
        }
    }

    func searchBySkyType(_ skyType: SkyType) async throws -> [Post] {
        do {
            let snapshot = try await postsCollection
                .whereField("skyType", isEqualTo: skyType.rawValue)
                .whereField("visibility", isEqualTo: Visibility.public.rawValue)
                .order(by: "createdAt", descending: true)
                .getDocuments()

            return PostDocumentDecoder.decodePosts(snapshot.documents, source: "search_sky_type")
        } catch {
            throw FirestoreServiceError.searchFailed(error)
        }
    }

    /// 複合検索（複数条件の組み合わせ）
    /// PostQueryBuilderでクエリ構築、ColorMatchingでクライアントサイドフィルタを実行し、
    /// FirestoreServiceはデータ取得のみに集中する
    func searchPosts(
        hashtag: String? = nil,
        color: String? = nil,
        timeOfDay: TimeOfDay? = nil,
        skyType: SkyType? = nil,
        colorThreshold: Double? = nil,
        limit: Int = 50
    ) async throws -> [Post] {
        do {
            // PostQueryBuilderでFirestoreクエリを構築
            let queryResult = PostQueryBuilder.buildSearchQuery(
                collection: postsCollection,
                hashtag: hashtag,
                color: color,
                timeOfDay: timeOfDay,
                skyType: skyType,
                limit: limit
            )

            // Firestoreからデータを取得
            let snapshot = try await queryResult.query.getDocuments()

            let posts = PostDocumentDecoder.decodePosts(snapshot.documents, source: "search_posts")

            // PostQueryBuilderでクライアントサイドフィルタリングを適用
            return PostQueryBuilder.applyClientSideFilters(
                posts: posts,
                queryResult: queryResult,
                color: color,
                colorThreshold: colorThreshold
            )
        } catch {
            throw FirestoreServiceError.searchFailed(error)
        }
    }

    // MARK: - Account Deletion

    /// ユーザーの全データを削除（公開プロフィール、フォロー、いいね、コメント、投稿、下書き、お気に入り、ユーザードキュメント）
    func deleteUserData(userId: String) async throws {
        // ⭐️ 削除の順番は「人から見えなくなるもの」を先にする。
        //    途中で失敗すると以降の手順は実行されないため（catch で throw する）、
        //    どこで止まっても「見えたまま残る」より「見えなくなる」ほうへ倒す。
        //    投稿の一括削除は件数が多く最も失敗しやすいので、これを先頭に置くと
        //    失敗時に公開プロフィールが残る＝まさに直したかった不具合が再発する。
        //    ⚠️ 全手順が Auth アカウント削除より前に実行される前提（rules が本人にしか
        //       delete を許さないため）。SettingsViewModel の呼び出し順を変えないこと。
        // 失敗時に「8 手順のどこで止まったか」を catch のログに残すための段階名 ⭐️
        // （FirestoreServiceError.deleteFailed は元エラーを保持するが、手順名までは持たない）
        var stage = "publicProfiles"
        do {
            // 1. 公開プロフィールを削除 ⭐️
            //    ここを消し忘れると、Auth アカウントも users も無いのに publicProfiles だけが残り、
            //    退会者が検索結果やフォロー一覧に出続ける（プライバシー事故）。
            try await publicProfilesCollection.document(userId).delete()

            // 2. フォロー関係を両方向とも削除 ⭐️
            //    「自分がフォローした」側（followerId）と「自分がフォローされた」側（followeeId）の
            //    2 本を別々に消す。片方だけだと、退会者が他人のフォロワー一覧に残り続ける。
            //    削除のたびに Cloud Functions の onFollowDeleted が発火し、
            //    相手（残るユーザー）の followersCount / followingCount が数え直される。
            //    退会者自身の publicProfiles は手順 1 で消えているので、Functions 側の存在確認
            //    （reconcileFollowCounters の exists ガード）は false を読み、作り直されない。
            //    ⚠️ ただし users 側は別。Functions の存在確認は get → set(merge) の 2 手で**非原子的**なので、
            //       手順 8 の users 削除が N 回の発火のどれかの get と set の間に落ちると、
            //       カウンタだけの users/{uid} が復活しうる（誰にも見えず PII なし・Admin SDK 掃除で回収可）。
            //       根治（set(merge) → update()）は Functions 側の別 issue #129 で行う。
            stage = "follows.follower"
            try await deleteFollows(field: "followerId", userId: userId)
            stage = "follows.followee"
            try await deleteFollows(field: "followeeId", userId: userId)

            // 3. 自分が付けたいいねを削除し、相手の投稿の likesCount を 1 つ減らす ⭐️（issue #130）
            //    消し忘れると、退会者の uid が「反応してくれた人」一覧（ReactedUsersViewModel）に
            //    publicProfiles の無い「ユーザー」として出続け、フォローボタンまで出てしまう。
            //    1 件ずつ処理する理由・投稿が読めないときの扱いは deleteReactions / deleteReaction 参照。
            stage = "likes"
            try await deleteReactions(collection: likesCollection, counterField: "likesCount", userId: userId)

            // 4. 自分が書いたコメントを削除し、投稿の commentsCount を 1 つ減らす ⭐️（issue #130）
            //    同じ投稿に複数コメントがありうるので、ここは 1 件ずつでないと rules に拒否される。
            stage = "comments"
            try await deleteReactions(collection: commentsCollection, counterField: "commentsCount", userId: userId)

            // 5. ユーザーの投稿を全てバッチ削除
            //    `.server` は deleteFollows の Note と同じ理由（キャッシュの部分集合を「全件」と誤認しない）。
            //    投稿は退会後も公開のまま見え続けるため、follows より取りこぼしの実害が大きい。
            stage = "posts"
            let postsSnapshot = try await postsCollection
                .whereField("userId", isEqualTo: userId)
                .getDocuments(source: .server)

            try await batchDelete(documents: postsSnapshot.documents)

            // 6. ユーザーの下書きを全てバッチ削除
            stage = "drafts"
            let draftsSnapshot = try await draftsCollection
                .whereField("userId", isEqualTo: userId)
                .getDocuments(source: .server)

            try await batchDelete(documents: draftsSnapshot.documents)

            // 7. お気に入りサブコレクションを全件バッチ削除 ⭐️
            //    favorites は本機能で新設した自分のコレクションなので、退会時に確実に消す。
            stage = "favorites"
            let favoritesSnapshot = try await favoritesCollection(userId: userId).getDocuments(source: .server)
            try await batchDelete(documents: favoritesSnapshot.documents)

            // 8. ユーザードキュメントを削除
            stage = "users"
            try await usersCollection.document(userId).delete()
        } catch {
            // どの手順で止まったかを 1 行残す（userId を出すのは postsCount 更新失敗ログと同じ扱い）。
            print("❌ 退会データ削除失敗 stage=\(stage) userId=\(userId) error=\(error.localizedDescription)")
            throw FirestoreServiceError.deleteFailed(error)
        }
    }

    /// 指定フィールドが `userId` に一致する `follows` を、空になるまで削除する ⭐️
    ///
    /// - Important: `follows` の rules は list に `request.query.limit <= 50` を課しているため、
    ///   上限なしの `getDocuments()` は permission-denied になる。必ず `limit(to:)` を付けて
    ///   「50 件取って消す」を繰り返す。`order(by:)` は付けない（付けると複合インデックスが
    ///   必要になり、index の deploy 漏れで退会処理が丸ごと失敗する経路が増える）。
    ///
    /// - Note: 取得は `source: .server` を明示する ⭐️。既定の `.default` は通信断だと
    ///   **ローカルキャッシュへフォールバック**し、キャッシュにあるのは `fetchFollows`（limit 30）で
    ///   過去に見た分だけなので、0 件や部分集合を「全部消えた」と誤認して終わってしまう。
    ///   その後 Auth アカウントが消えると rules を満たせず、残った follows はクライアントから
    ///   二度と消せない。`.server` なら通信断で失敗して退会が止まり、再試行できる
    ///   （安全側にしか働かない）。手順 3〜7 の getDocuments も同じ理由で揃えている。
    ///
    /// - Parameters:
    ///   - field: `"followerId"`（自分がフォローした）または `"followeeId"`（自分がフォローされた）
    ///   - userId: 退会するユーザーの ID
    private func deleteFollows(field: String, userId: String) async throws {
        try await BatchDrainer.drain(
            pageSize: Self.followsPageSize,
            fetch: { pageSize in
                try await self.followsCollection
                    .whereField(field, isEqualTo: userId)
                    .limit(to: pageSize)
                    .getDocuments(source: .server)
                    .documents
            },
            delete: { documents in
                try await self.batchDelete(documents: documents)
            }
        )
    }

    /// 退会者の `likes` / `comments` を空になるまで 1 件ずつ削除し、投稿側のカウンタを 1 つずつ減らす ⭐️
    ///
    /// - Important: 1 件ずつ処理する理由 — rules の `isCountOnlyUpdate` は他人の投稿の
    ///   `likesCount` / `commentsCount` を「変化なし or ±1」しか許さない。同じ投稿へのコメントが
    ///   2 件あるときに 1 回の batch でまとめて消すと -2 になって拒否され、退会が止まる。
    ///   いいねは (userId, postId) で一意なので本来まとめても通るが、コメントと同じ形に揃える。
    ///
    /// - Note: 取得は deleteFollows と同じく `limit(to:)` ＋ `source: .server`（キャッシュの部分集合を
    ///   「全件消えた」と誤認しないため）。`order(by:)` は付けない（複合インデックスを要求しないため）。
    ///
    /// - Parameters:
    ///   - collection: `likes` または `comments`
    ///   - counterField: 減らす投稿側のカウンタ（`"likesCount"` / `"commentsCount"`）
    ///   - userId: 退会するユーザーの ID
    private func deleteReactions(
        collection: CollectionReference,
        counterField: String,
        userId: String
    ) async throws {
        try await BatchDrainer.drain(
            pageSize: Self.reactionsPageSize,
            fetch: { pageSize in
                try await collection
                    .whereField("userId", isEqualTo: userId)
                    .limit(to: pageSize)
                    .getDocuments(source: .server)
                    .documents
            },
            delete: { documents in
                // 1 件ずつ順番に（並列にすると同じ投稿への書き込みが競合してリトライが増えるだけ）
                for document in documents {
                    try await self.deleteReaction(document, counterField: counterField)
                }
            }
        )
    }

    /// いいね / コメント 1 件を削除し、投稿のカウンタを 1 つ減らす ⭐️
    ///
    /// 投稿が「読めない」ことがあるので 3 段構えにする:
    /// - 段 A（通常）: トランザクションで投稿を get し、存在してカウンタが 1 以上のときだけ -1。
    ///   いいね/コメント自体はどちらでも消す。
    /// - 段 B: 段 A が permission-denied / not-found で失敗したら、get せずに
    ///   「削除 ＋ カウンタ -1」を batch で書く。
    /// - 段 C: 段 B も permission-denied / not-found なら、いいね/コメントだけを消す。
    ///
    /// ⚠️ 段 A の get が拒否されるのは次の 3 つ。posts の read rule は 3 つの条件すべてが
    ///    `resource.data` を参照するため、投稿が無い（`resource == null`）と評価エラー＝拒否になり、
    ///    `exists == false` はまず返らない（rules の評価規則からの推論・未実測。返っても段 A で正しく扱う）。
    ///    ① 投稿が既に削除されている ② 他人の非公開（private）投稿
    ///    ③ フォロワー限定投稿（手順 2 で自分の follows を消した後なので、もう読めない）
    ///    ②③ は投稿が存在し、posts の update rule（`isCountOnlyUpdate`）は公開範囲を見ないので
    ///    段 B の -1 が通る。① は段 B が失敗して段 C に落ちる（消えた投稿のカウンタは直す対象が無い）。
    ///    段 B では 0 以下かどうかを確かめられないが、いいね/コメントが残っている以上カウンタは
    ///    1 以上のはずなので、減らさずにズレを残すより減らす側を選んでいる。
    ///
    /// ⚠️ ネットワーク断など上記以外の失敗はそのまま throw する（退会を止めて再試行させる）。
    ///    段 C の削除自体が失敗したときも throw する（ここを消せないと退会者の痕跡が残るため）。
    private func deleteReaction(_ document: QueryDocumentSnapshot, counterField: String) async throws {
        let reactionRef = document.reference

        // postId が無い・壊れているドキュメントは、減らす先が分からないので削除だけする
        // （1 件の壊れたデータで退会全体を止めない）。
        guard let postId = document.data()["postId"] as? String, !postId.isEmpty else {
            print("⚠️ 退会時の削除: postId の無いドキュメントをカウンタ更新なしで削除 path=\(reactionRef.path)")
            try await reactionRef.delete()
            return
        }
        let postRef = postsCollection.document(postId)

        // 段 A: トランザクションで投稿を読み、減らしてよいときだけ -1
        do {
            _ = try await db.runTransaction { transaction, errorPointer in
                let postDoc: DocumentSnapshot
                do {
                    postDoc = try transaction.getDocument(postRef)
                } catch let fetchError as NSError {
                    errorPointer?.pointee = fetchError
                    return nil
                }

                let currentCount = postDoc.data()?[counterField] as? Int
                if FirestoreService.shouldDecrementCounter(postExists: postDoc.exists, currentCount: currentCount) {
                    transaction.updateData([counterField: FieldValue.increment(Int64(-1))], forDocument: postRef)
                }
                transaction.deleteDocument(reactionRef)
                return nil
            }
            return
        } catch {
            guard FirestoreService.isPostUnreachableError(error) else { throw error }
        }

        // 段 B: 投稿を読めない。get せずに「削除 ＋ -1」を書く（非公開・フォロワー限定の投稿はここで直る）
        do {
            let batch = db.batch()
            batch.deleteDocument(reactionRef)
            batch.updateData([counterField: FieldValue.increment(Int64(-1))], forDocument: postRef)
            try await batch.commit()
            return
        } catch {
            guard FirestoreService.isPostUnreachableError(error) else { throw error }
        }

        // 段 C: 投稿が消えている（またはカウンタを書けない）。いいね/コメントだけを消す
        // 「カウンタを書けない」場合はカウンタのズレを黙って残すので、気づけるようにログを残す
        // （postId が無い経路と同じ形。段 A→B は非公開投稿で通常起きるのでログしない）。
        print("⚠️ 退会時の削除: 投稿のカウンタを更新できずリアクションのみ削除 postId=\(postId) path=\(reactionRef.path)")
        try await reactionRef.delete()
    }

    /// 退会時のいいね/コメント削除で、投稿のカウンタを減らしてよいかを判定する ⭐️
    ///
    /// 投稿が存在し、カウンタが 1 以上のときだけ true。0 以下で減らすとマイナスになるため減らさない
    /// （フィールドが無い旧データも 0 扱い＝減らさない）。
    ///
    /// - Parameters:
    ///   - postExists: 投稿ドキュメントが存在するか
    ///   - currentCount: 投稿の現在のカウンタ値（フィールドが無ければ nil）
    static func shouldDecrementCounter(postExists: Bool, currentCount: Int?) -> Bool {
        guard postExists, let currentCount else { return false }
        return currentCount >= 1
    }

    /// 投稿が「読めない / 書けない」ことによる失敗か（permission-denied または not-found）⭐️
    ///
    /// true なら deleteReaction は次の段へ進む。false（ネットワーク断など）は呼び出し側へ throw し、
    /// 退会を止めて再試行させる（カウンタを直さないまま削除だけ進めるのを防ぐ）。
    static func isPostUnreachableError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain else { return false }
        return nsError.code == FirestoreErrorCode.permissionDenied.rawValue
            || nsError.code == FirestoreErrorCode.notFound.rawValue
    }

    /// ドキュメントをバッチ削除（最大500件/バッチ）
    private func batchDelete(documents: [QueryDocumentSnapshot]) async throws {
        // Firestoreのバッチは最大500オペレーション
        let batchSize = 500
        var index = 0

        while index < documents.count {
            let batch = db.batch()
            let end = min(index + batchSize, documents.count)

            for i in index ..< end {
                batch.deleteDocument(documents[i].reference)
            }

            try await batch.commit()
            index = end
        }
    }

    // MARK: - Report

    /// 投稿を通報する
    func reportPost(postId: String, reporterId: String, reportedUserId: String, reason: String) async throws {
        do {
            let reportData: [String: Any] = [
                "postId": postId,
                "reporterId": reporterId,
                "reportedUserId": reportedUserId,
                "reason": reason,
                "createdAt": FieldValue.serverTimestamp(),
            ]
            try await db.collection("reports").addDocument(data: reportData)
        } catch {
            throw FirestoreServiceError.createFailed(error)
        }
    }

    // MARK: - Feedback

    /// アプリ内フィードバックを送信する（`feedback` コレクションに作成）
    func submitFeedback(_ feedback: Feedback) async throws {
        do {
            try await db.collection("feedback")
                .document(feedback.id)
                .setData(feedback.toFirestoreData())
        } catch {
            throw FirestoreServiceError.createFailed(error)
        }
    }

    // MARK: - Block

    /// ユーザーをブロックする
    func blockUser(userId: String, blockedUserId: String) async throws {
        do {
            try await usersCollection.document(userId).updateData([
                "blockedUserIds": FieldValue.arrayUnion([blockedUserId]),
            ])
        } catch {
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    /// ユーザーのブロックを解除する
    func unblockUser(userId: String, blockedUserId: String) async throws {
        do {
            try await usersCollection.document(userId).updateData([
                "blockedUserIds": FieldValue.arrayRemove([blockedUserId]),
            ])
        } catch {
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    /// 指定した投稿群に付いた「いいね」を取得する ⭐️
    /// - Parameter postIds: 対象の投稿 ID（Firestore の `in` 上限により最大 30 件に切る）
    /// - Returns: いいね（新しい順への並べ替えは呼び出し側の責任）
    func fetchLikes(forPostIds postIds: [String]) async throws -> [Like] {
        // 空配列を `in` に渡すと Firestore がクラッシュするため、投げずに空を返す
        guard !postIds.isEmpty else { return [] }
        // `in` の上限は 30。呼び出し側で切っている前提だが、ここでも防御する
        let targetIds = Array(postIds.prefix(30))

        do {
            // ⚠️ `order(by:)` は付けない。等値フィルタ＋別フィールドの並び替えは複合インデックスが
            //    必要になるが、この用途（自分の直近投稿に付いたいいね）は件数が少なく、
            //    並べ替えは呼び出し側で行えば足りる。index 追加＝deploy を避けられる。
            //    ⚠️ `limit` は「非常弁」であって「正確な上位 N 件」ではない。
            //       `order(by:)` を付けていないので、上限に達した場合に切り捨てられるのは
            //       ドキュメント ID 順の後ろ側で、新しい順の上位が残る保証はない。
            //       `likes` の rules は read が `isAuthenticated()` のみで list 上限を強制しないため、
            //       人気投稿が窓に入ったときに読み取り量とメモリが青天井になるのを防ぐのが目的。
            let snapshot = try await likesCollection
                .whereField("postId", in: targetIds)
                .limit(to: Self.likesFetchLimit)
                .getDocuments()

            // 上限に張り付いた時点で「集計結果は過小」が確定する。
            // 例外にならないので、ここで痕跡を残さないと誰も気づけない。
            if snapshot.documents.count >= Self.likesFetchLimit {
                print("⚠️ fetchLikes が上限 \(Self.likesFetchLimit) 件に到達。いいね件数の集計が過小になります postIds=\(targetIds.count)件")
            }

            // ⚠️ compactMap { try? } は壊れたドキュメントを無言で落とすため使わない。
            //    パスをログに残したうえで 1 件だけスキップする（tech-spec.md の方針）。
            return snapshot.documents.compactMap { document -> Like? in
                do {
                    return try Like(from: document.data(), documentId: document.documentID)
                } catch {
                    print("❌ いいねのデコード失敗 path=\(document.reference.path) error=\(error.localizedDescription)")
                    return nil
                }
            }
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    /// 指定期間に押された「いいね」を新しい順に取得する（いいねランキングの集計用）⭐️
    ///
    /// ⚠️ インデックス: createdAt 単一フィールドの範囲＋同じフィールドの並び替えなので、
    ///    単一フィールドの自動インデックスで足りる（firestore.indexes.json の追加は不要）。
    ///    ここに `whereField("postId", ...)` などの等値フィルタを足すと複合インデックスが要るので注意。
    func fetchLikes(from start: Date, to end: Date, limit: Int) async throws -> [Like] {
        do {
            let snapshot = try await likesCollection
                .whereField("createdAt", isGreaterThanOrEqualTo: Timestamp(date: start))
                .whereField("createdAt", isLessThanOrEqualTo: Timestamp(date: end))
                .order(by: "createdAt", descending: true)
                .limit(to: limit)
                .getDocuments()

            // ⚠️ compactMap { try? } は壊れたドキュメントを無言で落とすため使わない。
            //    パスをログに残したうえで 1 件だけスキップする（tech-spec.md の方針）。
            return snapshot.documents.compactMap { document -> Like? in
                do {
                    return try Like(from: document.data(), documentId: document.documentID)
                } catch {
                    print("❌ いいねのデコード失敗 path=\(document.reference.path) error=\(error.localizedDescription)")
                    return nil
                }
            }
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    /// ブロックしているユーザーIDのリストを取得
    func fetchBlockedUserIds(userId: String) async throws -> [String] {
        do {
            let document = try await usersCollection.document(userId).getDocument()
            guard let data = document.data() else { return [] }
            return data["blockedUserIds"] as? [String] ?? []
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    // MARK: - Public Profiles

    /// 公開プロフィールを取得（機密情報を含まない）
    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        do {
            let document = try await publicProfilesCollection.document(userId).getDocument()

            // ドキュメントが存在しない、またはデータがない場合は notFound を直接 throw
            guard document.exists, let data = document.data() else {
                throw FirestoreServiceError.notFound
            }

            // ⭐️ 中の id がドキュメント ID と一致するかも確かめる（issue #133・なりすまし表示の防止）。
            //    呼び出し側は profile.id を辞書のキーにするので、ここで弾けば全画面に効く。
            //    不一致は id 欠落と同じ「壊れたデータ」扱い（下の catch で fetchFailed）にする。
            //    notFound は呼び出し側で「未作成の旧アカウント」として扱われる（users へのフォールバック等）ので使わない。
            return try PublicProfile(from: data, documentId: userId)
        } catch let error as FirestoreServiceError {
            // FirestoreServiceError（notFound 等）はそのまま re-throw（fetchFailed でラップしない）
            throw error
        } catch {
            // Firestore SDK 等の外部エラーのみ fetchFailed にラップ
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    /// 公開プロフィールのうち「本人が編集できるフィールド」だけを更新する ⭐️
    ///
    /// なぜ専用メソッドが必要か:
    /// `PublicProfile.toFirestoreData()` を丸ごと書く旧実装は、
    /// followersCount / followingCount まで**クライアントが持っている古い値**で
    /// 上書きしてしまう。カウンタは Cloud Functions（onFollowCreated /
    /// onFollowDeleted）が follows を count() して代入する真値なので、
    /// プロフィール編集のたびに 0 などへ巻き戻る事故が起きていた。
    /// updateData で対象フィールドだけを書けばこの経路は断てる
    /// （`updateNotificationPreferences` と同じ理由・同じ形）。
    ///
    /// - Note: nil のフィールドは「書き込まない」＝既存値を維持する。
    ///   従来の `setData(merge: true)` + `toFirestoreData()`（nil キーを省略）と
    ///   同じ挙動に揃えてあり、本 PR では意図的に変更していない。
    /// - Throws: 更新に失敗したときは `publicProfiles/{userId}` の存在を get で確認し、
    ///   不在なら `FirestoreServiceError.notFound`（呼び出し側が `createPublicProfile`
    ///   にフォールバックできるようにするため）、存在するなら
    ///   `FirestoreServiceError.updateFailed` を投げる。
    ///   ⚠️ updateData が返すエラーコードでは判定しない。publicProfiles の update ルールは
    ///   `resource.data.id` を参照するため、ドキュメント不在時に NOT_FOUND ではなく
    ///   PERMISSION_DENIED が返りうる。存在確認を経由することで rules の評価順序に
    ///   依存しない判定にしてある。
    func updatePublicProfileFields(userId: String, displayName: String?, photoURL: String?, bio: String?) async throws {
        // updatedAt は常に更新し、値がある項目だけを追加する
        var data: [String: Any] = ["updatedAt": Timestamp(date: Date())]

        if let displayName = displayName {
            data["displayName"] = displayName
        }
        if let photoURL = photoURL {
            data["photoURL"] = photoURL
        }
        if let bio = bio {
            data["bio"] = bio
        }

        do {
            try await publicProfilesCollection.document(userId).updateData(data)
        } catch {
            // 失敗の種類はエラーコードで推測せず、「ドキュメントが実在するか」を
            // get で確かめてから決める。publicProfiles の get は rules が
            // isAuthenticated() しか要求しないため決定的に判定でき、
            // update 側の rules（`resource.data.id` を参照する＝不在時に
            // NOT_FOUND ではなく PERMISSION_DENIED になりうる）の評価順序に左右されない。
            let snapshot = try? await publicProfilesCollection.document(userId).getDocument()
            if let snapshot = snapshot, !snapshot.exists {
                // ドキュメント未作成（マイグレーション未実施）のユーザー。
                // 呼び出し側が createPublicProfile へ切り替えられるよう notFound で伝える。
                throw FirestoreServiceError.notFound
            }
            // 存在する場合、および存在確認そのものが失敗した場合（snapshot が nil）は
            // 「不在」と断定できないので、元のエラーを updateFailed として伝える。
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    // MARK: - Recommended Skies（私のおすすめの空）⭐️

    /// 公開プロフィールが無いことをトランザクションの外へ伝えるためのエラードメイン
    private static let recommendedSkiesProfileMissingDomain = "FirestoreService.recommendedSkies.profileMissing"

    /// おすすめの空に投稿を追加する ⭐️
    ///
    /// ⚠️ トランザクションにしているのは「上限 3 枚」と「重複なし」を守るため。
    ///    別の端末で同時に追加されても、読み取った最新の一覧に対して判定する。
    ///    （`FieldValue.arrayUnion` だと上限を知らないので 4 枚目が入りうる。
    ///      rules でも size() <= 3 を検査しているが、そちらは拒否されるだけで理由が伝わらない。）
    func addRecommendedPost(postId: String, userId: String) async throws -> RecommendedSkies.AddResult {
        let profileRef = publicProfilesCollection.document(userId)

        do {
            let result = try await db.runTransaction { transaction, errorPointer in
                let snapshot: DocumentSnapshot
                do {
                    snapshot = try transaction.getDocument(profileRef)
                } catch let fetchError as NSError {
                    errorPointer?.pointee = fetchError
                    return nil
                }

                guard snapshot.exists else {
                    // 公開プロフィール未作成（移行未実施の旧アカウント）→ 呼び出し側で作ってから再試行する
                    errorPointer?.pointee = NSError(
                        domain: Self.recommendedSkiesProfileMissingDomain,
                        code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "公開プロフィールがありません"]
                    )
                    return nil
                }

                let current = snapshot.data()?["recommendedPostIds"] as? [String] ?? []
                let addResult = RecommendedSkies.adding(postId, to: current)
                // 追加できたときだけ書く（既に入っている・満杯のときは何も書かない）
                if case let .added(postIds) = addResult {
                    transaction.updateData([
                        "recommendedPostIds": postIds,
                        "updatedAt": Timestamp(date: Date())
                    ], forDocument: profileRef)
                }
                return addResult
            }

            guard let addResult = result as? RecommendedSkies.AddResult else {
                throw FirestoreServiceError.updateFailed(NSError(domain: "FirestoreService", code: -1, userInfo: [NSLocalizedDescriptionKey: "トランザクション結果の取得に失敗"]))
            }
            return addResult
        } catch let error as FirestoreServiceError {
            throw error
        } catch {
            if (error as NSError).domain == Self.recommendedSkiesProfileMissingDomain {
                throw FirestoreServiceError.notFound
            }
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    /// おすすめの空から投稿を外す ⭐️
    func removeRecommendedPosts(_ postIds: Set<String>, userId: String) async throws -> [String] {
        try await updateRecommendedPostIdsInTransaction(userId: userId) { current in
            RecommendedSkies.removing(postIds, from: current)
        }
    }

    /// おすすめの空の中で投稿を前後に動かす ⭐️
    func moveRecommendedPost(_ postId: String, by offset: Int, userId: String) async throws -> [String] {
        try await updateRecommendedPostIdsInTransaction(userId: userId) { current in
            RecommendedSkies.moving(postId, by: offset, in: current)
        }
    }

    /// おすすめの空の一覧を「サーバーの最新値に対して」書き換える共通処理 ⭐️
    ///
    /// ⚠️ 手元の一覧から配列を作って丸ごと上書きすると、別の端末で追加された空を消してしまう
    ///    （lost update）。追加（addRecommendedPost）と同じくトランザクションで最新値を読んでから書く。
    /// - updateData で recommendedPostIds（と updatedAt）だけを書く。PublicProfile 全体を書かないのは、
    ///   followersCount 等を古い値で巻き戻さないため（`updatePublicProfileFields` と同じ理由）。
    /// - 公開プロフィールが無い（旧アカウント）なら、外す／動かす対象も無いので何も書かず空配列を返す。
    /// - Returns: 書き換え後の一覧
    private func updateRecommendedPostIdsInTransaction(
        userId: String,
        transform: @escaping ([String]) -> [String]
    ) async throws -> [String] {
        let profileRef = publicProfilesCollection.document(userId)

        do {
            let result = try await db.runTransaction { transaction, errorPointer in
                let snapshot: DocumentSnapshot
                do {
                    snapshot = try transaction.getDocument(profileRef)
                } catch let fetchError as NSError {
                    errorPointer?.pointee = fetchError
                    return nil
                }

                guard snapshot.exists else { return [String]() }

                let current = RecommendedSkies.normalized(snapshot.data()?["recommendedPostIds"] as? [String] ?? [])
                let updated = transform(current)
                // 変化が無ければ書かない（updatedAt だけ進めて無駄な更新トリガーを起こさない）
                if updated != current {
                    transaction.updateData([
                        "recommendedPostIds": updated,
                        "updatedAt": Timestamp(date: Date())
                    ], forDocument: profileRef)
                }
                return updated
            }

            guard let postIds = result as? [String] else {
                throw FirestoreServiceError.updateFailed(NSError(domain: "FirestoreService", code: -1, userInfo: [NSLocalizedDescriptionKey: "トランザクション結果の取得に失敗"]))
            }
            return postIds
        } catch let error as FirestoreServiceError {
            throw error
        } catch {
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    /// 公開プロフィールが無いときだけ作成する ⭐️
    ///
    /// ⚠️ `createPublicProfile` は setData の丸ごと上書きなので、公開プロフィール未作成の旧アカウントで
    ///    2 台が同時に最初のおすすめを追加すると、先に作成・追加した端末の recommendedPostIds を
    ///    後の端末の作成処理が消してしまう。「無ければ作る」をトランザクションで原子的に行う。
    func createPublicProfileIfMissing(from user: User) async throws {
        let docRef = publicProfilesCollection.document(user.id)
        do {
            _ = try await db.runTransaction { transaction, errorPointer in
                do {
                    let snapshot = try transaction.getDocument(docRef)
                    if !snapshot.exists {
                        transaction.setData(PublicProfile(from: user).toFirestoreData(), forDocument: docRef)
                    }
                } catch let fetchError as NSError {
                    errorPointer?.pointee = fetchError
                }
                return nil
            }
        } catch {
            throw FirestoreServiceError.createFailed(error)
        }
    }

    /// Userモデルから公開プロフィールを作成
    /// ユーザー作成時に自動的に呼び出される
    func createPublicProfile(from user: User) async throws {
        do {
            let publicProfile = PublicProfile(from: user)
            let docRef = publicProfilesCollection.document(publicProfile.id)
            try await docRef.setData(publicProfile.toFirestoreData())
        } catch {
            throw FirestoreServiceError.createFailed(error)
        }
    }

    // MARK: - Likes

    /// いいねの追加/解除を明示指定で書き込む ⭐️
    ///
    /// ⚠️ サーバー側トグル（あれば消す・なければ作る）にしないのは意図的（issue #145 ②）。
    ///    ギャラリー系の画面ではいいね済みの投稿が空のハートで出ることがあり、
    ///    トグルだとそこで押した「いいねする」がサーバーでは「外す」になってしまう。
    ///    `setFavorite` と同じく、押した結果こうなってほしい状態へ収束させる（冪等）。
    /// ⚠️ 戻り値の likesCount のためにトランザクションで投稿も読むので、posts の読み取り権限（公開範囲）が要る。
    ///    読めない投稿（フォローを外した後のフォロワー限定投稿・非公開にされた投稿）では失敗し、LikeManager が元に戻す。
    ///    投稿を読まずに書いていた旧 toggleLike とは、この点だけ挙動が違う（docs/firestore-schema.md の書き込み契約）。
    /// - Parameters:
    ///   - postId: 対象の投稿ID
    ///   - userId: 操作するユーザーID
    ///   - isLiked: true で追加、false で解除
    /// - Returns: 書き込み後の投稿の likesCount（サーバー値）。既にその状態なら書かずに今の値を返す
    func setLike(postId: String, userId: String, isLiked: Bool) async throws -> Int {
        let likeDocId = Like.documentId(userId: userId, postId: postId)
        let likeRef = likesCollection.document(likeDocId)
        let postRef = postsCollection.document(postId)

        do {
            let result = try await db.runTransaction { transaction, errorPointer in
                // ⚠️ トランザクションは「読み取りをすべて済ませてから書く」決まり。
                //    いいねの有無と、戻り値に使う今の likesCount を先に読む。
                let likeDoc: DocumentSnapshot
                let postDoc: DocumentSnapshot
                do {
                    likeDoc = try transaction.getDocument(likeRef)
                    postDoc = try transaction.getDocument(postRef)
                } catch let fetchError as NSError {
                    errorPointer?.pointee = fetchError
                    return nil
                }

                // Post の読み込み（`documentData["likesCount"] as? Int ?? 0`）と同じ解釈にそろえる
                let currentCount = postDoc.data()?["likesCount"] as? Int ?? 0

                if isLiked, !likeDoc.exists {
                    // いいね追加
                    let like = Like(userId: userId, postId: postId)
                    transaction.setData(like.toFirestoreData(), forDocument: likeRef)
                    transaction.updateData(["likesCount": FieldValue.increment(Int64(1))], forDocument: postRef)
                    return NSNumber(value: currentCount + 1)
                } else if !isLiked, likeDoc.exists {
                    // いいね削除
                    transaction.deleteDocument(likeRef)
                    transaction.updateData(["likesCount": FieldValue.increment(Int64(-1))], forDocument: postRef)
                    return NSNumber(value: currentCount - 1)
                } else {
                    // 既に望む状態：何も書かない（数も動かさない）
                    return NSNumber(value: currentCount)
                }
            }

            guard let count = (result as? NSNumber)?.intValue else {
                throw FirestoreServiceError.updateFailed(NSError(domain: "FirestoreService", code: -1, userInfo: [NSLocalizedDescriptionKey: "トランザクション結果の取得に失敗"]))
            }
            return count
        } catch {
            throw FirestoreServiceError.updateFailed(error)
        }
    }

    /// 特定の投稿に対するいいね状態を確認
    func checkLikeStatus(postId: String, userId: String) async throws -> Bool {
        let likeDocId = Like.documentId(userId: userId, postId: postId)
        do {
            let document = try await likesCollection.document(likeDocId).getDocument()
            return document.exists
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    /// 複数投稿のいいね状態を一括確認
    /// - Returns: いいね済みの投稿IDセット
    func batchCheckLikeStatus(postIds: [String], userId: String) async throws -> Set<String> {
        guard !postIds.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            for postId in postIds {
                group.addTask { [self] in
                    let likeDocId = Like.documentId(userId: userId, postId: postId)
                    let document = try await likesCollection.document(likeDocId).getDocument()
                    return (postId, document.exists)
                }
            }

            var likedIds: Set<String> = []
            for try await (postId, exists) in group {
                if exists {
                    likedIds.insert(postId)
                }
            }
            return likedIds
        }
    }

    // MARK: - Favorites（私のお気に入りの空）⭐️

    /// お気に入りの追加/解除を明示指定で書き込む
    ///
    /// ⚠️ サーバー側トグルにしないのは意図的（いいねの `setLike` も同じ方式）。
    ///    ローカル状態が古くても「押した結果こうなってほしい」状態へ収束する（冪等）。
    /// - Parameters:
    ///   - postId: 対象の投稿ID（そのままドキュメントIDになる）
    ///   - userId: 操作するユーザーID（＝サブコレクションの所有者）
    ///   - isFavorited: true で追加、false で解除
    func setFavorite(postId: String, userId: String, isFavorited: Bool) async throws {
        let document = favoritesCollection(userId: userId).document(postId)

        do {
            if isFavorited {
                try await document.setData(Favorite(postId: postId).toFirestoreData())
            } else {
                try await document.delete()
            }
        } catch {
            // 追加は「更新失敗」、解除は「削除失敗」として区別できるように包む。
            throw isFavorited
                ? FirestoreServiceError.updateFailed(error)
                : FirestoreServiceError.deleteFailed(error)
        }
    }

    /// 複数投稿のお気に入り状態を一括確認
    /// - Returns: お気に入り済みの投稿IDセット
    func batchCheckFavoriteStatus(postIds: [String], userId: String) async throws -> Set<String> {
        guard !postIds.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            for postId in postIds {
                group.addTask { [self] in
                    // ドキュメントID = postId なので、存在確認だけで済む。
                    let document = try await favoritesCollection(userId: userId).document(postId).getDocument()
                    return (postId, document.exists)
                }
            }

            var favoritedIds: Set<String> = []
            for try await (postId, exists) in group {
                if exists {
                    favoritedIds.insert(postId)
                }
            }
            return favoritedIds
        }
    }

    /// 自分のお気に入りを新しい順に1ページ取得する
    /// - Parameters:
    ///   - userId: 所有者のユーザーID
    ///   - limit: 1ページの件数
    ///   - after: 前ページ末尾の createdAt（nil で先頭ページ）。
    ///            `DocumentSnapshot` ではなく Date をカーソルにすることで、
    ///            protocol に Firestore 型を出さずテストでモックできる。
    /// - Returns: お気に入りの配列（createdAt 降順）
    func fetchFavorites(userId: String, limit: Int, after: Date?) async throws -> [Favorite] {
        do {
            var query: Query = favoritesCollection(userId: userId)
                .order(by: "createdAt", descending: true)

            if let after {
                query = query.start(after: [Timestamp(date: after)])
            }

            let snapshot = try await query.limit(to: limit).getDocuments()

            // ⚠️ compactMap { try? ... } は壊れたドキュメントを無言で落とすため禁止（tech-spec）。
            //    失敗した1件はパスをログに残してスキップし、ページ全体は巻き込まない。
            return snapshot.documents.compactMap { document in
                do {
                    return try Favorite(from: document.data(), documentId: document.documentID)
                } catch {
                    print("❌ お気に入りデコード失敗 path=\(document.reference.path) error=\(error.localizedDescription)")
                    return nil
                }
            }
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }


    // MARK: - Comments

    /// コメント一覧を取得（ページネーション対応）
    func fetchComments(postId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> (comments: [Comment], lastDocument: DocumentSnapshot?) {
        do {
            var query: Query = commentsCollection
                .whereField("postId", isEqualTo: postId)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)

            if let lastDocument {
                query = query.start(afterDocument: lastDocument)
            }

            let snapshot = try await query.getDocuments()

            let comments: [Comment] = try snapshot.documents.map { document in
                try Comment(from: document.data(), documentId: document.documentID)
            }

            return (comments: comments, lastDocument: snapshot.documents.last)
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    /// コメントを追加
    /// - Parameters:
    ///   - authorName: 投稿者の表示名（投稿時点の値を非正規化して保存。取得できなければ nil）
    ///   - authorPhotoURL: 投稿者のプロフィール画像URL（同上）
    func addComment(postId: String, userId: String, content: String, authorName: String?, authorPhotoURL: String?) async throws -> Comment {
        let comment = Comment(
            userId: userId,
            postId: postId,
            content: content,
            authorName: authorName,
            authorPhotoURL: authorPhotoURL
        )

        do {
            let batch = db.batch()

            // コメントドキュメント作成
            let commentRef = commentsCollection.document(comment.id)
            batch.setData(comment.toFirestoreData(), forDocument: commentRef)

            // 投稿の commentsCount をインクリメント
            let postRef = postsCollection.document(postId)
            batch.updateData(["commentsCount": FieldValue.increment(Int64(1))], forDocument: postRef)

            try await batch.commit()
            return comment
        } catch {
            throw FirestoreServiceError.createFailed(error)
        }
    }

    /// コメントを削除
    func deleteComment(commentId: String, postId: String, userId _: String) async throws {
        do {
            let batch = db.batch()

            // コメントドキュメント削除
            let commentRef = commentsCollection.document(commentId)
            batch.deleteDocument(commentRef)

            // 投稿の commentsCount をデクリメント
            let postRef = postsCollection.document(postId)
            batch.updateData(["commentsCount": FieldValue.increment(Int64(-1))], forDocument: postRef)

            try await batch.commit()
        } catch {
            throw FirestoreServiceError.deleteFailed(error)
        }
    }
}

// MARK: - FirestoreServiceError

enum FirestoreServiceError: LocalizedError {
    case notFound
    case createFailed(Error)
    case fetchFailed(Error)
    case updateFailed(Error)
    case deleteFailed(Error)
    case searchFailed(Error)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .notFound:
            "データが見つかりませんでした"
        case let .createFailed(error):
            "データの作成に失敗しました: \(error.localizedDescription)"
        case let .fetchFailed(error):
            "データの取得に失敗しました: \(error.localizedDescription)"
        case let .updateFailed(error):
            "データの更新に失敗しました: \(error.localizedDescription)"
        case let .deleteFailed(error):
            "データの削除に失敗しました: \(error.localizedDescription)"
        case let .searchFailed(error):
            "検索に失敗しました: \(error.localizedDescription)"
        case .unauthorized:
            "この操作を行う権限がありません"
        }
    }
}
