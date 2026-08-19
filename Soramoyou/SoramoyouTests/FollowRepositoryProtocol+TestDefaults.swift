//
//  FollowRepositoryProtocol+TestDefaults.swift
//  SoramoyouTests
//
//  ⭐️ テスト target 専用: FollowRepositoryProtocol のメソッド追加時に
//  既存モック（MockFollowRepository 等）が一斉にコンパイルエラーを起こすのを
//  防ぐためのデフォルト実装（FirestoreServiceProtocol+TestDefaults と同方針）。
//
//  各モックはテストで必要なメソッドだけ上書きすればよく、
//  未使用メソッドは `fatalError("unimplemented")` のデフォルトで満たす。
//

import FirebaseFirestore
import Foundation
@testable import Soramoyou

extension FollowRepositoryProtocol {
    func fetchFollowers(
        of _: String,
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        fatalError("MockFollowRepository.fetchFollowers は未実装です")
    }

    func fetchFollowing(
        of _: String,
        limit _: Int,
        lastDocument _: DocumentSnapshot?
    ) async throws -> (follows: [Follow], lastDocument: DocumentSnapshot?) {
        fatalError("MockFollowRepository.fetchFollowing は未実装です")
    }

    func removeFollower(_: String, from _: String) async throws {
        fatalError("MockFollowRepository.removeFollower は未実装です")
    }
}
