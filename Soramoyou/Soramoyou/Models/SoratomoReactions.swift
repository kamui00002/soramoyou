//
//  SoratomoReactions.swift
//  Soramoyou
//
//  そらともの投稿へのリアクションのモデル ⭐️
//  7 種類の絵文字・投稿の中のリアクション・画面に出す数と一覧（soratomo-reactions tasks 7.1・design.md の iOS の型）。
//
//  ⚠️ 名前（rawValue）と絵文字は functions/soratomoCore.js の REACTION_KINDS と一致させること。
//     並び・名前・絵文字のコードポイントは、SoratomoReactionKindTests と soratomoCore.test.js の両方で 7 行とも固定している。
//     絵文字は見えない U+FE0F を落とさないよう、文字そのものでなく `\u{...}` のエスケープで書く。
//  ⚠️ リアクションは既存のいいね（LikeManager）・お気に入り・おすすめ・ランキングとは別のもの。Post へ変換する口を作らないこと（要件 12.2・12.3）。
//

import FirebaseFirestore
import Foundation

// MARK: - 7 種類の絵文字

/// リアクションの絵文字（7 種類・並びは表示の順・rawValue は保存と計測の名前）
///
/// 送る値・保存する値・計測の `kind` は rawValue（英小文字のスネークケース）で、絵文字そのものは送らない。
/// 並びはメニューの選択肢と数の表示の並びに使う（数の多い順に並べ替えない）。
enum SoratomoReactionKind: String, CaseIterable, Sendable {
    case sunset, cloud, rainbow, sparkles, eyes
    case redHeart = "red_heart", blueHeart = "blue_heart"

    /// 表の絵文字（FE0F を含む形）
    var emoji: String {
        switch self {
        case .sunset: "\u{1F305}" // 🌅（Unicode の名前は SUNRISE だが、アプリでは「夕焼け」と呼ぶ・決定事項P1）
        case .cloud: "\u{2601}\u{FE0F}" // ☁️（U+2601 U+FE0F）
        case .rainbow: "\u{1F308}" // 🌈
        case .sparkles: "\u{2728}" // ✨（UTF-16 で 1 単位）
        case .eyes: "\u{1F440}" // 👀
        case .redHeart: "\u{2764}\u{FE0F}" // ❤️（U+2764 U+FE0F）
        case .blueHeart: "\u{1F499}" // 💙
        }
    }

    /// VoiceOver の日本語名（要件 13.3）
    var spokenName: String {
        switch self {
        case .sunset: "夕焼け"
        case .cloud: "くも"
        case .rainbow: "虹"
        case .sparkles: "きれい"
        case .eyes: "見たよ"
        case .redHeart: "赤いハート"
        case .blueHeart: "青いハート"
        }
    }
}

// MARK: - 投稿の中のリアクション

/// 1 人分のリアクション
struct SoratomoReaction: Equatable, Sendable {
    /// 付けた絵文字
    let kind: SoratomoReactionKind
    /// 付けた・選び直した時刻（サーバーの時刻。読めなければ nil）
    let reactedAt: Date?
}

/// 投稿に付いたリアクション（uid → 1 人分。Firestore の `skies/{skyId}.reactions`）
///
/// 書き手は Functions だけ（`soratomoSetReaction` と、抜ける・退会の片づけ）。アプリは読むだけ。
/// 1 人が 1 つの投稿に持てるのは 1 つ（地図のキーが uid）。
struct SoratomoReactions: Equatable, Sendable {
    /// リアクションが 1 つも無い（項目が無い投稿・リアクションを足す前に作られた投稿も、これになる）
    static let empty = SoratomoReactions(byUser: [:])

    /// 付けた人の uid → 1 人分
    let byUser: [String: SoratomoReaction]

    /// Firestore の項目名（functions/soratomoStore.js の setReactionTx が書く形 `{ kind, at }` と一致させる）
    private enum Field {
        static let reactions = "reactions"
        static let kind = "kind"
        static let at = "at"
    }

