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
    /// 投稿作成通知の購読を保持（ProfileViewModel と同型のパターン）。
    private var postCreatedObserver: NSObjectProtocol?
    /// 直近の load(userId:) 呼び出しの userId。通知受信時の再読み込みに使う。
    private var lastLoadedUserId: String?

    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
        setupPostCreatedObserver()
    }

    deinit {
        if let observer = postCreatedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 投稿作成通知を監視し、カレンダーの投稿一覧を自動更新する ☁️
    ///
    /// 再編集（投稿済み画像の上書き更新）は同じ postId のドキュメントを新しい画像URLで
    /// 置き換えるが、`.postCreated` を購読していないと `postsByDay` は古いまま残り、
    /// カレンダー日記 → 投稿詳細 → 再編集 → 戻る、で削除済みの旧画像を表示し続ける
    /// （統合レビューで発見）。
    private func setupPostCreatedObserver() {
        postCreatedObserver = NotificationCenter.default.addObserver(
            forName: .postCreated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard let userId = self.lastLoadedUserId else { return }
                await self.load(userId: userId)
            }
        }
    }

    /// 指定ユーザーの全投稿を取得し、暦日ごとにグルーピングする。
    func load(userId: String) async {
        lastLoadedUserId = userId
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
