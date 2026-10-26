//
//  DailyPickService.swift
//  Soramoyou
//
//  「今日のおすすめのそらもよう」の文書（dailyPicks/{yyyy-MM-dd}）を読むサービス ⭐️
//
//  別 protocol にしているのは RankingService・TagFeedService の前例どおり（FirestoreServiceProtocol を太らせない）。
//  ルールは `dailyPicks` の get だけ誰でも可（ゲスト含む）・list と書き込みは不可（firestore.rules）。
//  ⚠️ 「私のおすすめの空」（publicProfiles.recommendedPostIds）とは別物。名前は dailyPick 系で統一する。
//

import FirebaseFirestore
import Foundation

// MARK: - Protocol

/// 今日のおすすめの文書を読むインターフェース（テスト時にモックを注入可能）
protocol DailyPickServiceProtocol {
    /// dailyPicks/{dateKey} を 1 件読む
    /// - Parameter dateKey: yyyy-MM-dd
    /// - Returns: 文書が無い・使える postIds が無いときは nil
    /// - Throws: 読めなかったとき（ネットワーク断など）。呼び出し側はそこで止める
    func fetchDailyPick(dateKey: String) async throws -> DailyPick?
}

// MARK: - Service

/// 今日のおすすめの文書を読むサービス
final class DailyPickService: DailyPickServiceProtocol {
    private let db: Firestore

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func fetchDailyPick(dateKey _: String) async throws -> DailyPick? {
        // 契約の仮の実装（A2 が置き換える）
        nil
    }
}
