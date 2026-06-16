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

    #if DEBUG
    // MARK: - シミュレータ確認用シード（launchArg SEED_WIDGET から呼ぶ・本番に影響なし）

    /// サンプルの空画像を数枚キャッシュへ書き、ウィジェットの写真表示をログインなしで確認できるようにする。
    func debugSeed() {
        let samples: [(id: String, tod: String, top: (Double, Double, Double), bottom: (Double, Double, Double))] = [
            ("seed-morning", "morning", (0.42, 0.68, 0.93), (0.87, 0.94, 0.99)),
            ("seed-day", "afternoon", (0.13, 0.45, 0.90), (0.75, 0.89, 0.99)),
            ("seed-evening", "evening", (0.99, 0.55, 0.32), (0.90, 0.38, 0.43)),
            ("seed-night", "night", (0.05, 0.07, 0.18), (0.13, 0.16, 0.32))
        ]
        let now = Date()
        for (i, sample) in samples.enumerated() {
            let image = Self.makeGradientImage(top: sample.top, bottom: sample.bottom)
            try? writer.cache(
                image: image,
                postId: sample.id,
                timeOfDay: sample.tod,
                skyColors: [],
                createdAt: now.addingTimeInterval(Double(-i) * 3600)
            )
        }
        WidgetCenter.shared.reloadAllTimelines()
        print("✅ [Widget] debugSeed: \(samples.count) 件のサンプル空をキャッシュ")
    }

    private static func makeGradientImage(top: (Double, Double, Double), bottom: (Double, Double, Double)) -> UIImage {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [
                UIColor(red: top.0, green: top.1, blue: top.2, alpha: 1).cgColor,
                UIColor(red: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            // 識別マーカー（「確かに写真が出ている」を一目で分かるように）：太陽/月＋地平線シルエット。
            cg.setFillColor(UIColor(white: 1.0, alpha: 0.92).cgColor)
            cg.fillEllipse(in: CGRect(x: 400, y: 110, width: 96, height: 96))
            cg.setFillColor(UIColor(red: 0.10, green: 0.12, blue: 0.10, alpha: 0.45).cgColor)
            cg.fill(CGRect(x: 0, y: 470, width: size.width, height: 130))
        }
    }
    #endif
}
