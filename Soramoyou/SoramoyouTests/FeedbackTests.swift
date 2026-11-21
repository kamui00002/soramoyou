//
//  FeedbackTests.swift
//  SoramoyouTests
//
//  Feedback モデルの Firestore マッピング・バリデーション検証
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

final class FeedbackTests: XCTestCase {
    /// 必須キー（userId/message/createdAt）と任意項目がある場合に書き込まれる
    func testToFirestoreDataIncludesRequiredAndOptionalFields() {
        let feedback = Feedback(
            userId: "u1",
            message: "アプリ最高です",
            category: "request",
            appVersion: "1.7.4 (57)",
            deviceInfo: "iOS 18.5 / iPhone"
        )

        let data = feedback.toFirestoreData()

        XCTAssertEqual(data["userId"] as? String, "u1")
        XCTAssertEqual(data["message"] as? String, "アプリ最高です")
        XCTAssertNotNil(data["createdAt"]) // serverTimestamp sentinel
        XCTAssertEqual(data["category"] as? String, "request")
        XCTAssertEqual(data["appVersion"] as? String, "1.7.4 (57)")
        XCTAssertEqual(data["deviceInfo"] as? String, "iOS 18.5 / iPhone")
    }

    /// 必須キーは rules の hasAll(['userId','message','createdAt']) を満たす
    func testToFirestoreDataSatisfiesRulesRequiredKeys() {
        let data = Feedback(userId: "u1", message: "hi").toFirestoreData()
        for key in ["userId", "message", "createdAt"] {
            XCTAssertNotNil(data[key], "必須キー \(key) が欠落")
        }
    }

    /// 任意項目が nil のときはキーを書き込まない
    func testToFirestoreDataOmitsNilOptionalFields() {
        let data = Feedback(userId: "u1", message: "hi").toFirestoreData()
        XCTAssertNil(data["category"])
        XCTAssertNil(data["appVersion"])
        XCTAssertNil(data["deviceInfo"])
        XCTAssertNil(data["replyEmail"])
    }

    // MARK: - 返信用のメールアドレス

    /// 返信用のメールアドレス：値があれば書き、nil と空文字は書かない（Rules は "" を断るので、書くとご意見ごと失敗する）
    func testToFirestoreDataReplyEmail() {
        let withEmail = Feedback(userId: "u1", message: "hi", replyEmail: "sora@example.com").toFirestoreData()
        XCTAssertEqual(withEmail["replyEmail"] as? String, "sora@example.com")

        let nilEmail = Feedback(userId: "u1", message: "hi", replyEmail: nil).toFirestoreData()
        XCTAssertNil(nilEmail["replyEmail"])

        let emptyEmail = Feedback(userId: "u1", message: "hi", replyEmail: "").toFirestoreData()
        XCTAssertNil(emptyEmail["replyEmail"])
    }

    /// 長さの下限・上限は Rules・関数と同じ（3〜254）
    func testReplyEmailLengthLimitsMatchRulesAndFunctions() {
        XCTAssertEqual(Feedback.REPLY_EMAIL_MIN_LENGTH, 3)
        XCTAssertEqual(Feedback.REPLY_EMAIL_MAX_LENGTH, 254)
    }

    // ⚠️ 下の 3 本の表は functions/feedbackMail.test.js の「形（isValidReplyEmail）」の表をそのまま写したもの。
    //    Rules・関数・アプリで判定を同じにするため、片方を変えたらもう片方も直す。
    //    見えない文字は \u{…} で書く（生の文字で書くと、見えないまま食い違っても気づけないため）

    /// 形: 半角の見える文字だけの「…@….…」は通す（境目の 3 文字・254 文字も）
    func testIsValidReplyEmailAcceptsHalfWidthAddresses() {
        let longest = String(repeating: "a", count: 64) + "@" + String(repeating: "b", count: 185) + ".com"
        XCTAssertEqual(longest.utf16.count, 254)
        let ok = [
            "sora@example.com",
            "a.b+tag@sub.example.co.jp",
            "x_y-z@example.jp",
            "a@b.c", // いちばん短い形（5 文字）
            longest, // 254 文字ちょうど
        ]
        for value in ok {
            XCTAssertTrue(Feedback.isValidReplyEmail(value), value)
        }
    }

    /// 形: 長さ・@ の数・点の位置が合わないものは断る
    func testIsValidReplyEmailRejectsWrongLengthOrShape() {
        let tooLong = String(repeating: "a", count: 64) + "@" + String(repeating: "b", count: 186) + ".com"
        XCTAssertEqual(tooLong.utf16.count, 255)
        let ng = [
            "", // 空
            "ab", // 短すぎる
            tooLong, // 255 文字
            "sora.example.com", // @ が無い
            "a@@b.c", // @ が 2 つ
            "a@b@c.d", // @ が 2 つ
            "a@b", // @ の後ろに点が無い
            "a@b.", // 点の後ろが無い
            "@b.c", // @ の前が無い
            "a@.c", // @ と点の間が無い
        ]
        for value in ng {
            XCTAssertFalse(Feedback.isValidReplyEmail(value), value.debugDescription)
        }
    }

    /// 形: 改行・空白・制御文字・全角・見えない文字が 1 つでもあれば断る
    func testIsValidReplyEmailRejectsInvisibleOrFullWidthCharacters() {
        let ng = [
            "a@b.c\n", // 末尾の改行（NSRegularExpression の $ はこの手前でも一致する＝範囲まで見ないと通ってしまう）
            "a\n@b.c",
            "a@b.c\r",
            "a@b.c\r\nBcc: x@y.z", // ヘッダーの差し込みの形
            " a@b.c", // 前後の空白も削らない（削るのは ViewModel）
            "a@b.c ",
            "a b@c.d",
            "a\t@b.c",
            "a\u{0B}@b.c", // 垂直タブ
            "a\u{00}@b.c",
            "a\u{7F}@b.c",
            "a\u{3000}@b.c", // 全角の空白
            "\u{FF53}\u{FF4F}\u{FF52}\u{FF41}@example.com", // 全角の英字（ｓｏｒａ）
            "sora\u{FF20}example.com", // 全角の @
            "sora@example\u{FF0E}com", // 全角の点
            "a\u{A0}@b.c", // ノーブレークスペース
            "a\u{200B}@b.c", // ゼロ幅スペース
            "a\u{202E}@b.c", // 文字の向きを変える制御
            "a\u{2028}@b.c", // 行の区切り
            "a\u{FEFF}@b.c",
            "日本@例え.jp", // 半角以外の文字（2026-11-20 の決定で断る）
        ]
        for value in ng {
            XCTAssertFalse(Feedback.isValidReplyEmail(value), value.debugDescription)
        }
    }

    /// バリデーション: 空・空白のみは無効、通常文は有効、上限超過は無効
    func testIsValid() {
        XCTAssertTrue(Feedback(userId: "u1", message: "感想です").isValid)
        XCTAssertFalse(Feedback(userId: "u1", message: "").isValid)
        XCTAssertFalse(Feedback(userId: "u1", message: "   \n ").isValid)
        XCTAssertFalse(Feedback(userId: "u1", message: String(repeating: "あ", count: 1001)).isValid)
        XCTAssertTrue(Feedback(userId: "u1", message: String(repeating: "あ", count: 1000)).isValid)
    }
}
