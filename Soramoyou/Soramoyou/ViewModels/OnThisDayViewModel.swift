//
//  OnThisDayViewModel.swift
//  Soramoyou
//
//  On This Day（1年前の空）の ViewModel。自分の投稿を取得し、同月日の過去投稿を抽出する。
//

import Foundation

@MainActor
final class OnThisDayViewModel: ObservableObject {

    @Published private(set) var memories: [OnThisDayMemory] = []
    /// ストリーク（連続投稿日数）。ホームのチップ表示用。
    /// メモリーと同じ投稿取得を使い回して算出する（同一クエリの二重フェッチを避ける）。
    @Published private(set) var streak: SkyStreakState = .empty
    @Published private(set) var isLoading = false

    private let firestoreService: FirestoreServiceProtocol
    /// 全件取得の上限（SkyCollection と同様、趣味アプリの1ユーザーを十分カバー）。
    private let fetchLimit = 1000

    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }

    /// 自分の投稿を取得し、今日と同じ月日の過去投稿（メモリー）とストリークを算出する。
    func load(userId: String, today: Date = Date()) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let posts = try await firestoreService.fetchUserPosts(
                userId: userId,
                limit: fetchLimit,
                lastDocument: nil
            )
            memories = OnThisDayService.memories(from: posts, today: today)
            streak = SkyStreakCalculator.calculate(posts: posts, today: today)
        } catch {
            // メモリー表示はベストエフォート（失敗してもホーム表示を妨げない）
            memories = []
            streak = .empty
        }
    }
}
