//
//  FirestoreServiceProtocol+TestDefaults.swift
//  SoramoyouTests
//
//  ⭐️ テスト target 専用: FirestoreServiceProtocol のメソッド追加時に
//  既存モック 5 種（MockFirestoreService, *Gallery, *Home, *Profile, *Search）が
//  一斉にコンパイルエラーを起こすのを防ぐためのデフォルト実装。
//
//  方針:
//  - 各モックが個別にテストで必要とするメソッドだけ上書きすればよい構成とし、
//    未使用メソッドは `fatalError("unimplemented")` を返すデフォルトで満たす。
//  - production ターゲットには含めない（テストのみで有効）ので、
//    本番コードは従来通り MockFirestoreService 側で完全実装する必要がない。
//  - `fatalError` は想定外パスが呼ばれた場合のみ発火するため、
//    テストが利用するメソッドを MockFirestoreService が実装していれば何も起きない。
//

import Foundation
import FirebaseFirestore
@testable import Soramoyou

extension FirestoreServiceProtocol {

    // MARK: - Posts

    func createPost(_ post: Post) async throws -> Post {
        fatalError("MockFirestoreService.createPost は未実装です")
    }

    func updatePost(_ post: Post) async throws -> Post {
        fatalError("MockFirestoreService.updatePost は未実装です")
    }

    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] {
        fatalError("MockFirestoreService.fetchPosts は未実装です")
    }

    func fetchPostsWithSnapshot(
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        fatalError("MockFirestoreService.fetchPostsWithSnapshot は未実装です")
    }

    func fetchPost(postId: String) async throws -> Post {
        fatalError("MockFirestoreService.fetchPost は未実装です")
    }

    func deletePost(postId: String, userId: String) async throws {
        fatalError("MockFirestoreService.deletePost は未実装です")
    }

    func fetchUserPosts(
        userId: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> [Post] {
        fatalError("MockFirestoreService.fetchUserPosts は未実装です")
    }

    // MARK: - Drafts

    func saveDraft(_ draft: Draft) async throws -> Draft {
        fatalError("MockFirestoreService.saveDraft は未実装です")
    }

    func fetchDrafts(userId: String) async throws -> [Draft] {
        fatalError("MockFirestoreService.fetchDrafts は未実装です")
    }

    func loadDraft(draftId: String) async throws -> Draft {
        fatalError("MockFirestoreService.loadDraft は未実装です")
    }

    func deleteDraft(draftId: String) async throws {
        fatalError("MockFirestoreService.deleteDraft は未実装です")
    }

    // MARK: - Users

    func fetchUser(userId: String) async throws -> User {
        fatalError("MockFirestoreService.fetchUser は未実装です")
    }

    func updateUser(_ user: User) async throws -> User {
        fatalError("MockFirestoreService.updateUser は未実装です")
    }

    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws {
        fatalError("MockFirestoreService.updateEditTools は未実装です")
    }

    func syncPostsCount(userId: String, count: Int) async throws {
        fatalError("MockFirestoreService.syncPostsCount は未実装です")
    }

    func updateNotificationPreferences(userId: String, notifyReactions: Bool, notifyNewPostsFromFollowing: Bool, notifyNewPostsFromEveryone: Bool) async throws {
        fatalError("MockFirestoreService.updateNotificationPreferences は未実装です")
    }

    // MARK: - Public Profiles

    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        fatalError("MockFirestoreService.fetchPublicProfile は未実装です")
    }

    func updatePublicProfile(_ profile: PublicProfile) async throws {
        fatalError("MockFirestoreService.updatePublicProfile は未実装です")
    }

    func createPublicProfile(from user: User) async throws {
        fatalError("MockFirestoreService.createPublicProfile は未実装です")
    }

    // MARK: - Account

    func deleteUserData(userId: String) async throws {
        fatalError("MockFirestoreService.deleteUserData は未実装です")
    }

    // MARK: - Report / Block

    func reportPost(
        postId: String,
        reporterId: String,
        reportedUserId: String,
        reason: String
    ) async throws {
        fatalError("MockFirestoreService.reportPost は未実装です")
    }

    func blockUser(userId: String, blockedUserId: String) async throws {
        fatalError("MockFirestoreService.blockUser は未実装です")
    }

    func unblockUser(userId: String, blockedUserId: String) async throws {
        fatalError("MockFirestoreService.unblockUser は未実装です")
    }

    func fetchBlockedUserIds(userId: String) async throws -> [String] {
        fatalError("MockFirestoreService.fetchBlockedUserIds は未実装です")
    }

    // MARK: - Search

    func searchByHashtag(_ hashtag: String) async throws -> [Post] {
        fatalError("MockFirestoreService.searchByHashtag は未実装です")
    }

    func searchByColor(_ color: String, threshold: Double?) async throws -> [Post] {
        fatalError("MockFirestoreService.searchByColor は未実装です")
    }

    func searchByTimeOfDay(_ timeOfDay: TimeOfDay) async throws -> [Post] {
        fatalError("MockFirestoreService.searchByTimeOfDay は未実装です")
    }

    func searchBySkyType(_ skyType: SkyType) async throws -> [Post] {
        fatalError("MockFirestoreService.searchBySkyType は未実装です")
    }

    func searchPosts(
        hashtag: String?,
        color: String?,
        timeOfDay: TimeOfDay?,
        skyType: SkyType?,
        colorThreshold: Double?,
        limit: Int
    ) async throws -> [Post] {
        fatalError("MockFirestoreService.searchPosts は未実装です")
    }

    // MARK: - Likes

    func toggleLike(postId: String, userId: String) async throws -> Bool {
        fatalError("MockFirestoreService.toggleLike は未実装です")
    }

    func checkLikeStatus(postId: String, userId: String) async throws -> Bool {
        fatalError("MockFirestoreService.checkLikeStatus は未実装です")
    }

    func batchCheckLikeStatus(postIds: [String], userId: String) async throws -> Set<String> {
        fatalError("MockFirestoreService.batchCheckLikeStatus は未実装です")
    }

    // MARK: - Comments

    func fetchComments(
        postId: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (comments: [Comment], lastDocument: DocumentSnapshot?) {
        fatalError("MockFirestoreService.fetchComments は未実装です")
    }

    func addComment(postId: String, userId: String, content: String, authorName: String?, authorPhotoURL: String?) async throws -> Comment {
        fatalError("MockFirestoreService.addComment は未実装です")
    }

    func deleteComment(commentId: String, postId: String, userId: String) async throws {
        fatalError("MockFirestoreService.deleteComment は未実装です")
    }

    func submitFeedback(_ feedback: Feedback) async throws {
        fatalError("MockFirestoreService.submitFeedback は未実装です")
    }
}
