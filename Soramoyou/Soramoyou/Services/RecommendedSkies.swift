//
//  RecommendedSkies.swift
//  Soramoyou
//
//  「私のおすすめの空」の一覧操作ルール ⭐️
//
//  プロフィールに飾る「おすすめの空」（最大 3 枚・自分／他の人の公開投稿どちらも可）は
//  `publicProfiles/{uid}.recommendedPostIds`（表示順の配列）に保存する。
//  ここには Firestore にも UI にも触らない純関数だけを置き、単体テストで挙動を固定する
//  （`RecommendedSkiesTests`）。
//
//  ⚠️ publicProfiles に置くのは「他の人がプロフィールを見たときにも読めるように」するため。
//     users/{uid} は所有者しか読めない（firestore.rules）。
//

import Foundation

enum RecommendedSkies {
    /// プロフィールに飾れる最大枚数
    ///
    /// ⚠️ firestore.rules の `recommendedPostIds.size() <= 3` と一致させること。
    static let maxCount = 3

    /// 追加しようとした結果
    enum AddResult: Equatable {
        /// 追加した（追加後の一覧）
        case added([String])
        /// もともと入っていた（一覧は変えない）
        case alreadyAdded([String])
        /// 上限に達していて追加できない（現在の一覧）
        case full([String])

        /// 結果の一覧（どの場合も「保存されているはずの一覧」）
        var postIds: [String] {
            switch self {
            case let .added(ids), let .alreadyAdded(ids), let .full(ids):
                return ids
            }
        }
    }

    /// 一覧に投稿を追加する（末尾に足す）
    ///
    /// - 既に入っていれば何もしない（二重に入れない）
    /// - 上限に達していれば追加しない
    static func adding(_ postId: String, to postIds: [String], maxCount: Int = maxCount) -> AddResult {
        let current = normalized(postIds)
        if current.contains(postId) {
            return .alreadyAdded(current)
        }
        guard current.count < maxCount else {
            return .full(current)
        }
        return .added(current + [postId])
    }

    /// 一覧から投稿を外す（複数まとめて外せる＝表示できなくなった空の整理にも使う）
    static func removing(_ postIdsToRemove: Set<String>, from postIds: [String]) -> [String] {
        normalized(postIds).filter { !postIdsToRemove.contains($0) }
    }

    /// 一覧の中で投稿を前後に動かす（offset: -1 で前へ、+1 で後ろへ）
    ///
    /// 端を超える移動や、一覧に無い投稿の指定は何もしない（一覧をそのまま返す）。
    static func moving(_ postId: String, by offset: Int, in postIds: [String]) -> [String] {
        var current = normalized(postIds)
        guard let index = current.firstIndex(of: postId) else { return current }
        let destination = index + offset
        guard destination >= 0, destination < current.count, destination != index else { return current }
        current.swapAt(index, destination)
        return current
    }

    /// 保存されている一覧を正規化する（重複を除き、先に出てきた順を保つ）
    ///
    /// 古いクライアントや手作業のデータで重複が混ざっても、表示と操作が壊れないようにする。
    static func normalized(_ postIds: [String]) -> [String] {
        var seen = Set<String>()
        return postIds.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