    /// Firestore の `reactions` の値から作る。投げない
    ///
    /// 壊れたリアクションのせいで投稿そのものを飛ばさないよう、例外は投げずに読めた分だけを返す。
    /// - 無い → 空
    /// - 地図でない → 空（パスと項目名だけをコンソールに出す。値は出さない）
    /// - 1 人分の値が地図でない・`kind` が文字列でない・知らない名前 → その 1 人分だけ飛ばす
    ///   （新しい版で種類が増えても、古い版が落ちない）
    /// - `at` が無い・`Timestamp` でない → リアクションは残し、時刻を nil にする
    /// - Parameters:
    ///   - raw: 文書の `reactions` の値（`data["reactions"]`）
    ///   - path: 文書のパス（地図でないときのログに使う。分からなければ nil）
    /// - Returns: 読めた分のリアクション
    static func decode(_ raw: Any?, path: String? = nil) -> SoratomoReactions {
        // 項目が無い（まだだれも付けていない・リアクションを足す前の投稿）は 0 件
        guard let raw else { return .empty }
        guard let map = raw as? [String: Any] else {
            // 値（uid など）は出さず、どの文書のどの項目かだけを残す
            print("⚠️ そらともリアクションを読めない path=\(path ?? "不明") field=\(Field.reactions)")
            return .empty
        }

        var byUser: [String: SoratomoReaction] = [:]
        for (uid, value) in map {
            // 1 人分が壊れていても、その人だけを飛ばしてほかの人の分は読む
            guard let entry = value as? [String: Any],
                  let name = entry[Field.kind] as? String,
                  let kind = SoratomoReactionKind(rawValue: name)
            else { continue }
            // 時刻は並び順にしか使わないので、読めなくてもリアクションは数える
            let reactedAt = (entry[Field.at] as? Timestamp)?.dateValue()
            byUser[uid] = SoratomoReaction(kind: kind, reactedAt: reactedAt)
        }
        return SoratomoReactions(byUser: byUser)
    }
}

// MARK: - 自分の分の一時の上書き

/// 自分の分の一時の上書き（送っている間と、確定してから 10 秒）
///
/// 監視の結果が届くまでの間、自分の操作を画面にすぐ出すために使う。上書きはメモリだけで、端末に残さない。
enum SoratomoReactionOverride: Equatable, Sendable {
    /// この絵文字を付けた（付ける・選び直す）
    case set(SoratomoReactionKind)
    /// 外した
    case removed
}

// MARK: - 画面に出す数と一覧

/// 画面に出す数と一覧（1 つの集合から作るので、一覧の人数と数の合計は必ず一致する・要件 3.6）
struct SoratomoReactionSummary: Equatable, Sendable {
    /// 1 つの絵文字の数
    struct Count: Equatable, Sendable {
        /// 絵文字
        let kind: SoratomoReactionKind
        /// 付けた人の数（1 以上）
        let count: Int
    }

    /// 絵文字の並び順で、1 以上のものだけ（要件 2.1・2.3）
    let counts: [Count]
    /// 自分が付けた絵文字（上書きを反映した後。要件 2.2）
    let myKind: SoratomoReactionKind?
    /// counts の合計
    let total: Int
    /// 押した人の一覧の行（新しい順。同じ時刻どうしと時刻の無いものどうしは uid の順。時刻の無いものは最後）
    let reactors: [SoratomoReactorEntry]

