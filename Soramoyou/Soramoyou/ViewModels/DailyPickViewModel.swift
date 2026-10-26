//
//  DailyPickViewModel.swift
//  Soramoyou
//
//  ホーム「すべて」の「今日のおすすめのそらもよう」カードの状態 ⭐️☁️
//
//  流れ: 今日の文書 → 無ければ前日の文書 → 候補を先頭から 1 件ずつ fetchPost →
//  公開・ブロックしていない投稿者の最初の 1 件を出す（ゲストも 1 件・名前は出さない＝利用者の決定 2026-10-26）。
//  ⚠️ 「私のおすすめの空」（publicProfiles.recommendedPostIds）とは別物。名前は dailyPick 系で統一する。
//

import Foundation

// MARK: - 表示する 1 件

/// カードに出す 1 件
struct DailyPickItem {
    /// 出す投稿（公開・ブロックしていない投稿者のもの）
    let post: Post
    /// 投稿者の表示名。ゲスト・取得失敗・名前なしは nil（カードは「ユーザー」と出す＝HomeView の投稿者欄と同じ扱い）
    let authorName: String?
    /// 出している文書の鍵（前日の文書なら前日の鍵）
    let dateKey: String
    /// postIds の何番目か（0 始まり）
    let candidateIndex: Int
    /// 今日の文書が無く、前日の文書から出しているか
    let isFallbackDay: Bool
}

// MARK: - 計装の差し替え口

/// 計装の送り先（テストでは記録するだけの偽物を渡す）
protocol DailyPickEventLogging: AnyObject {
    func logEvent(_ name: String, parameters: [String: Any]?)
}

/// 本番は LoggingService（PostHog・Firebase Analytics の両方に送る）。署名はそのまま合う
extension LoggingService: DailyPickEventLogging {}

// MARK: - セッション中 1 回の記録係

/// `daily_pick_shown`・`daily_pick_unavailable` を「同じ date_key でセッション中 1 回」に抑える記録係
///
/// タブの切り替えでホームが作り直される（＝VM も作り直される）ため、VM のインスタンス変数では守れない。
/// 本番は `shared`（アプリが生きている間だけ覚える）、テストはケースごとに `DailyPickSessionLog()` を作って渡す。
@MainActor
final class DailyPickSessionLog {
    static let shared = DailyPickSessionLog()

    init() {}

    /// まだ記録していなければ記録して true、記録済みなら false
    /// - Parameters:
    ///   - event: イベント名（例: "daily_pick_shown"）
    ///   - dateKey: その日の鍵
    func markFirst(event _: String, dateKey _: String) -> Bool {
        // 契約の仮の実装（A3 が置き換える）
        true
    }
}

// MARK: - ViewModel

@MainActor
final class DailyPickViewModel: ObservableObject {
    /// カードに出す 1 件。nil ならカードを描かない
    @Published private(set) var item: DailyPickItem?

    private let dailyPickService: DailyPickServiceProtocol
    private let firestoreService: FirestoreServiceProtocol
    private let logger: DailyPickEventLogging
    private let sessionLog: DailyPickSessionLog
    private let notificationCenter: NotificationCenter
    private let now: () -> Date

    init(
        dailyPickService: DailyPickServiceProtocol = DailyPickService(),
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        logger: DailyPickEventLogging = LoggingService.shared,
        // nil の既定値にしているのは、`.shared`（MainActor の static）を既定値の式に書くと
        // 既定値が MainActor の外で評価されて警告になるため（Swift 6 ではエラー）。本体の中で解決する
        sessionLog: DailyPickSessionLog? = nil,
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.dailyPickService = dailyPickService
        self.firestoreService = firestoreService
        self.logger = logger
        self.sessionLog = sessionLog ?? .shared
        self.notificationCenter = notificationCenter
        self.now = now
    }

    /// 今日のおすすめを読み込む（HomeView の onAppear からログイン条件なしで呼ぶ）
    /// - Parameters:
    ///   - viewerId: 見ている人の uid。ゲストは nil（ブロック一覧と名前を取りに行かない）
    ///   - force: 引っ張って更新のとき true（同じ鍵でも取り直す）
    func load(viewerId _: String?, force _: Bool = false) async {
        // 契約の仮の実装（A3 が置き換える）
    }

    /// カードがタップされたときに呼ぶ（計装だけ。画面の遷移は HomeView が selectedPost で行う）
    func recordTapped() {
        // 契約の仮の実装（A3 が置き換える）
    }
}
