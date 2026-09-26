//
//  RecommendedSkiesViewModel.swift
//  Soramoyou
//
//  プロフィールの「おすすめの空」欄に並べる投稿を解決する ViewModel ⭐️
//
//  postId の一覧（publicProfiles/{uid}.recommendedPostIds）→ 1 件ずつ fetchPost で投稿に解決する。
//  ⚠️ `documentID in [...]` の一括取得にしないのは、posts の read rule が visibility 依存で、
//     1 件でも読めない投稿が混ざるとクエリ全体が permission denied になるため（お気に入りと同じ理由）。
//
//  - 表示するのは「公開」投稿だけ（誰が見ても同じ欄にするため）。
//  - 他の人のプロフィールでは、閲覧者がブロックしている人の投稿を出さない（ランキングと同じ扱い）。
//  - 削除済み・非公開化などで出せない投稿は `unavailablePostIds` に集め、持ち主には整理を促す。
//  - 他の人の投稿には投稿者名を添える（おすすめした空のクレジット表示）。
//

import Foundation

@MainActor
final class RecommendedSkiesViewModel: ObservableObject {
    /// 欄に並べる 1 件
    struct Item: Identifiable {
        let post: Post
        /// 投稿者名（プロフィールの持ち主以外の投稿のときだけ。取れなければ nil）
        let authorName: String?

        var id: String { post.id }
    }

    /// 表示する投稿（一覧の順）
    @Published private(set) var items: [Item] = []
    /// もう表示できない投稿（削除済み・非公開化・公開範囲の変更）
    @Published private(set) var unavailablePostIds: [String] = []
    /// 初回の読み込み中か
    @Published private(set) var isLoading = false

    /// 解決済みの投稿（postId → 結果）。並べ替え・外すたびに取り直さないためのキャッシュ
    private var resolved: [String: Resolution] = [:]
    /// 読み込みの世代（古い読み込み結果で新しい表示を上書きしないため）
    private var generation = 0
    /// 閲覧者がブロックしている人（この人たちの投稿は欄に出さない）
    private var blockedUserIds: Set<String> = []

    private let firestoreService: FirestoreServiceProtocol

    /// 1 件の解決結果
    private enum Resolution {
        case item(Item)
        case unavailable
    }

    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }

    /// 一覧を読み込む
    /// - Parameters:
    ///   - postIds: おすすめの空の postId（表示順）
    ///   - ownerId: プロフィールの持ち主（この人の投稿には投稿者名を付けない）
    ///   - viewerId: 閲覧者（他の人のプロフィールを見るとき。この人のブロック相手の投稿を出さない）
    ///   - force: true ならキャッシュを捨てて取り直す（引っ張って更新）
    func load(postIds: [String], ownerId: String, viewerId: String? = nil, force: Bool = false) async {
        generation += 1
        let currentGeneration = generation
        if force {
            resolved = [:]
        }

        if let viewerId, viewerId != ownerId {
            // 取れなくても欄は出す（ブロック一覧の取得失敗で、おすすめの空まで消さない）
            let blocked = (try? await firestoreService.fetchBlockedUserIds(userId: viewerId)) ?? []
            guard currentGeneration == generation else { return }
            blockedUserIds = Set(blocked)
        }

        let ids = RecommendedSkies.normalized(postIds)
        let missing = ids.filter { resolved[$0] == nil }

        if !missing.isEmpty {
            // 初回（何も出ていない）ときだけローディング表示にする。並べ替え等では出さない
            isLoading = items.isEmpty
            let fetched = await resolve(postIds: missing, ownerId: ownerId)
            // 読み込み中に新しい一覧で load が呼ばれていたら、この結果では描かない
            // （ローディング表示の解除も新しい方の load に任せる）
            guard currentGeneration == generation else { return }
            resolved.merge(fetched) { _, new in new }
        }

        isLoading = false
        rebuild(from: ids)
    }

    // MARK: - Private

    /// 解決済みの結果から、一覧の順で表示用の配列を作り直す
    private func rebuild(from ids: [String]) {
        var newItems: [Item] = []
        var newUnavailable: [String] = []
        for id in ids {
            switch resolved[id] {
            case let .item(item):
                // 閲覧者がブロックしている人の投稿は出さない（「表示できない空」にも数えない）
                guard !blockedUserIds.contains(item.post.userId) else { continue }
                newItems.append(item)
            case .unavailable:
                newUnavailable.append(id)
            case nil:
                // 一時的な失敗で解決できなかった投稿は、出さずに次回の読み込みで取り直す
                // （「表示できない空」に数えると、持ち主に誤って整理を促してしまう）
                continue
            }
        }
        items = newItems
        unavailablePostIds = newUnavailable
    }

    /// 投稿を 1 件ずつ並列に解決し、他の人の投稿には投稿者名を添える
    private func resolve(postIds: [String], ownerId: String) async -> [String: Resolution] {
        // 1. 投稿を取得
        let postResults: [(String, Result<Post, Error>)] = await withTaskGroup(
            of: (String, Result<Post, Error>).self
        ) { group in
            for postId in postIds {
                group.addTask { [firestoreService] in
                    do {
                        return (postId, .success(try await firestoreService.fetchPost(postId: postId)))
                    } catch {
                        return (postId, .failure(error))
                    }
                }
            }
            var collected: [(String, Result<Post, Error>)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        var posts: [String: Post] = [:]
        var resolutions: [String: Resolution] = [:]
        for (postId, result) in postResults {
            switch result {
            case let .success(post):
                if post.visibility == .public {
                    posts[postId] = post
                } else {
                    // 非公開・フォロワー限定に変わった投稿は欄に出さない
                    resolutions[postId] = .unavailable
                }
            case let .failure(error):
                if PostAvailability.isUnavailable(error) {
                    resolutions[postId] = .unavailable
                } else {
                    // 一時的な失敗は結果に入れない（次回の読み込みで取り直す）
                    print("❌ おすすめの空の投稿取得に失敗 postId=\(postId) error=\(error.localizedDescription)")
                }
            }
        }

        // 2. 他の人の投稿の投稿者名を取得（取れなくても投稿は出す）
        let authorIds = Set(posts.values.map(\.userId)).subtracting([ownerId])
        let authorNames: [String: String] = await withTaskGroup(of: (String, String?).self) { group in
            for authorId in authorIds {
                group.addTask { [firestoreService] in
                    let profile = try? await firestoreService.fetchPublicProfile(userId: authorId)
                    return (authorId, profile?.displayName)
                }
            }
            var names: [String: String] = [:]
            for await (authorId, name) in group {
                if let name, !name.isEmpty {
                    names[authorId] = name
                }
            }
            return names
        }

        for (postId, post) in posts {
            let authorName = post.userId == ownerId ? nil : authorNames[post.userId]
            resolutions[postId] = .item(Item(post: post, authorName: authorName))
        }
        return resolutions
    }
}
