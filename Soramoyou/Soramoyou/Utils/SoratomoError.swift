//
//  SoratomoError.swift
//  Soramoyou
//
//  そらとも（友達グループで空を共有）の失敗の種類と、画面に出す固定の文言 ⭐️
//  （tasks 10.2・design.md の Error Handling・要件 12.5・15.1・15.4）
//

import Foundation

/// そらともの失敗の種類
///
/// サービスの境界（tasks 11.x）で Firebase のエラーをこの型に写し、ViewModel はこの型だけを扱う。
/// 画面の文言は `userMessage` だけから出し、サーバーの文言や内部のエラーコードは画面に出さない（要件 12.5）。
/// 計測の理由（`soratomo_*_failed` の `reason`）への写し方は SoratomoAnalytics.swift にある。
enum SoratomoError: Error, Equatable, CaseIterable {
    /// 通信できない・届かない
    case network
    /// 機能フラグ（クレーム soratomoBeta）が無い
    case flagOff
    /// グループ名が 1〜30 文字でない
    case invalidName
    /// 招待コードの形が違う（正規化して 8 文字にならない）
    case invalidFormat
    /// 招待コードに一致するグループが無い
    case notFound
    /// グループが満員（20 人）
    case groupFull
    /// 参加できるグループの上限（10 個）
    case userLimit
    /// 招待コードの再発行をオーナー以外が行った
    case notOwner
    /// グループのメンバーでない（読めない・グループが無い）
    case notMember
    /// 1 日の投稿の上限（1 つのグループにつき 20 件）
    case dailyLimit
    /// キャプションが 100 文字を超えている
    case captionTooLong
    /// 表示名が 1〜20 文字でない
    case displayNameInvalid
    /// 写真を読めない
    case imageUnreadable
    /// 写真が大きすぎて送れない
    case imageTooLarge
    /// 画像のアップロードが制限時間を超えた
    case uploadTimeout
    /// バックグラウンドの猶予が切れて送信を中止した
    case backgroundExpired
    /// ルールに拒否された
    case permissionDenied
    /// 上のどれでもない
    case unknown

    /// 画面に出す文言（利用者の入力を含めない固定の文言・design.md の Error Categories の表）
    ///
    /// ⚠️ 文字列の補間（`\(...)`）で入力を埋め込まないこと（要件 15.1）。
    ///    数字（30 文字・20 人など）は上限の定数と一致させる。
    var userMessage: String {
        switch self {
        case .network:
            "通信できませんでした。インターネットにつながる場所でもう一度お試しください"
        case .invalidName:
            "グループ名は1〜30文字で入力してください"
        case .invalidFormat:
            "招待コードは8文字です（例: ABCD-EFGH）"
        case .notFound:
            "招待コードが見つかりません"
        case .groupFull:
            "このグループは満員です（20人）"
        case .userLimit:
            "参加できるグループは10個までです"
        case .dailyLimit:
            "1日に投稿できるのは1つのグループにつき20件までです"
        case .notMember:
            "グループを開けませんでした"
        case .captionTooLong:
            // design.md の表に無いので、ほかの文字数の文言（invalidName など）と同じ形にした。
            // 投稿画面は 100 文字を超えている間は確定できない（要件 6.4）ので、通常はここまで来ない
            "キャプションは100文字までです"
        case .imageUnreadable:
            "この写真は使えません。別の写真を選んでください"
        case .imageTooLarge:
            "この写真は大きすぎて送れません"
        case .displayNameInvalid:
            "表示名は1〜20文字で入力してください"
        case .flagOff, .notOwner, .permissionDenied, .uploadTimeout, .backgroundExpired, .unknown:
            "うまくいきませんでした。時間をおいてもう一度お試しください"
        }
    }
}

// MARK: - 操作ごとの失敗の文言

/// 失敗したとき、種類ではなく「何ができなかったか」を出す操作
/// （design.md の Error Categories の表の下・要件 3.12・8.19・18.5）
///
/// この 3 つの操作は、通信できない場合を含めて、失敗したら操作の文言を出す。
/// `SoratomoError` の case にしないのは、計測の理由（`not_owner`・`network` など）を種類から写すため。
/// 操作の名前を case にすると、種類が消えて、計測の理由がすべて `unknown` に落ちる。
/// 例: 再発行の失敗 → 画面は `SoratomoFailedAction.regenerateInviteCode.userMessage`、
///     計測は `SoratomoRegenerateFailReason(from: error)`
enum SoratomoFailedAction: CaseIterable {
    /// 招待コードの再発行（表示中の招待コードは変えない・要件 3.12）
    case regenerateInviteCode
    /// 自分の投稿の削除（投稿はタイムラインに残す・要件 8.19）
    case deleteSky
    /// 表示名の保存（入力した表示名を残す・要件 18.5）。文字数の検証の失敗は `SoratomoError.displayNameInvalid` の文言
    case saveDisplayName

    /// 画面に出す文言（利用者の入力を含めない固定の文言）
    var userMessage: String {
        switch self {
        case .regenerateInviteCode:
            "招待コードを再発行できませんでした"
        case .deleteSky:
            "削除できませんでした"
        case .saveDisplayName:
            "表示名を保存できませんでした"
        }
    }
}

// MARK: - 失敗の記録

extension SoratomoError {
    /// 失敗を既存の非致命エラーの記録（`ErrorHandler.logError` → Crashlytics）に残す（要件 15.4）
    ///
    /// 文脈は `StaticString`（ソースに直接書いた文字列）しか受け取らない。
    /// 文字列の補間ができないので、グループ名・表示名・キャプション・招待コード・通知トークンを
    /// 文脈に混ぜられない（要件 15.1）。例: `SoratomoError.record(error, context: "soratomo.createGroup")`
    /// - Parameters:
    ///   - error: 記録するエラー（写す前の Firebase のエラーでもよい）
    ///   - context: 固定の文字列。`soratomo.` で始める
    static func record(_ error: Error, context: StaticString) {
        ErrorHandler.logError(error, context: context.description)
    }
}
