//
//  DailyPick.swift
//  Soramoyou
//
//  「今日のおすすめのそらもよう」の 1 日ぶんの文書（dailyPicks/{yyyy-MM-dd}）と、
//  候補を 1 件ずつ見て「出す／次へ／止める」を決める純関数 ⭐️
//
//  文書はサーバー（publishDailyPick）だけが書く。postIds は最大 5 件で、先頭から順に「今日の主役」と「代役」。
//  カードに出すのはいつも 1 件（ゲストも同じ・利用者の決定 2026-10-26）。
//  ⚠️ 「私のおすすめの空」（publicProfiles.recommendedPostIds）とは別物。名前は dailyPick 系で統一する。
//

import Foundation

/// dailyPicks/{dateKey} の中身（アプリが使う項目だけ）
struct DailyPick: Equatable {
    /// 端末で見る候補の上限（サーバーが書くのは最大 5 件。手で増やされても読む数を抑える）
    static let maxCandidates = 5

    /// 文書 ID（yyyy-MM-dd）
    let dateKey: String
    /// 候補の投稿 ID（先頭から順に見る。1 件以上・重複なし・空文字と「/」入りは含まない）
    let postIds: [String]

    /// Firestore の data を読む
    /// - Parameters:
    ///   - dateKey: 文書 ID
    ///   - data: `DocumentSnapshot.data()`
    /// - Returns: 使える postIds が 1 件も無ければ nil
    static func parse(dateKey _: String, data _: [String: Any]) -> DailyPick? {
        // 契約の仮の実装（A1 が置き換える）
        nil
    }
}

/// 候補 1 件を見た結果
enum DailyPickOutcome: Equatable {
    /// これをカードに出す
    case show
    /// 次の候補へ（削除済み・非公開・壊れている・公開でない・ブロック中の投稿者）
    case skip
    /// そこで止めて何も出さない（一時的な失敗。代役に回すと「全員に同じ 1 枚」が崩れるため）
    case stop
}

/// 候補の分類（純関数・Firestore に触らない）
enum DailyPickResolver {
    /// 読めた投稿を分類する
    /// - Parameters:
    ///   - post: fetchPost で読めた投稿
    ///   - blockedUserIds: 見ている人がブロックしている投稿者（ゲストは空）
    /// - Returns: 公開かつブロックしていない投稿者なら `.show`、それ以外は `.skip`
    static func classify(post _: Post, blockedUserIds _: Set<String>) -> DailyPickOutcome {
        // 契約の仮の実装（A1 が置き換える）
        .stop
    }

    /// 読めなかった投稿を分類する
    /// - Parameter error: fetchPost が投げたエラー
    /// - Returns: `PostAvailability.isUnavailable` なら `.skip`、それ以外（ネットワーク断など）は `.stop`
    static func classify(error _: Error) -> DailyPickOutcome {
        // 契約の仮の実装（A1 が置き換える）
        .stop
    }
}
