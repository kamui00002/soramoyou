//
//  CalendarDiaryViewModel.swift
//  Soramoyou
//
//  空カレンダー日記の ViewModel。自分の投稿を取得し、純関数 CalendarDiaryService で
//  暦日ごとにグルーピングする（SkyCollectionViewModel / OnThisDayViewModel と同型）。
//

import Foundation

@MainActor
final class CalendarDiaryViewModel: ObservableObject {

    /// 暦日（年/月/日）ごとにグルーピングした投稿
    @Published private(set) var postsByDay: [SkyStreakDay: [Post]] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let firestoreService: FirestoreServiceProtocol
    /// 全件取得の上限（SkyCollection / OnThisDay と同様、趣味アプリの1ユーザーを十分カバー）。
    private let fetchLimit = 1000

    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }

    /// 指定ユーザーの全投稿を取得し、暦日ごとにグルーピングする。
    func load(userId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let posts = try await firestoreService.fetchUserPosts(
                userId: userId,
                limit: fetchLimit,
                lastDocument: nil
            )
            // グリッド描画・空月判定と暦日キーがズレないよう、グレゴリオ暦を明示的に渡す
            // （和暦ユーザーが全セル空白になるバグの回帰防止。Calendar+Soramoyou.swift 参照）。
            postsByDay = CalendarDiaryService.groupByDay(posts: posts, calendar: .soramoyouGregorian)

            #if DEBUG
            if posts.count >= fetchLimit {
                print("⚠️ CalendarDiary: 取得が上限(\(fetchLimit))に達しました。古い投稿が欠落する可能性があります。")
            }
            #endif
        } catch {
            ErrorHandler.logError(error, context: "CalendarDiaryViewModel.load", userId: userId)
            errorMessage = error.localizedDescription
        }
    }

    /// 指定した暦日の投稿（無ければ空配列）
    func posts(on day: SkyStreakDay) -> [Post] {
        postsByDay[day] ?? []
    }

    /// 指定した年/月に1件でも投稿があるか（月ごとの空状態表示の判定に使う）
    func hasPosts(year: Int, month: Int) -> Bool {
        postsByDay.keys.contains { $0.year == year && $0.month == month }
    }
}
