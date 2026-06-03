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
    @Published private(set) var isLoading = false

    private let firestoreService: FirestoreServiceProtocol
    /// 全件取得の上限（SkyCollection と同様、趣味アプリの1ユーザーを十分カバー）。
    private let fetchLimit = 1000

    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }

    /// 自分の投稿を取得し、今日と同じ月日の過去投稿（メモリー）を算出する。
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
        } catch {
            // メモリー表示はベストエフォート（失敗してもホーム表示を妨げない）
            memories = []
        }
    }
}
