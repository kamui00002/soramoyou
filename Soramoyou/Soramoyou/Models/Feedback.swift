//
//  Feedback.swift
//  Soramoyou
//
//  アプリ内フィードバック（ユーザー → Firestore `feedback` コレクション）
//  App Store レビュー任せにせず、アプリ内から不具合・要望を直接送れる導線。
//  読み取りは管理者のみ（Firebase コンソール）。
//

import FirebaseFirestore
import Foundation

/// フィードバックの種別（任意・送信時のトリアージ用）
enum FeedbackCategory: String, CaseIterable, Identifiable {
    case bug // 不具合
    case request // 要望
    case other // その他

    var id: String { rawValue }

    /// 画面表示名
    var displayName: String {
        switch self {
        case .bug: "不具合"
        case .request: "要望"
        case .other: "その他"
        }
    }
}

/// アプリ内フィードバック1件
struct Feedback: Identifiable {
    let id: String
    let userId: String
    let message: String
    /// 種別（`FeedbackCategory.rawValue`。任意）
    let category: String?
    /// 送信時のアプリバージョン（例 "1.7.4 (57)"。トラブル切り分け用・任意）
    let appVersion: String?
    /// 送信時の端末情報（例 "iOS 18.5 / iPhone"。任意）
    let deviceInfo: String?
    /// 返信用のメールアドレス（任意。欄に入力したときだけ。前後の空白は FeedbackViewModel が削ってから渡す）
    /// 空欄のときは、サーバーの関数（functions の mailFeedbackToSupport）が登録メールを返信先にする
    let replyEmail: String?

    init(
        id: String = UUID().uuidString,
        userId: String,
        message: String,
        category: String? = nil,
        appVersion: String? = nil,
        deviceInfo: String? = nil,
        replyEmail: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.message = message
        self.category = category
        self.appVersion = appVersion
        self.deviceInfo = deviceInfo
        self.replyEmail = replyEmail
    }

    /// 本文のバリデーション（1〜1000文字）。`firestore.rules` の上限と一致させること。
    var isValid: Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && message.count <= 1000
    }

    // MARK: - Firestore Mapping

    /// Firestore ドキュメントデータに変換。
    /// createdAt はサーバー時刻（reportPost と同方針）。
    /// キーは `firestore.rules` の `hasAll(['userId','message','createdAt'])` を必ず満たす。
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "userId": userId,
            "message": message,
            "createdAt": FieldValue.serverTimestamp(),
        ]
        // 任意項目は値があるときだけ書き込む（hasAll は追加キーを許容）
        if let category {
            data["category"] = category
        }
        if let appVersion {
            data["appVersion"] = appVersion
        }
        if let deviceInfo {
            data["deviceInfo"] = deviceInfo
        }
        // 返信用のメールアドレス：nil と空文字は書かない。
        // ⚠️ Rules（isValidReplyEmail）は "" を断る（3 文字以上）ので、空文字を書くとご意見そのものが送れなくなる
        if let replyEmail, !replyEmail.isEmpty {
            data["replyEmail"] = replyEmail
        }
        return data
    }

    // MARK: - 返信用のメールアドレスの形

    /// 返信用のメールアドレスの長さの下限・上限（UTF-16 の数。Rules の size() と同じ数え方）。
    /// ⚠️ firestore.rules の isValidReplyEmail・functions/feedbackMail.js の REPLY_EMAIL_MIN/MAX_LENGTH と同じにすること
    ///    （functions/feedbackMail.test.js の見張りがこの 2 行を読んで比べる）
    static let REPLY_EMAIL_MIN_LENGTH = 3
    static let REPLY_EMAIL_MAX_LENGTH = 254

    /// 返信用のメールアドレスの形。「@ 以外の半角の見える文字（! から ~）」だけの「…@….…」（2026-11-20 の決定）。
    /// 全角で打った・空白や改行や見えない文字が混ざったアドレスは断る。
    /// ⚠️ functions/feedbackMail.js の REPLY_EMAIL_PATTERN と 1 文字も違わない文字にすること（見張りがこの行を読んで比べる）。
    ///    raw 文字列（#"…"#）なので、バックスラッシュは JS の正規表現と同じく 1 個で書く
    static let REPLY_EMAIL_PATTERN = #"^[\x21-\x3F\x41-\x7E]+@[\x21-\x3F\x41-\x7E]+\.[\x21-\x3F\x41-\x7E]+$"#

    /// 返信用のメールアドレスとして使える形か。
    /// 前後の空白は削らない（削るのは FeedbackViewModel の役目。Rules と関数も削らずに確かめる）。
    /// - Parameter value: 確かめるアドレス
    /// - Returns: Rules と関数が通す形なら true
    static func isValidReplyEmail(_ value: String) -> Bool {
        // 長さは UTF-16 で数える（Rules の size()・JS の length と同じ単位）
        let length = value.utf16.count
        guard length >= REPLY_EMAIL_MIN_LENGTH, length <= REPLY_EMAIL_MAX_LENGTH else { return false }

        // NSRegularExpression も UTF-16 の単位で動く（JS・Rules と同じ）。
        // 呼ばれるのは送信のときだけなので、その場で作る（static に持つと並行処理の安全性の扱いが要るため）
        guard let regex = try? NSRegularExpression(pattern: REPLY_EMAIL_PATTERN) else { return false }
        let whole = NSRange(location: 0, length: length)
        guard let match = regex.firstMatch(in: value, options: [], range: whole) else { return false }
        // 一致した範囲が文字列の全体のときだけ通す。
        // ⚠️ ICU（NSRegularExpression の中身）の $ は末尾の改行の手前でも一致するので、範囲まで見ないと "a@b.c\n" を通してしまう
        return match.range == whole
    }
}
