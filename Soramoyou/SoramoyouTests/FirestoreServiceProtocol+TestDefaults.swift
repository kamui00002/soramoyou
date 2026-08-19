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

import FirebaseFirestore
import Foundation
@testable import Soramoyou

extension FirestoreServiceProtocol {
    // MARK: - Posts

    func createPost(_: Post) async throws -> Post {
        fatalError("MockFirestoreService.createPost は未実装です")
    }

    func updatePost(_: Post) async throws -> Post {
        fatalError("MockFirestoreService.updatePost は未実装です")
    }

    func fetchPosts(limit _: Int, lastDocument _: DocumentSnapshot?) async throws -> [Post] {
        fatalError("MockFirestoreService.fetchPosts は未実装です")
    }

    func fetchPostsWithSnapshot(
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        fatalError("MockFirestoreService.fetchPostsWithSnapshot は未実装です")
    }

    func fetchPostsWithSnapshot(
        timeOfDay _: TimeOfDay?,
        skyType _: SkyType?,
        sortField _: String,
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        fatalError("MockFirestoreService.fetchPostsWithSnapshot(絞り込み版) は未実装です")
    }

    func fetchPost(postId _: String) async throws -> Post {
        fatalError("MockFirestoreService.fetchPost は未実装です")
    }

    func deletePost(postId _: String, userId _: String) async throws {
        fatalError("MockFirestoreService.deletePost は未実装です")
    }

    func fetchUserPosts(
        userId _: String,
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> [Post] {
        fatalError("MockFirestoreService.fetchUserPosts は未実装です")
    }

    // MARK: - Drafts

    func saveDraft(_: Draft) async throws -> Draft {
        fatalError("MockFirestoreService.saveDraft は未実装です")
    }

    func fetchDrafts(userId _: String) async throws -> [Draft] {
        fatalError("MockFirestoreService.fetchDrafts は未実装です")
    }

    func loadDraft(draftId _: String) async throws -> Draft {
        fatalError("MockFirestoreService.loadDraft は未実装です")
    }

    func deleteDraft(draftId _: String) async throws {
        fatalError("MockFirestoreService.deleteDraft は未実装です")
    }

    // MARK: - Users

    func fetchUser(userId _: String) async throws -> User {
        fatalError("MockFirestoreService.fetchUser は未実装です")
    }

    func updateUser(_: User) async throws -> User {
        fatalError("MockFirestoreService.updateUser は未実装です")
    }

    func updateEditTools(userId _: String, tools _: [EditTool], order _: [String]) async throws {
        fatalError("MockFirestoreService.updateEditTools は未実装です")
    }

    func syncPostsCount(userId _: String, count _: Int) async throws {
        fatalError("MockFirestoreService.syncPostsCount は未実装です")
    }

    func followTag(userId _: String, tag _: String) async throws {
        fatalError("MockFirestoreService.followTag は未実装です")
    }

    func unfollowTag(userId _: String, tag _: String) async throws {
        fatalError("MockFirestoreService.unfollowTag は未実装です")
    }

    func updateNotificationPreferences(userId _: String, notifyReactions _: Bool, notifyNewPostsFromFollowing _: Bool, notifyNewPostsFromEveryone _: Bool) async throws {
        fatalError("MockFirestoreService.updateNotificationPreferences は未実装です")
    }

    // MARK: - Public Profiles

    func fetchPublicProfile(userId _: String) async throws -> PublicProfile {
        fatalError("MockFirestoreService.fetchPublicProfile は未実装です")
    }

    func updatePublicProfile(_: PublicProfile) async throws {
        fatalError("MockFirestoreService.updatePublicProfile は未実装です")
    }

    func createPublicProfile(from _: User) async throws {
        fatalError("MockFirestoreService.createPublicProfile は未実装です")
    }

    // MARK: - Account

    func deleteUserData(userId _: String) async throws {
        fatalError("MockFirestoreService.deleteUserData は未実装です")
    }

    // MARK: - Report / Block

    func reportPost(
        postId _: String,
        reporterId _: String,
        reportedUserId _: String,
        reason _: String
    ) async throws {
        fatalError("MockFirestoreService.reportPost は未実装です")
    }

    func blockUser(userId _: String, blockedUserId _: String) async throws {
        fatalError("MockFirestoreService.blockUser は未実装です")
    }

    func unblockUser(userId _: String, blockedUserId _: String) async throws {
        fatalError("MockFirestoreService.unblockUser は未実装です")
    }

    func fetchBlockedUserIds(userId _: String) async throws -> [String] {
        fatalError("MockFirestoreService.fetchBlockedUserIds は未実装です")
    }

    // MARK: - Search

    func searchByHashtag(_: String) async throws -> [Post] {
        fatalError("MockFirestoreService.searchByHashtag は未実装です")
    }

    func searchByColor(_: String, threshold _: Double?) async throws -> [Post] {
        fatalError("MockFirestoreService.searchByColor は未実装です")
    }

    func searchByTimeOfDay(_: TimeOfDay) async throws -> [Post] {
        fatalError("MockFirestoreService.searchByTimeOfDay は未実装です")
    }

    func searchBySkyType(_: SkyType) async throws -> [Post] {
        fatalError("MockFirestoreService.searchBySkyType は未実装です")
    }

    func searchPosts(
        hashtag _: String?,
        color _: String?,
        timeOfDay _: TimeOfDay?,
        skyType _: SkyType?,
        colorThreshold _: Double?,
        limit _: Int
    ) async throws -> [Post] {
        fatalError("MockFirestoreService.searchPosts は未実装です")
    }

    // MARK: - Likes

    func toggleLike(postId _: String, userId _: String) async throws -> Bool {
        fatalError("MockFirestoreService.toggleLike は未実装です")
    }

    func checkLikeStatus(postId _: String, userId _: String) async throws -> Bool {
        fatalError("MockFirestoreService.checkLikeStatus は未実装です")
    }

    func batchCheckLikeStatus(postIds _: [String], userId _: String) async throws -> Set<String> {
        fatalError("MockFirestoreService.batchCheckLikeStatus は未実装です")
    }

    // MARK: - Comments

    func fetchComments(
        postId _: String,
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> (comments: [Comment], lastDocument: DocumentSnapshot?) {
        fatalError("MockFirestoreService.fetchComments は未実装です")
    }

    func addComment(postId _: String, userId _: String, content _: String, authorName _: String?, authorPhotoURL _: String?) async throws -> Comment {
        fatalError("MockFirestoreService.addComment は未実装です")
    }

    func deleteComment(commentId _: String, postId _: String, userId _: String) async throws {
        fatalError("MockFirestoreService.deleteComment は未実装です")
    }

    func submitFeedback(_: Feedback) async throws {
        fatalError("MockFirestoreService.submitFeedback は未実装です")
    }
}
