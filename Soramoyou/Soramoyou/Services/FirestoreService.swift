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
    
    // Users
    func fetchUser(userId: String) async throws -> User
    func updateUser(_ user: User) async throws -> User
    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws
    
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
            
            // 作成された投稿を返す（IDは既に設定されている）
            return post
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
