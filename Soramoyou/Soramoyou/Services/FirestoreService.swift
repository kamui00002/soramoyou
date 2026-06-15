//
//  FirestoreService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import FirebaseFirestore

protocol FirestoreServiceProtocol {
    // Posts
    func createPost(_ post: Post) async throws -> Post
    /// 既存投稿を上書き更新する（再編集）。likesCount/commentsCount/createdAt/userId は保持して呼ぶこと
    /// （Firestore ルール isValidPostUpdate がカウント不変を要求するため）。postsCount は加算しない。
    func updatePost(_ post: Post) async throws -> Post
    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post]
    func fetchPostsWithSnapshot(limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?)
    func fetchPost(postId: String) async throws -> Post
    func deletePost(postId: String, userId: String) async throws
    func fetchUserPosts(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post]
    
    // Drafts
    func saveDraft(_ draft: Draft) async throws -> Draft
    func fetchDrafts(userId: String) async throws -> [Draft]
    func loadDraft(draftId: String) async throws -> Draft
    func deleteDraft(draftId: String) async throws
    
    // Users (機密情報含む - 所有者のみ)
    func fetchUser(userId: String) async throws -> User
    func updateUser(_ user: User) async throws -> User
    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws
    func syncPostsCount(userId: String, count: Int) async throws

    // Public Profiles (公開情報のみ - 認証済みユーザー)
    func fetchPublicProfile(userId: String) async throws -> PublicProfile
    func updatePublicProfile(_ profile: PublicProfile) async throws
    func createPublicProfile(from user: User) async throws
    
    // Account
    func deleteUserData(userId: String) async throws
    
    // Report / Block
    func reportPost(postId: String, reporterId: String, reportedUserId: String, reason: String) async throws
    func blockUser(userId: String, blockedUserId: String) async throws
    func unblockUser(userId: String, blockedUserId: String) async throws
    func fetchBlockedUserIds(userId: String) async throws -> [String]
    
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
    func toggleLike(postId: String, userId: String) async throws -> Bool
    func checkLikeStatus(postId: String, userId: String) async throws -> Bool
    func batchCheckLikeStatus(postIds: [String], userId: String) async throws -> Set<String>

    // Comments
    func fetchComments(postId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> (comments: [Comment], lastDocument: DocumentSnapshot?)
    func addComment(postId: String, userId: String, content: String, authorName: String?, authorPhotoURL: String?) async throws -> Comment
    func deleteComment(commentId: String, postId: String, userId: String) async throws
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

    private var likesCollection: CollectionReference {
        db.collection("likes")
    }

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

            // users と publicProfiles の postsCount をインクリメント
            let countIncrement: [String: Any] = ["postsCount": FieldValue.increment(Int64(1))]
            try await usersCollection.document(post.userId).updateData(countIncrement)
            // publicProfiles が存在しない場合はエラーを無視（マイグレーション未実施ユーザー対応）
            try? await publicProfilesCollection.document(post.userId).updateData(countIncrement)

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
            if let lastDocument = lastDocument {
                query = query.start(afterDocument: lastDocument)
            }
            
            let snapshot = try await query.getDocuments()
            
            return try snapshot.documents.compactMap { document in
                try Post(from: document.data())
            }
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
            if let lastDocument = lastDocument {
                query = query.start(afterDocument: lastDocument)
            }
            
            let snapshot = try await query.getDocuments()
            
            let posts = try snapshot.documents.compactMap { document in
                try Post(from: document.data())
            }
            
            // 最後のドキュメントを取得
            let lastDoc = snapshot.documents.last
            
            return (posts: posts, lastDocument: lastDoc)
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }
    
    func fetchPost(postId: String) async throws -> Post {
        do {
            let document = try await postsCollection.document(postId).getDocument()
            
            guard document.exists,
                  let data = document.data() else {
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
                  let postUserId = data["userId"] as? String else {
                throw FirestoreServiceError.notFound
            }

            // 認可チェック: 自分の投稿のみ削除可能
            guard postUserId == userId else {
                throw FirestoreServiceError.unauthorized
            }

            try await postsCollection.document(postId).delete()

            // users と publicProfiles の postsCount をデクリメント（0未満にはならない）
            let countDecrement: [String: Any] = ["postsCount": FieldValue.increment(Int64(-1))]
            try await usersCollection.document(userId).updateData(countDecrement)
            try? await publicProfilesCollection.document(userId).updateData(countDecrement)
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
            if let lastDocument = lastDocument {
                query = query.start(afterDocument: lastDocument)
            }
            
            let snapshot = try await query.getDocuments()
            
            return try snapshot.documents.compactMap { document in
                try Post(from: document.data())
            }
        } catch {
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
                  let data = document.data() else {
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
                  let data = document.data() else {
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
    
    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws {
        do {
            let docRef = usersCollection.document(userId)
            let toolsStrings = tools.map { $0.rawValue }

            // まずドキュメントの存在を確認
            let document = try await docRef.getDocument()

            if document.exists {
                // ドキュメントが存在する場合はupdateData()で更新
                try await docRef.updateData([
                    "customEditTools": toolsStrings,
                    "customEditToolsOrder": order
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
                    "customEditToolsOrder": order
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
    
    /// 投稿数カウンターをFirestoreと同期する（既存データの不整合を修正）
    func syncPostsCount(userId: String, count: Int) async throws {
        do {
            let countData: [String: Any] = ["postsCount": count]
            try await usersCollection.document(userId).updateData(countData)
            try? await publicProfilesCollection.document(userId).updateData(countData)
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
            
            return try snapshot.documents.compactMap { document in
                try Post(from: document.data())
            }
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

            var posts = try snapshot.documents.compactMap { document in
                try Post(from: document.data())
            }

            // 閾値が指定されている場合は、ColorMatchingでRGB距離フィルタリングを適用
            if let threshold = threshold {
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

            return try snapshot.documents.compactMap { document in
                try Post(from: document.data())
            }
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

            return try snapshot.documents.compactMap { document in
                try Post(from: document.data())
            }
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

            let posts = try snapshot.documents.compactMap { document in
                try Post(from: document.data())
            }

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
    
    /// ユーザーの全データを削除（投稿、下書き、ユーザードキュメント）
    func deleteUserData(userId: String) async throws {
        do {
            // 1. ユーザーの投稿を全てバッチ削除
            let postsSnapshot = try await postsCollection
                .whereField("userId", isEqualTo: userId)
                .getDocuments()

            try await batchDelete(documents: postsSnapshot.documents)

            // 2. ユーザーの下書きを全てバッチ削除
            let draftsSnapshot = try await draftsCollection
                .whereField("userId", isEqualTo: userId)
                .getDocuments()

            try await batchDelete(documents: draftsSnapshot.documents)

            // 3. ユーザードキュメントを削除
            try await usersCollection.document(userId).delete()
        } catch {
            throw FirestoreServiceError.deleteFailed(error)
        }
    }

    /// ドキュメントをバッチ削除（最大500件/バッチ）
    private func batchDelete(documents: [QueryDocumentSnapshot]) async throws {
        // Firestoreのバッチは最大500オペレーション
        let batchSize = 500
        var index = 0

        while index < documents.count {
            let batch = db.batch()
            let end = min(index + batchSize, documents.count)

            for i in index..<end {
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
                "createdAt": FieldValue.serverTimestamp()
            ]
            try await db.collection("reports").addDocument(data: reportData)
        } catch {
            throw FirestoreServiceError.createFailed(error)
        }
    }
    
    // MARK: - Block
    
    /// ユーザーをブロックする
    func blockUser(userId: String, blockedUserId: String) async throws {
        do {
            try await usersCollection.document(userId).updateData([
                "blockedUserIds": FieldValue.arrayUnion([blockedUserId])
            ])
        } catch {
            throw FirestoreServiceError.updateFailed(error)
        }
    }
    
    /// ユーザーのブロックを解除する
    func unblockUser(userId: String, blockedUserId: String) async throws {
        do {
            try await usersCollection.document(userId).updateData([
                "blockedUserIds": FieldValue.arrayRemove([blockedUserId])
            ])
        } catch {
            throw FirestoreServiceError.updateFailed(error)
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

            return try PublicProfile(from: data)
        } catch let error as FirestoreServiceError {
            // FirestoreServiceError（notFound 等）はそのまま re-throw（fetchFailed でラップしない）
            throw error
        } catch {
            // Firestore SDK 等の外部エラーのみ fetchFailed にラップ
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    /// 公開プロフィールを更新
    func updatePublicProfile(_ profile: PublicProfile) async throws {
        do {
            let docRef = publicProfilesCollection.document(profile.id)
            try await docRef.setData(profile.toFirestoreData(), merge: true)
        } catch {
            throw FirestoreServiceError.updateFailed(error)
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

    /// いいねをトグル（追加/削除）する
    /// - Returns: トグル後のいいね状態（true = いいね済み）
    func toggleLike(postId: String, userId: String) async throws -> Bool {
        let likeDocId = Like.documentId(userId: userId, postId: postId)
        let likeRef = likesCollection.document(likeDocId)
        let postRef = postsCollection.document(postId)

        do {
            let result = try await db.runTransaction { transaction, errorPointer in
                // いいねドキュメントの存在チェック
                let likeDoc: DocumentSnapshot
                do {
                    likeDoc = try transaction.getDocument(likeRef)
                } catch let fetchError as NSError {
                    errorPointer?.pointee = fetchError
                    return nil
                }

                if likeDoc.exists {
                    // いいね削除
                    transaction.deleteDocument(likeRef)
                    transaction.updateData(["likesCount": FieldValue.increment(Int64(-1))], forDocument: postRef)
                    return NSNumber(value: false)
                } else {
                    // いいね追加
                    let like = Like(userId: userId, postId: postId)
                    transaction.setData(like.toFirestoreData(), forDocument: likeRef)
                    transaction.updateData(["likesCount": FieldValue.increment(Int64(1))], forDocument: postRef)
                    return NSNumber(value: true)
                }
            }

            guard let isLiked = (result as? NSNumber)?.boolValue else {
                throw FirestoreServiceError.updateFailed(NSError(domain: "FirestoreService", code: -1, userInfo: [NSLocalizedDescriptionKey: "トランザクション結果の取得に失敗"]))
            }
            return isLiked
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
                    let document = try await self.likesCollection.document(likeDocId).getDocument()
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

    // MARK: - Comments

    /// コメント一覧を取得（ページネーション対応）
    func fetchComments(postId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> (comments: [Comment], lastDocument: DocumentSnapshot?) {
        do {
            var query: Query = commentsCollection
                .whereField("postId", isEqualTo: postId)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)

            if let lastDocument = lastDocument {
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
    func deleteComment(commentId: String, postId: String, userId: String) async throws {
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
            return "データが見つかりませんでした"
        case .createFailed(let error):
            return "データの作成に失敗しました: \(error.localizedDescription)"
        case .fetchFailed(let error):
            return "データの取得に失敗しました: \(error.localizedDescription)"
        case .updateFailed(let error):
            return "データの更新に失敗しました: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "データの削除に失敗しました: \(error.localizedDescription)"
        case .searchFailed(let error):
            return "検索に失敗しました: \(error.localizedDescription)"
        case .unauthorized:
            return "この操作を行う権限がありません"
        }
    }
}
