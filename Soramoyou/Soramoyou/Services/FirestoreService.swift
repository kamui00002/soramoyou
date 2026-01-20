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
    func deletePost(postId: String) async throws
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
    
    init(db: Firestore = Firestore.firestore()) {
        self.db = db
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
    
    func deletePost(postId: String) async throws {
        do {
            try await postsCollection.document(postId).delete()
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
            
            try await docRef.updateData([
                "customEditTools": toolsStrings,
                "customEditToolsOrder": order
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
            
            // 閾値が指定されている場合は、クライアント側でRGB距離を計算してフィルタリング
            if let threshold = threshold {
                posts = filterPostsByColorDistance(posts: posts, targetColor: color, threshold: threshold)
            }
            
            return posts
        } catch {
            throw FirestoreServiceError.searchFailed(error)
        }
    }
    
    /// RGB距離を計算して投稿をフィルタリング
    private func filterPostsByColorDistance(posts: [Post], targetColor: String, threshold: Double) -> [Post] {
        guard let targetRGB = hexToRGB(targetColor) else {
            return posts
        }
        
        return posts.filter { post in
            guard let skyColors = post.skyColors else {
                return false
            }
            
            // 投稿の色のいずれかが閾値以内の距離にあるかチェック
            return skyColors.contains { color in
                guard let colorRGB = hexToRGB(color) else {
                    return false
                }
                
                let distance = calculateRGBDistance(targetRGB, colorRGB)
                return distance <= threshold
            }
        }
    }
    
    /// 16進数カラーコードをRGBに変換
    private func hexToRGB(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        guard hexSanitized.count == 6 else {
            return nil
        }
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        return (r: r, g: g, b: b)
    }
    
    /// RGB距離を計算（ユークリッド距離）
    private func calculateRGBDistance(_ color1: (r: Double, g: Double, b: Double), _ color2: (r: Double, g: Double, b: Double)) -> Double {
        let dr = color1.r - color2.r
        let dg = color1.g - color2.g
        let db = color1.b - color2.b
        
        return sqrt(dr * dr + dg * dg + db * db)
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
    func searchPosts(
        hashtag: String? = nil,
        color: String? = nil,
        timeOfDay: TimeOfDay? = nil,
        skyType: SkyType? = nil,
        colorThreshold: Double? = nil,
        limit: Int = 50
    ) async throws -> [Post] {
        do {
            var query: Query = postsCollection
                .whereField("visibility", isEqualTo: Visibility.public.rawValue)
            
            // 条件を追加
            if let hashtag = hashtag {
                query = query.whereField("hashtags", arrayContains: hashtag)
            }
            
            if let timeOfDay = timeOfDay {
                query = query.whereField("timeOfDay", isEqualTo: timeOfDay.rawValue)
            }
            
            if let skyType = skyType {
                query = query.whereField("skyType", isEqualTo: skyType.rawValue)
            }
            
            // 色検索の場合は、まずarrayContainsで取得してからクライアント側でフィルタリング
            if let color = color {
                query = query.whereField("skyColors", arrayContains: color)
            }
            
            query = query.order(by: "createdAt", descending: true)
                .limit(to: limit)
            
            let snapshot = try await query.getDocuments()
            
            var posts = try snapshot.documents.compactMap { document in
                try Post(from: document.data())
            }
            
            // 色検索で閾値が指定されている場合は、クライアント側でフィルタリング
            if let color = color, let threshold = colorThreshold {
                posts = filterPostsByColorDistance(posts: posts, targetColor: color, threshold: threshold)
            }
            
            return posts
        } catch {
            throw FirestoreServiceError.searchFailed(error)
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
        }
    }
}
