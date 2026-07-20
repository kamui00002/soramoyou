//
//  SkyCollectionViewModel.swift
//  Soramoyou
//
//  空コレクション図鑑（柱2）の ViewModel。
//  ユーザーの全投稿を取得し、純関数 SkyCollectionAggregator で集計する。
//

import Foundation

@MainActor
final class SkyCollectionViewModel: ObservableObject {

    /// 集計結果（あなたが集めた空）
    @Published private(set) var state: CollectionState = CollectionState()
    /// ストリーク（連続投稿日数）の状態。カレンダー表示と「◯日連続」表示に使う
    @Published private(set) var streak: SkyStreakState = .empty
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let firestoreService: FirestoreServiceProtocol

    /// 全件取得の上限。趣味アプリの 1 ユーザーは十分カバーできる想定。
    /// 超過時は完遂バッジが不正確になりうるため DEBUG ログを出す（将来は完全ページングへ）。
    private let fetchLimit = 1000

    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }

    /// 指定ユーザーの全投稿を取得して集計する。
    func load(userId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let posts = try await firestoreService.fetchUserPosts(
                userId: userId,
                limit: fetchLimit,
                lastDocument: nil
            )
            state = SkyCollectionAggregator.aggregate(posts: posts)

            // ストリーク（連続投稿日数）を算出し、連続バッジ用に longestStreak を state へ反映
            // グレゴリオ暦を明示的に渡す（和暦ユーザーで postedDays の年がカレンダー描画とズレる
            // バグの回帰防止。CalendarDiaryViewModel.load / Calendar+Soramoyou.swift 参照）。
            streak = SkyStreakCalculator.calculate(posts: posts, today: Date(), calendar: .soramoyouGregorian)
            state.longestStreak = streak.longestStreak

            // 図鑑表示の計装（柱2 主要画面）
            LoggingService.shared.logEvent("sky_zukan_viewed", parameters: [
                "total_posts": state.totalPosts,
                "unlocked_badges": unlockedBadges.count
            ])

            #if DEBUG
            if posts.count >= fetchLimit {
                print("⚠️ SkyCollection: 取得が上限(\(fetchLimit))に達しました。完遂バッジが不正確になる可能性があります。")
            }
            #endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 解放済みバッジ（上に表示）
    var unlockedBadges: [SkyBadge] { SkyBadge.all.filter { $0.isUnlocked(state) } }
    /// 未解放バッジ（下に表示）
    var lockedBadges: [SkyBadge] { SkyBadge.all.filter { !$0.isUnlocked(state) } }
}
