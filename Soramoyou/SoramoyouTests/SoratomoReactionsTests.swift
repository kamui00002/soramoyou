//
//  SoratomoReactionsTests.swift
//  SoramoyouTests
//
//  そらともの投稿の中のリアクション（decode）と、画面に出す数と一覧（SoratomoReactionSummary）のテスト ⭐️
//  （soratomo-reactions tasks 7.1）
//
//  ⚠️ 期待値は make の結果から作らず、数・並び・uid を直に書く（何もしない実装でも緑になる比べ方を避ける）。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

final class SoratomoReactionsTests: XCTestCase {
    // MARK: - 部品

    /// 秒単位の時刻（Timestamp を通しても値が変わらないよう、端数を持たせない）
    private func time(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(1_760_000_000 + seconds))
    }

    /// Firestore の 1 人分の値（`{ kind, at }`）
    private func raw(_ kind: String, at seconds: Int?) -> [String: Any] {
        var value: [String: Any] = ["kind": kind]
        if let seconds {
            value["at"] = Timestamp(date: time(seconds))
        }
        return value
    }

    /// テスト用のリアクション（uid → 絵文字・時刻の秒）
    private func reactions(_ entries: [String: (SoratomoReactionKind, Int?)]) -> SoratomoReactions {
        SoratomoReactions(byUser: entries.mapValues { kind, seconds in
            SoratomoReaction(kind: kind, reactedAt: seconds.map(time))
        })
    }

    /// 絵文字ごとの数
    private func count(_ kind: SoratomoReactionKind, _ count: Int) -> SoratomoReactionSummary.Count {
        SoratomoReactionSummary.Count(kind: kind, count: count)
    }

    // MARK: - decode

    func testDecodeMissingIsEmpty() {
        // 項目が無い投稿（リアクションを足す前の投稿・まだだれも付けていない投稿）
        XCTAssertEqual(SoratomoReactions.decode(nil), .empty)
        XCTAssertEqual(SoratomoReactions.decode(nil).byUser.count, 0)
    }

    func testDecodeNotMapIsEmpty() {
        // 地図でない値は 0 件として扱い、投げない
        let values: [Any] = ["sunset", ["u1", "u2"], 3, true, NSNull()]
        for value in values {
            XCTAssertEqual(
                SoratomoReactions.decode(value, path: "soratomoGroups/g1/skies/s1"),
                .empty,
                String(describing: type(of: value))
            )
        }
    }

    func testDecodeReadsKindAndTime() {
        let decoded = SoratomoReactions.decode([
            "u1": raw("sunset", at: 10),
            "u2": raw("red_heart", at: 20),
            "u3": raw("blue_heart", at: 30),
        ])
        XCTAssertEqual(decoded.byUser, [
            "u1": SoratomoReaction(kind: .sunset, reactedAt: time(10)),
            "u2": SoratomoReaction(kind: .redHeart, reactedAt: time(20)),
            "u3": SoratomoReaction(kind: .blueHeart, reactedAt: time(30)),
        ])
    }

    func testDecodeSkipsUnknownKindOnlyForThatUser() {
        // 新しい版で増えた種類・Swift のケース名・絵文字そのものは、その 1 人分だけ飛ばす
        let decoded = SoratomoReactions.decode([
            "u1": raw("sunset", at: 10),
            "u2": raw("thumbs_up", at: 20),
            "u3": raw("redHeart", at: 30),
            "u4": raw("\u{2601}\u{FE0F}", at: 40),
            "u5": raw("eyes", at: 50),
        ])
        XCTAssertEqual(decoded.byUser, [
            "u1": SoratomoReaction(kind: .sunset, reactedAt: time(10)),
            "u5": SoratomoReaction(kind: .eyes, reactedAt: time(50)),
        ])
    }

    func testDecodeSkipsMalformedValueOnlyForThatUser() {
        // 1 人分の値が地図でない・kind が無い・kind が文字列でない → その人だけ飛ばす
        let input: [String: Any] = [
            "u1": raw("rainbow", at: 10),
            "u2": "sunset",
            "u3": ["at": Timestamp(date: time(30))] as [String: Any],
            "u4": ["kind": 1, "at": Timestamp(date: time(40))] as [String: Any],
            "u5": NSNull(),
        ]
        let decoded = SoratomoReactions.decode(input)
        XCTAssertEqual(decoded.byUser, ["u1": SoratomoReaction(kind: .rainbow, reactedAt: time(10))])
    }

    func testDecodeKeepsReactionWhenTimeIsMissingOrNotTimestamp() {
        // 時刻が読めなくてもリアクションは数える（時刻は nil）
        let input: [String: Any] = [
            "u1": raw("sparkles", at: nil),
            "u2": ["kind": "cloud", "at": "2026-10-20"] as [String: Any],
            "u3": ["kind": "eyes", "at": NSNull()] as [String: Any],
        ]
        let decoded = SoratomoReactions.decode(input)
        XCTAssertEqual(decoded.byUser, [
            "u1": SoratomoReaction(kind: .sparkles, reactedAt: nil),
            "u2": SoratomoReaction(kind: .cloud, reactedAt: nil),
            "u3": SoratomoReaction(kind: .eyes, reactedAt: nil),
        ])
    }

    func testSkyDefaultsToEmptyReactions() {
        // 既存の SoratomoSky(...) の呼び出し（reactions を渡さない形）は 0 件になる
        let sky = SoratomoSky(
            id: "s1", groupId: "g1", authorId: "a1", caption: nil,
            pixelWidth: 100, pixelHeight: 100, createdAt: time(0)
        )
        XCTAssertEqual(sky.reactions, .empty)
    }

    // MARK: - make: 数と並び

    func testCountsFollowEmojiOrderNotCountOrder() {
        // 数の多い順（虹 3・青いハート 2・夕焼け 1）ではなく、絵文字の並び順
        let summary = SoratomoReactionSummary.make(
            reactions: reactions([
                "u1": (.sunset, 1),
                "u2": (.rainbow, 2), "u3": (.rainbow, 3), "u4": (.rainbow, 4),
                "u5": (.blueHeart, 5), "u6": (.blueHeart, 6),
            ]),
            myUid: nil, myOverride: nil, blockedUserIds: []
        )
        XCTAssertEqual(summary.counts, [count(.sunset, 1), count(.rainbow, 3), count(.blueHeart, 2)])
        XCTAssertEqual(summary.total, 6)
    }

    func testEmptyReactionsGiveNoCounts() {
        let summary = SoratomoReactionSummary.make(
            reactions: .empty, myUid: "me", myOverride: nil, blockedUserIds: []
        )
        XCTAssertEqual(summary.counts, [])
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.reactors, [])
        XCTAssertNil(summary.myKind)
    }

    func testMyKindMarksOwnReaction() {
        let server = reactions(["me": (.cloud, 1), "u1": (.sunset, 2)])

        let mine = SoratomoReactionSummary.make(reactions: server, myUid: "me", myOverride: nil, blockedUserIds: [])
        XCTAssertEqual(mine.myKind, .cloud)

        // 自分が付けていない投稿・ログアウト中は印なし
        let other = SoratomoReactionSummary.make(reactions: server, myUid: "u9", myOverride: nil, blockedUserIds: [])
        XCTAssertNil(other.myKind)
        let signedOut = SoratomoReactionSummary.make(reactions: server, myUid: nil, myOverride: nil, blockedUserIds: [])
        XCTAssertNil(signedOut.myKind)
        XCTAssertEqual(signedOut.total, 2)
    }

    func testAuthorKeyIsCounted() {
        // 投稿者本人のキーは保存されない決まりだが、万一あっても数える（make は投稿者を知らない・design.md）
        let summary = SoratomoReactionSummary.make(
            reactions: reactions(["author1": (.eyes, 1), "u1": (.eyes, 2)]),
            myUid: "author1", myOverride: nil, blockedUserIds: []
        )
        XCTAssertEqual(summary.counts, [count(.eyes, 2)])
        XCTAssertEqual(summary.myKind, .eyes)
        XCTAssertEqual(summary.reactors.map(\.id), ["u1", "author1"])
    }

    // MARK: - make: ブロック

    func testBlockedReactorsAreExcludedFromCountsTotalAndList() {
        // u2・u3 をブロックしている人の画面（要件 5.1）
        let server = reactions([
            "u1": (.sunset, 1),
            "u2": (.sunset, 2),
            "u3": (.rainbow, 3),
            "u4": (.eyes, 4),
        ])
        let summary = SoratomoReactionSummary.make(
            reactions: server, myUid: "me", myOverride: nil, blockedUserIds: ["u2", "u3"]
        )
        XCTAssertEqual(summary.counts, [count(.sunset, 1), count(.eyes, 1)])
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.reactors.map(\.id), ["u4", "u1"])

        // ブロックしていない人の画面では含める（要件 5.3）
        let unblocked = SoratomoReactionSummary.make(
            reactions: server, myUid: "me", myOverride: nil, blockedUserIds: []
        )
        XCTAssertEqual(unblocked.counts, [count(.sunset, 2), count(.rainbow, 1), count(.eyes, 1)])
        XCTAssertEqual(unblocked.total, 4)
        XCTAssertEqual(unblocked.reactors.map(\.id), ["u4", "u3", "u2", "u1"])
    }

    func testBlockedListNeverRemovesMe() {
        // 自分の uid がブロックの一覧に入っていても（ふつうは起きない）、自分の分は残す
        let summary = SoratomoReactionSummary.make(
            reactions: reactions(["me": (.rainbow, 1), "u1": (.rainbow, 2)]),
            myUid: "me", myOverride: nil, blockedUserIds: ["me"]
        )
        XCTAssertEqual(summary.counts, [count(.rainbow, 2)])
        XCTAssertEqual(summary.myKind, .rainbow)
    }

    // MARK: - make: 自分の上書き

    func testOverrideSetReplacesMyServerReaction() {
        // サーバーでは自分は夕焼け。虹を選び直して送っている間・確定の直後（要件 1.9）
        let summary = SoratomoReactionSummary.make(
            reactions: reactions(["me": (.sunset, 5), "u1": (.sunset, 1), "u2": (.rainbow, 2)]),
            myUid: "me", myOverride: .set(.rainbow), blockedUserIds: []
        )
        XCTAssertEqual(summary.counts, [count(.sunset, 1), count(.rainbow, 2)])
        XCTAssertEqual(summary.myKind, .rainbow)
        XCTAssertEqual(summary.total, 3)
        // 一覧の中の自分の行は、新しい絵文字で、サーバーの時刻のまま（位置を動かさない）
        XCTAssertEqual(summary.reactors.first, SoratomoReactorEntry(id: "me", kind: .rainbow, reactedAt: time(5)))
    }

    func testOverrideSetAddsWhenIHaveNoServerReaction() {
        // まだサーバーに自分の分が無い（付ける要求を送っている間）
        let summary = SoratomoReactionSummary.make(
            reactions: reactions(["u1": (.eyes, 1)]),
            myUid: "me", myOverride: .set(.eyes), blockedUserIds: []
        )
        XCTAssertEqual(summary.counts, [count(.eyes, 2)])
        XCTAssertEqual(summary.myKind, .eyes)
        // 時刻が無いので一覧の最後
        XCTAssertEqual(summary.reactors, [
            SoratomoReactorEntry(id: "u1", kind: .eyes, reactedAt: time(1)),
            SoratomoReactorEntry(id: "me", kind: .eyes, reactedAt: nil),
        ])
    }

    func testOverrideRemovedHidesMyServerReaction() {
        // サーバーではまだ付いているが、外す要求を送っている間
        let summary = SoratomoReactionSummary.make(
            reactions: reactions(["me": (.redHeart, 3), "u1": (.redHeart, 1), "u2": (.blueHeart, 2)]),
            myUid: "me", myOverride: .removed, blockedUserIds: []
        )
        XCTAssertEqual(summary.counts, [count(.redHeart, 1), count(.blueHeart, 1)])
        XCTAssertNil(summary.myKind)
        XCTAssertEqual(summary.reactors.map(\.id), ["u2", "u1"])
    }

    func testOverrideIsIgnoredWhenSignedOut() {
        // ログアウト中（uid が無い）は上書きを使わない
        let summary = SoratomoReactionSummary.make(
            reactions: reactions(["u1": (.sunset, 1)]),
            myUid: nil, myOverride: .set(.rainbow), blockedUserIds: []
        )
        XCTAssertEqual(summary.counts, [count(.sunset, 1)])
        XCTAssertNil(summary.myKind)
    }

    // MARK: - make: 一覧

    func testReactorCountEqualsTotal() {
        // 一覧の人数＝数の合計（要件 3.6）。ブロック・上書きが入っても崩れない
        let server = reactions([
            "me": (.sunset, 1), "u1": (.sunset, 2), "u2": (.cloud, 3), "u3": (.sparkles, nil), "u4": (.eyes, 4),
        ])
        let cases: [(String, SoratomoReactionOverride?, Set<String>, Int)] = [
            ("そのまま", nil, [], 5),
            ("ブロック", nil, ["u2", "u4"], 3),
            ("選び直し", .set(.blueHeart), [], 5),
            ("外す", .removed, ["u1"], 3),
        ]
        for (label, override, blocked, expectedTotal) in cases {
            let summary = SoratomoReactionSummary.make(
                reactions: server, myUid: "me", myOverride: override, blockedUserIds: blocked
            )
            XCTAssertEqual(summary.total, expectedTotal, label)
            XCTAssertEqual(summary.reactors.count, summary.total, label)
            XCTAssertEqual(summary.counts.reduce(0) { $0 + $1.count }, summary.total, label)
        }
    }

    func testReactorsAreNewestFirstThenUidOrder() {
        // 新しい順。同じ時刻どうしは uid の順。時刻の無いものは最後に uid の順
        let summary = SoratomoReactionSummary.make(
            reactions: reactions([
                "b": (.sunset, 20),
                "a": (.rainbow, 20),
                "c": (.eyes, 30),
                "e": (.cloud, nil),
                "d": (.sparkles, nil),
                "f": (.redHeart, 10),
            ]),
            myUid: nil, myOverride: nil, blockedUserIds: []
        )
        XCTAssertEqual(summary.reactors.map(\.id), ["c", "a", "b", "f", "d", "e"])
        XCTAssertEqual(summary.reactors.first, SoratomoReactorEntry(id: "c", kind: .eyes, reactedAt: time(30)))
    }

    // MARK: - accessibilityLabel

    func testAccessibilityLabelReadsCountsAndMine() {
        let summary = SoratomoReactionSummary.make(
            reactions: reactions([
                "me": (.sunset, 1), "u1": (.sunset, 2), "u2": (.sunset, 3), "u3": (.rainbow, 4),
            ]),
            myUid: "me", myOverride: nil, blockedUserIds: []
        )
        XCTAssertEqual(summary.accessibilityLabel, "リアクション、夕焼け3人、虹1人。あなたは夕焼けを付けています")
    }

    func testAccessibilityLabelWithoutMine() {
        let summary = SoratomoReactionSummary.make(
            reactions: reactions(["u1": (.cloud, 1), "u2": (.redHeart, 2), "u3": (.blueHeart, 3)]),
            myUid: "me", myOverride: nil, blockedUserIds: []
        )
        XCTAssertEqual(summary.accessibilityLabel, "リアクション、くも1人、赤いハート1人、青いハート1人")
    }

    func testAccessibilityLabelWhenEmpty() {
        let summary = SoratomoReactionSummary.make(
            reactions: .empty, myUid: "me", myOverride: nil, blockedUserIds: []
        )
        XCTAssertEqual(summary.accessibilityLabel, "リアクションなし")
    }
}
