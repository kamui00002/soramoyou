//
//  CalendarDiaryViewModel.swift
//  Soramoyou
//
//  空カレンダー日記の ViewModel。自分の投稿を取得し、純関数 CalendarDiaryService で
//  暦日ごとにグルーピングする（SkyCollectionViewModel / OnThisDayViewModel と同型）。
//  他人の空カレンダー（フォロワーが他人のプロフィールから開く）は `loadOtherUser(userId:)` で読む ⭐️
//

// FirestoreErrorDomain・FirestoreErrorCode（他人用の読み取りの拒否を見分けるため）⭐️ 1.18.0 PR-B
import FirebaseFirestore
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

    /// 他人の空カレンダー用: 見られる公開範囲（公開・フォロワー限定）の投稿だけを取得し、暦日ごとにグルーピングする ⭐️
    ///
    /// ⚠️ 他人には `fetchUserPosts` を使えない。公開範囲で絞らないクエリは、Firestore Security Rules が
    ///    「非公開も含みうる」と判断してクエリ全体が permission-denied になる（UserProfileViewModel の
    ///    `fetchVisiblePostsSafe` のコメント＝欠陥 D と同じ理由）。
    ///
    /// ⚠️ `[.public, .followers]` を渡せるのは、他人の空カレンダーの入口が**フォロワーにしか出ない**から
    ///    （ルールの followers の枝を満たせる＝読めると証明できる）。フォローしていない人に `.followers` を
    ///    要求すると、公開の投稿まで巻き添えでクエリ全体が拒否される。
    ///
    /// ⚠️ `lastLoadedUserId` には**書かない**。`.postCreated` の通知での読み直しは本人用だけ
    ///    （ここで書くと、通知を受けたときに他人の uid で `fetchUserPosts` を呼んで権限エラーになる）。
    ///    他人の投稿を閲覧者が再編集することは無いので、読み直しが無くても古い表示にはならない。
    /// - Parameter userId: 空カレンダーの持ち主（他人）の uid
    func loadOtherUser(userId: String) async {
        lastLoadedUserId = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let posts = try await firestoreService.fetchVisibleUserPosts(
                userId: userId,
                visibilities: [.public, .followers],
                limit: fetchLimit,
                lastDocument: nil
            )
            // 本人用と同じく、グリッド描画・空月判定とずれないようグレゴリオ暦で暦日キーを作る
            postsByDay = CalendarDiaryService.groupByDay(posts: posts, calendar: .soramoyouGregorian)

            #if DEBUG
                if posts.count >= fetchLimit {
                    print("⚠️ CalendarDiary(他人): 取得が上限(\(fetchLimit))に達しました。古い投稿が欠落する可能性があります。")
                }
            #endif
        } catch {
            // ルールに拒否された＝入口を開いた後にフォローが外れた（持ち主がフォロワーから外した・
            // ブロックでお互いのフォローが外れた）⭐️ 1.18.0 PR-B
            // `[.public, .followers]` の followers の枝を満たせなくなり、公開の投稿まで巻き添えでクエリ全体が拒否される。
            // SDK の英語の文（Missing or insufficient permissions.）をそのまま出さず、理由が分かる日本語にする
            // （他人のお気に入りの「見られなくなりました」と同じ見分け方・同じ言い方・2026-10-25 利用者の決定）。
            // ⚠️ 想定どおりの状態なので ErrorHandler（Crashlytics）には記録しない（本物の不具合が埋もれるため。
            //    FavoritesViewModel.markAccessRevoked と同じ考え方）。
            if Self.isPermissionDenied(error) {
                print("ℹ️ 他人の空カレンダー: 読み取りが拒否されたため「フォローが外れた」の文を出します")
                errorMessage = "フォローが外れたため、いまは空カレンダーを見られません"
                return
            }
            // ⚠️ userId には他人の uid を渡さない（記録に残るのは閲覧者の端末の失敗なので、持ち主の uid は要らない）
            ErrorHandler.logError(error, context: "CalendarDiaryViewModel.loadOtherUser", userId: nil)
            errorMessage = error.localizedDescription
        }
    }

    /// 投稿の読み取りがルールに拒否された（permission-denied）か ⭐️ 1.18.0 PR-B
    ///
    /// `fetchVisibleUserPosts` は失敗を `FirestoreServiceError.fetchFailed(元のエラー)` で包んで投げる。
    /// 見分け方は `FavoritesViewModel.isPermissionDenied` と同じ（ドメインとコードの両方を見る）。
    private static func isPermissionDenied(_ error: Error) -> Bool {
        guard case let .fetchFailed(underlying)? = error as? FirestoreServiceError else { return false }
        let nsError = underlying as NSError
        return nsError.domain == FirestoreErrorDomain
            && nsError.code == FirestoreErrorCode.permissionDenied.rawValue
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