    /// 投稿のリアクションから、画面に出す数と一覧を作る
    ///
    /// - ブロックの一覧（`blockedUserIds`）にいる人を除く（要件 5.1〜5.3）。自分は除かない
    /// - 自分の分は上書きがあれば上書きを使う（要件 1.9）。ログアウト中（`myUid` が nil）は上書きを使わない
    /// - 投稿者本人のキーがあっても数える（ふつうは保存されない・design.md）。この関数は投稿者を知らない
    /// - Parameters:
    ///   - reactions: サーバーに保存されたリアクション
    ///   - myUid: 自分の uid（ログアウト中は nil）
    ///   - myOverride: 自分の分の一時の上書き（無ければ nil）
    ///   - blockedUserIds: 自分がブロックした人の uid
    /// - Returns: 画面に出す数と一覧
    static func make(
        reactions: SoratomoReactions,
        myUid: String?,
        myOverride: SoratomoReactionOverride?,
        blockedUserIds: Set<String>
    ) -> SoratomoReactionSummary {
        // ① ブロックした人を除く（自分の分は、万一一覧に入っていても残す）
        var entries = reactions.byUser.filter { uid, _ in
            uid == myUid || !blockedUserIds.contains(uid)
        }

        // ② 自分の分を上書きで置き換える
        if let myUid, let myOverride {
            switch myOverride {
            case let .set(kind):
                // 時刻は、サーバーに自分の分があればそれを使う（一覧の中の位置を、確定の前後で動かさない）
                entries[myUid] = SoratomoReaction(kind: kind, reactedAt: entries[myUid]?.reactedAt)
            case .removed:
                entries[myUid] = nil
            }
        }

        // ③ 絵文字ごとに数え、絵文字の並び順のまま 1 以上だけを残す（数の多い順に並べ替えない）
        var tally: [SoratomoReactionKind: Int] = [:]
        for reaction in entries.values {
            tally[reaction.kind, default: 0] += 1
        }
        let counts = SoratomoReactionKind.allCases.compactMap { kind -> Count? in
            guard let count = tally[kind], count >= 1 else { return nil }
            return Count(kind: kind, count: count)
        }

        // ④ 一覧は数と同じ集合（entries）から作る
        let reactors = entries
            .map { uid, reaction in
                SoratomoReactorEntry(id: uid, kind: reaction.kind, reactedAt: reaction.reactedAt)
            }
            .sorted(by: precedes)

        return SoratomoReactionSummary(
            counts: counts,
            myKind: myUid.flatMap { entries[$0]?.kind },
            total: counts.reduce(0) { $0 + $1.count },
            reactors: reactors
        )
    }

    /// 一覧の並び（新しい順。時刻の無いものは最後。同じ時刻どうし・時刻の無いものどうしは uid の順）
    ///
    /// 地図（Dictionary）の順番は決まらないので、時刻が同じでも毎回同じ並びになるよう uid で決める。
    private static func precedes(_ lhs: SoratomoReactorEntry, _ rhs: SoratomoReactorEntry) -> Bool {
        switch (lhs.reactedAt, rhs.reactedAt) {
        case let (left?, right?) where left != right:
            left > right
        case (.some, .none):
            true
        case (.none, .some):
            false
        default:
            lhs.id < rhs.id
        }
    }

    /// VoiceOver の読み上げ（要件 13.2・13.3）
    ///
    /// 例: 「リアクション、夕焼け3人、虹1人。あなたは夕焼けを付けています」。
    /// 0 件のときは数を表示しない（要件 2.3）が、読み上げの文は「リアクションなし」に決めておく。
    var accessibilityLabel: String {
        guard total > 0 else { return "リアクションなし" }
        let parts = counts.map { "\($0.kind.spokenName)\($0.count)人" }
        var label = "リアクション、" + parts.joined(separator: "、")
        if let myKind {
            label += "。あなたは\(myKind.spokenName)を付けています"
        }
        return label
    }
}

/// 押した人の一覧の 1 行（表示名とアイコンは画面が SoratomoProfileStore から出す）
struct SoratomoReactorEntry: Identifiable, Equatable, Sendable {
    /// 付けた人の uid
    let id: String
    /// その人が付けた絵文字
    let kind: SoratomoReactionKind
    /// 付けた・選び直した時刻（読めなければ nil）
    let reactedAt: Date?
}
