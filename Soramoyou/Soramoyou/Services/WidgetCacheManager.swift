//
//  WidgetCacheManager.swift
//  Soramoyou
//
//  本体アプリ側のウィジェットキャッシュ統括（ファサード）。
//  - 投稿成功時に焼き込み済みの実画像をローカルキャッシュへ書く
//  - 起動時に既存の自分の投稿をバックフィル（直近 N 件をローカル化）
//  - ログアウト/退会時にキャッシュをクリア
//  いずれも **best-effort**：失敗しても本体の主機能（投稿・認証）は妨げない。
//
//  ⚠️ 本体専用（WidgetCacheWriter=Metal・FirestoreService・WidgetCenter に依存）。ウィジェットには入れない。
//

import Foundation
import UIKit
import WidgetKit

/// ウィジェット用ローカルキャッシュの本体側統括。
final class WidgetCacheManager {
    static let shared = WidgetCacheManager()

    private let writer: WidgetCacheWriter
    private let firestoreService: FirestoreServiceProtocol
    private let session: URLSession

    /// バックフィル件数（Decision 2 = 直近50件）。
    private let backfillLimit = 50

    init(
        writer: WidgetCacheWriter = WidgetCacheWriter(),
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        session: URLSession = .shared
    ) {
        self.writer = writer
        self.firestoreService = firestoreService
        self.session = session
    }

    // MARK: - 投稿成功時

    /// 投稿成功時：焼き込み済みの実画像をウィジェットキャッシュへ書き、タイムラインを更新する。
    /// - Note: best-effort。App Group 未取得（entitlement なし）等で失敗しても投稿成功は妨げない。
    func cacheOnPost(image: UIImage, post: Post) {
        do {
            try writer.cache(
                image: image,
                postId: post.id,
                timeOfDay: post.timeOfDay?.rawValue,
                skyColors: post.skyColors ?? [],
                createdAt: post.createdAt
            )
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("⚠️ [Widget] 投稿時キャッシュ書き込み失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - バックフィル

    /// 既存の自分の投稿を直近 `backfillLimit` 件までローカルキャッシュ化する（best-effort・起動後1回想定）。
    /// - 既にキャッシュ済みの postId はスキップして再ダウンロードを避ける。
    /// - 重複排除は WidgetCacheWriter 側でも担保されるため、複数回呼んでも安全。
    func backfill(userId: String) async {
        let posts: [Post]
        do {
            posts = try await firestoreService.fetchUserPosts(userId: userId, limit: backfillLimit, lastDocument: nil)
        } catch {
            print("⚠️ [Widget] バックフィルの投稿取得失敗: \(error.localizedDescription)")
            return
        }

        let alreadyCached = Set(writer.loadIndex().entries.map { $0.postId })
        var didWrite = false

        for post in posts {
            if alreadyCached.contains(post.id) { continue }
            // 軽いサムネイル URL を優先（無ければ本体 URL）。リモート URL はキャッシュには保存しない。
            guard let urlString = post.images.first?.thumbnail ?? post.images.first?.url,
                  let url = URL(string: urlString),
                  let image = await downloadImage(from: url) else {
                continue
            }
            do {
                try writer.cache(
                    image: image,
                    postId: post.id,
                    timeOfDay: post.timeOfDay?.rawValue,
                    skyColors: post.skyColors ?? [],
                    createdAt: post.createdAt
                )
                didWrite = true
            } catch {
                print("⚠️ [Widget] バックフィル書き込み失敗 postId=\(post.id): \(error.localizedDescription)")
            }
        }

        if didWrite {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: - クリア

    /// ログアウト・退会時：ウィジェットキャッシュ（画像＋index）を消す。
    func clearOnSignOut() {
        do {
            try writer.clear()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("⚠️ [Widget] キャッシュのクリア失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - ヘルパー

    private func downloadImage(from url: URL) async -> UIImage? {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}
