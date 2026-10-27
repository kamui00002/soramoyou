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

    /// dailyPicks/{dateKey} を文書 ID で 1 件だけ読む
    ///
    /// - ルールは `dailyPicks` の get だけ誰でも可（ゲスト含む）・list は不可。
    ///   だからクエリ（whereField / getDocuments）にせず、文書 ID を指定して 1 件だけ読む。
    /// - `getDocument()` の source は既定のまま（サーバー優先・オフラインならキャッシュを返す）。
    ///   ホームの上に出す軽い枠なので、電波が悪いときに前回の文書が見えるほうが
    ///   何も出ないより良い。キャッシュを強制すると古い日付のまま固まるので source は指定しない。
    func fetchDailyPick(dateKey: String) async throws -> DailyPick? {
        // dateKey が空・"/" を含むと文書パスが壊れ、Firestore SDK が例外で落ちる。
        // 問い合わせる前に弾いて「おすすめなし」として扱う。
        guard !dateKey.isEmpty, !dateKey.contains("/") else {
            print("❌ 今日のおすすめの dateKey が不正のため読まない dateKey=\(dateKey)")
            return nil
        }

        let snapshot: DocumentSnapshot
        do {
            snapshot = try await db.collection("dailyPicks").document(dateKey).getDocument()
        } catch {
            // 読み取りの失敗（ネットワーク断・権限など）は呼び出し側（VM）に伝えて止めてもらう。
            throw FirestoreServiceError.fetchFailed(error)
        }

        // 文書が無い（まだ選ばれていない日）のは正常。nil を返す。
        guard snapshot.exists, let data = snapshot.data() else {
            return nil
        }

        // ⚠️ 壊れた文書（形が違う・使える postIds が 0 件）を無言で落とさない。
        //    運用で発覚した壊れたデータを検知できるよう、パスをログに残してから nil を返す。
        guard let pick = DailyPick.parse(dateKey: dateKey, data: data) else {
            print("❌ 今日のおすすめの文書が壊れている path=\(snapshot.reference.path)")
            return nil
        }
        return pick
    }
}
