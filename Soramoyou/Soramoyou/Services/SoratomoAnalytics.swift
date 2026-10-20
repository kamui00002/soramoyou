//
//  SoratomoAnalytics.swift
//  Soramoyou
//
//  そらとも（友達グループで空を共有）の計測を型で表す ⭐️
//  （tasks 10.2・design.md の SoratomoAnalytics・要件 14.1〜14.5・15.1）
//
//  イベント名・パラメータ名・値は要件 14 の表と 1 対 1 で対応する。表を変えるときは、
//  SoratomoAnalyticsTests の期待値と requirements.md の表も同時に変えること。
//  release-gate 8 で足した値・イベント・画面名は、.kiro/specs/soratomo-release-gate/requirements.md の要件 15 の表と対応する。
//  leave-group 6 で足した値・イベントは、.kiro/specs/soratomo-leave-group/requirements.md の要件 12 の表と対応する。
//  soratomo-reactions 7.4 で足した値・イベント（リアクションの 4 個と、通知のタップの `type` の `reaction`）は、
//  .kiro/specs/soratomo-reactions/requirements.md の要件 15 の表と 15.5 と対応する。
//

import Foundation

// MARK: - パラメータの値（列挙の値・数値・真偽値だけ）

/// 計測のパラメータの値
///
/// 自由な文字列を入れる口を作らないため、文字列は各列挙型の `rawValue` からしか作らない（要件 14.4）。
/// グループ名・表示名・キャプション・招待コード・通知トークンは、型の上でパラメータに入らない。
enum SoratomoAnalyticsValue: Equatable {
    /// 列挙の値（要件 14 の表に書いた値だけ）
    case value(String)
    case int(Int)
    case bool(Bool)

    /// `LoggingService.logEvent` に渡す形
    var loggingValue: Any {
        switch self {
        case let .value(text): text
        case let .int(number): number
        case let .bool(flag): flag
        }
    }
}

// MARK: - 理由・方法などの列挙（要件 14 の表の値）

/// `soratomo_create_failed` の `reason`
enum SoratomoCreateFailReason: String, CaseIterable {
    case userLimit = "user_limit", invalidName = "invalid_name", network, flagOff = "flag_off", unknown
    /// release-gate 要件 15.2 で足した値（既存の値と並びは変えない）
    case ngWord = "ng_word", suspended, consentRequired = "consent_required"

    /// 失敗の種類から理由を決める（表に無い組み合わせは unknown・design.md の Error Categories）
    init(_ error: SoratomoError) {
        switch error {
        case .userLimit: self = .userLimit
        case .invalidName: self = .invalidName
        case .network: self = .network
        case .flagOff: self = .flagOff
        case .ngWord: self = .ngWord
        case .suspended: self = .suspended
        // アプリが古いときも、サーバーが拒否した理由は consent_required（要件 15.2 の値を増やさない・design.md）
        case .consentRequired, .outdatedApp: self = .consentRequired
        default: self = .unknown
        }
    }
}

/// `soratomo_join_failed` の `reason`
enum SoratomoJoinFailReason: String, CaseIterable {
    case invalidFormat = "invalid_format", notFound = "not_found", groupFull = "group_full"
    case userLimit = "user_limit", network, flagOff = "flag_off", unknown
    /// release-gate 要件 15.2 で足した値（既存の値と並びは変えない。参加には NG ワードの検査が無い）
    case suspended, consentRequired = "consent_required"
    /// leave-group 要件 12.3 で足した値（抜けたときの片づけが終わっていない。既存の値と並びは変えない）
    case leavePending = "leave_pending"

    /// 失敗の種類から理由を決める（表に無い組み合わせは unknown）
    init(_ error: SoratomoError) {
        switch error {
        case .invalidFormat: self = .invalidFormat
        case .notFound: self = .notFound
        case .groupFull: self = .groupFull
        case .userLimit: self = .userLimit
        case .network: self = .network
        case .flagOff: self = .flagOff
        case .suspended: self = .suspended
        // 作成と同じく、アプリが古いときは consent_required として数える
        case .consentRequired, .outdatedApp: self = .consentRequired
        case .leavePending: self = .leavePending
        default: self = .unknown
        }
    }
}

/// `soratomo_post_failed` の `stage`
enum SoratomoPostFailStage: String, CaseIterable {
    /// 送信前の確認（通信の有無・日次件数）で止めた
    case precheck
    /// 画像の変換
    case image
    /// 画像のアップロード
    case upload
    /// 投稿のデータの保存
    case save
}

/// `soratomo_post_failed` の `reason`
enum SoratomoPostFailReason: String, CaseIterable {
    case offline, dailyLimit = "daily_limit"
    case network, unreadable, tooLarge = "too_large", permission, timeout, background, unknown
    /// release-gate 要件 15.2 で足した値（既存の値と並びは変えない）
    case ngWord = "ng_word"

    /// 失敗した段階と種類から理由を決める（design.md の Error Categories の下の注記）
    ///
    /// - 事前確認（precheck）で通信が無いときは `offline`。事前確認を通った後の通信の失敗は `network`
    /// - 表に無い組み合わせ（たとえば `flagOff`）は `unknown`
    init(stage: SoratomoPostFailStage, error: SoratomoError) {
        switch error {
        case .network: self = stage == .precheck ? .offline : .network
        case .dailyLimit: self = .dailyLimit
        case .imageUnreadable: self = .unreadable
        case .imageTooLarge: self = .tooLarge
        case .permissionDenied: self = .permission
        case .uploadTimeout: self = .timeout
        case .backgroundExpired: self = .background
        case .ngWord: self = .ngWord
        default: self = .unknown
        }
    }
}

/// `soratomo_invite_shared` の `method`
enum SoratomoInviteShareMethod: String, CaseIterable {
    case shareSheet = "share_sheet", copy
}

/// `soratomo_invite_regenerate_failed` の `reason`
enum SoratomoRegenerateFailReason: String, CaseIterable {
    case notOwner = "not_owner", network, unknown

    /// 失敗の種類から理由を決める（表に無い組み合わせは unknown）
    init(_ error: SoratomoError) {
        switch error {
        case .notOwner: self = .notOwner
        case .network: self = .network
        default: self = .unknown
        }
    }
}

/// `soratomo_post_deleted` の `image_cleanup`（投稿のデータを消した後の画像の削除の結果）
enum SoratomoImageCleanup: String, CaseIterable {
    case deleted, failed
}

/// `soratomo_post_delete_failed` の `reason`
enum SoratomoDeleteFailReason: String, CaseIterable {
    case network, unknown

    /// 失敗の種類から理由を決める（表に無い組み合わせは unknown）
    init(_ error: SoratomoError) {
        self = error == .network ? .network : .unknown
    }
}

/// `soratomo_display_name_saved` の `trigger`（どちらの操作から表示名の入力に来たか）
enum SoratomoDisplayNameTrigger: String, CaseIterable {
    case create, join
}

/// `soratomo_display_name_failed` の `reason`
enum SoratomoDisplayNameFailReason: String, CaseIterable {
    case invalidLength = "invalid_length", network, unknown

    /// 失敗の種類から理由を決める（表に無い組み合わせは unknown）
    init(_ error: SoratomoError) {
        switch error {
        case .displayNameInvalid: self = .invalidLength
        case .network: self = .network
        default: self = .unknown
        }
    }
}

/// 通知の事前説明で選んだ操作（`soratomo_notification_prompt_result` の `choice`）
///
/// 事前説明の窓口（`SoratomoNotificationPrimer`・tasks 12.2）もこの型を使う。
enum SoratomoPrimerChoice: String, CaseIterable {
    /// 「通知を受け取る」
    case allow
    /// 「あとで」
    case later
}

/// 通知のタップの結果（`soratomo_notification_opened` の `result`）
///
/// 遷移を決めるルーター（`SoratomoRouter`・tasks 12.1）もこの型を使う。
enum SoratomoNotificationOpenResult: String, CaseIterable {
    case opened, notMember = "not_member", flagOff = "flag_off", signedOut = "signed_out"
}

/// 通報・ブロックをした画面（`soratomo_report_submitted`・`soratomo_user_blocked` の `source`・release-gate 要件 15.1）
///
/// 通報とブロックのサービス（release-gate 9.2）とタイムライン（10.1）もこの型を使う。
enum SoratomoModerationSource: String, CaseIterable {
    /// 投稿詳細の「…」のメニュー
    case detail
    /// タイムラインの長押しのメニュー
    case timeline
}

/// `soratomo_report_failed` の `reason`（release-gate 要件 15.1）
enum SoratomoReportFailReason: String, CaseIterable {
    case network, notFound = "not_found", unknown

    /// 失敗の種類から理由を決める（表に無い組み合わせは unknown）
    init(_ error: SoratomoError) {
        switch error {
        case .network: self = .network
        case .skyGone: self = .notFound
        default: self = .unknown
        }
    }
}

/// ガイドラインの全文を出したきっかけ（`soratomo_guideline_result` の `trigger`・release-gate 要件 15.1）
///
/// 作成と参加の同意の段（release-gate 10.4）と入口（10.5）もこの型を使う。
enum SoratomoGuidelineTrigger: String, CaseIterable {
    case create, join, entry
}

/// ガイドラインの全文で選んだ操作（`soratomo_guideline_result` の `choice`・release-gate 要件 15.1）
enum SoratomoGuidelineChoice: String, CaseIterable {
    /// 「同意する」
    case agree
    /// 「同意しない」
    case decline
}

/// 抜ける前の役割（`soratomo_group_left` の `role`・leave-group 要件 12.1）
enum SoratomoLeaveRole: String, CaseIterable {
    case owner, member
}

/// `soratomo_leave_failed` の `reason`（leave-group 要件 12.1）
///
/// 抜けるのサービスの失敗（leave-group 7.1 の `SoratomoLeaveError`）からの写し方は、抜けるの ViewModel（8.1）が決める。
/// 通信できない・制限時間切れは `network`、それ以外は `unknown`（design.md の Error Categories の表）。
enum SoratomoLeaveFailReason: String, CaseIterable {
    case network, unknown
}

/// 通知の種類（`soratomo_notification_opened` の `type`・soratomo-reactions 要件 15.5）
///
/// 遷移を決めるルーター（`SoratomoRouter`）が、タップされた通知の種類（`SoratomoNotificationKind`）から写す。
/// 新着投稿の `post_created` は 1.15.0 までと同じ値のまま（既存の集計を割らないため）。リアクションの通知は `reaction`。
enum SoratomoNotificationOpenType: String, CaseIterable {
    case postCreated = "post_created", reaction
}

/// `soratomo_reaction_failed` の `action`（soratomo-reactions 要件 15 の表）
///
/// 選び直し（別の絵文字に付け替える）の失敗も `add` にする（要件 15 の表）。
enum SoratomoReactionFailAction: String, CaseIterable {
    case add, remove
}

/// `soratomo_reaction_failed` の `reason`（soratomo-reactions 要件 15 の表）
///
/// `offline` は、送る前に通信が無いと分かって送らなかったとき。失敗の種類（`SoratomoError`）からは作らず、
/// 送る前の確認をする側（リアクションの ViewModel）が直接入れる。送った後の通信の失敗は `network`。
enum SoratomoReactionFailReason: String, CaseIterable {
    case offline, network, notFound = "not_found", notMember = "not_member", suspended, unknown

    /// 失敗の種類から理由を決める（表に無い組み合わせは unknown・design.md の SoratomoAnalytics（変更））
    ///
    /// 投稿がもう無い（`skyGone`）は `not_found`。招待コードの `notFound` とは別の種類なので、`notFound` は unknown になる。
    init(_ error: SoratomoError) {
        switch error {
        case .network: self = .network
        case .skyGone: self = .notFound
        case .notMember: self = .notMember
        case .suspended: self = .suspended
        default: self = .unknown
        }
    }
}

// MARK: - イベント（要件 14 の表の 17 個と、release-gate 要件 15.1 の表の 4 個と、leave-group 要件 12 の表の 2 個と、soratomo-reactions 要件 15 の表の 4 個）

/// そらともの計測イベント
enum SoratomoEvent: Equatable {
    /// そらともの入口からグループ一覧を開いた
    case opened(groupCount: Int)
    /// グループの作成に成功した
    case groupCreated
    /// グループの作成に失敗した
    case createFailed(SoratomoCreateFailReason)
    /// 招待の共有シートを開いた、またはコードをコピーした
    case inviteShared(SoratomoInviteShareMethod)
    /// 招待コードでの参加に成功した（`source` は v1 で "code" に固定）
    case groupJoined(alreadyMember: Bool)
    /// 参加に失敗した
    case joinFailed(SoratomoJoinFailReason)
    /// 投稿に成功した
    case postCreated(hasCaption: Bool, durationMs: Int)
    /// 投稿に失敗した
    case postFailed(stage: SoratomoPostFailStage, reason: SoratomoPostFailReason)
    /// 通知の事前説明で操作を選んだ
    case notificationPromptResult(choice: SoratomoPrimerChoice, granted: Bool)
    /// そらともの通知をタップした（`type` は通知の種類。新着投稿は "post_created"、リアクションは "reaction"）
    ///
    /// `type` は既定を新着投稿（`.postCreated`）にして、`.notificationOpened(.opened)` のような既存の書き方と値を
    /// そのまま通す（1.15.0 までの記録と同じ値・soratomo-reactions 要件 15.5）。
    case notificationOpened(SoratomoNotificationOpenResult, type: SoratomoNotificationOpenType = .postCreated)
    /// 招待コードの再発行に成功した
    case inviteCodeRegenerated
    /// 招待コードの再発行に失敗した
    case inviteRegenerateFailed(SoratomoRegenerateFailReason)
    /// 自分の投稿の削除に成功した
    case postDeleted(imageCleanup: SoratomoImageCleanup)
    /// 自分の投稿の削除に失敗した
    case postDeleteFailed(SoratomoDeleteFailReason)
    /// 表示名の事前入力で保存した
    case displayNameSaved(trigger: SoratomoDisplayNameTrigger)
    /// 表示名の保存に失敗した
    case displayNameFailed(SoratomoDisplayNameFailReason)
    /// メンバー一覧を開いた
    case membersViewed(memberCount: Int)
    /// 通報が受け付けられた（release-gate）
    case reportSubmitted(reason: ReportReason, source: SoratomoModerationSource)
    /// 通報に失敗した（release-gate）
    case reportFailed(SoratomoReportFailReason)
    /// ブロックが保存された（release-gate）
    case userBlocked(source: SoratomoModerationSource)
    /// ガイドラインの全文で操作を選んだ（release-gate。`version` はアプリの版 `SoratomoGuideline.currentVersion`）
    case guidelineResult(choice: SoratomoGuidelineChoice, trigger: SoratomoGuidelineTrigger, version: Int)
    /// グループを抜けた（leave-group。メンバーでなくなったと確かめて抜けた扱いにした場合を含む・要件 4.5）
    /// - `groupDeleted`: 最後の 1 人でグループごと消えた（消える）か
    /// - `completed`: アプリが片づけの完了まで確かめたか（偽なら残りは定期実行が終える）
    case groupLeft(role: SoratomoLeaveRole, groupDeleted: Bool, completed: Bool)
    /// グループを抜けられなかった（leave-group。メンバーのまま・要件 4.4）
    case leaveFailed(SoratomoLeaveFailReason)
    /// リアクションを付けた、または選び直した（soratomo-reactions。サーバーが受け付けたとき）
    /// - `kind`: 付けた絵文字。送るのは絵文字そのものでなく名前（`SoratomoReactionKind.rawValue`・要件 15.4）
    /// - `source`: 操作した画面（通報とブロックと同じ `timeline` / `detail`）
    /// - `replaced`: 別の絵文字からの選び直しか
    case reactionAdded(kind: SoratomoReactionKind, source: SoratomoModerationSource, replaced: Bool)
    /// 自分のリアクションを外した（soratomo-reactions。サーバーが受け付けたとき）
    case reactionRemoved(source: SoratomoModerationSource)
    /// 付ける・外す・選び直すに失敗した（soratomo-reactions。選び直しの失敗は `action: add`）
    case reactionFailed(action: SoratomoReactionFailAction, reason: SoratomoReactionFailReason)
    /// 押した人の一覧を開いた（soratomo-reactions。`reactionCount` は一覧の人数）
    case reactionsViewed(reactionCount: Int)

    /// イベント名（英小文字のスネークケース・`soratomo_` で始める・要件 14.2）
    var name: String {
        switch self {
        case .opened: "soratomo_opened"
        case .groupCreated: "soratomo_group_created"
        case .createFailed: "soratomo_create_failed"
        case .inviteShared: "soratomo_invite_shared"
        case .groupJoined: "soratomo_group_joined"
        case .joinFailed: "soratomo_join_failed"
        case .postCreated: "soratomo_post_created"
        case .postFailed: "soratomo_post_failed"
        case .notificationPromptResult: "soratomo_notification_prompt_result"
        case .notificationOpened: "soratomo_notification_opened"
        case .inviteCodeRegenerated: "soratomo_invite_code_regenerated"
        case .inviteRegenerateFailed: "soratomo_invite_regenerate_failed"
        case .postDeleted: "soratomo_post_deleted"
        case .postDeleteFailed: "soratomo_post_delete_failed"
        case .displayNameSaved: "soratomo_display_name_saved"
        case .displayNameFailed: "soratomo_display_name_failed"
        case .membersViewed: "soratomo_members_viewed"
        case .reportSubmitted: "soratomo_report_submitted"
        case .reportFailed: "soratomo_report_failed"
        case .userBlocked: "soratomo_user_blocked"
        case .guidelineResult: "soratomo_guideline_result"
        case .groupLeft: "soratomo_group_left"
        case .leaveFailed: "soratomo_leave_failed"
        case .reactionAdded: "soratomo_reaction_added"
        case .reactionRemoved: "soratomo_reaction_removed"
        case .reactionFailed: "soratomo_reaction_failed"
        case .reactionsViewed: "soratomo_reactions_viewed"
        }
    }

    /// パラメータ（パラメータ名は英小文字のスネークケース・要件 14.2）。無いイベントは空
    var parameters: [String: SoratomoAnalyticsValue] {
        switch self {
        case let .opened(groupCount):
            ["group_count": .int(groupCount)]
        case .groupCreated, .inviteCodeRegenerated:
            [:]
        case let .createFailed(reason):
            ["reason": .value(reason.rawValue)]
        case let .inviteShared(method):
            ["method": .value(method.rawValue)]
        case let .groupJoined(alreadyMember):
            // v1 の参加の経路は招待コードだけ（URL・リンクからの参加は対象外）
            ["source": .value("code"), "already_member": .bool(alreadyMember)]
        case let .joinFailed(reason):
            ["reason": .value(reason.rawValue)]
        case let .postCreated(hasCaption, durationMs):
            ["has_caption": .bool(hasCaption), "duration_ms": .int(durationMs)]
        case let .postFailed(stage, reason):
            ["stage": .value(stage.rawValue), "reason": .value(reason.rawValue)]
        case let .notificationPromptResult(choice, granted):
            ["choice": .value(choice.rawValue), "granted": .bool(granted)]
        case let .notificationOpened(result, type):
            // 通知の種類は、新着投稿（post_created・1.15.0 までと同じ値）とリアクション（reaction）（soratomo-reactions 要件 15.5）
            ["type": .value(type.rawValue), "result": .value(result.rawValue)]
        case let .inviteRegenerateFailed(reason):
            ["reason": .value(reason.rawValue)]
        case let .postDeleted(imageCleanup):
            ["image_cleanup": .value(imageCleanup.rawValue)]
        case let .postDeleteFailed(reason):
            ["reason": .value(reason.rawValue)]
        case let .displayNameSaved(trigger):
            ["trigger": .value(trigger.rawValue)]
        case let .displayNameFailed(reason):
            ["reason": .value(reason.rawValue)]
        case let .membersViewed(memberCount):
            ["member_count": .int(memberCount)]
        case let .reportSubmitted(reason, source):
            // 通報の理由は既存のルートの通報と同じ列挙の値（release-gate 要件 5.3）
            ["report_reason": .value(reason.rawValue), "source": .value(source.rawValue)]
        case let .reportFailed(reason):
            ["reason": .value(reason.rawValue)]
        case let .userBlocked(source):
            ["source": .value(source.rawValue)]
        case let .guidelineResult(choice, trigger, version):
            ["choice": .value(choice.rawValue), "trigger": .value(trigger.rawValue), "version": .int(version)]
        case let .groupLeft(role, groupDeleted, completed):
            // グループ名・引き継ぐ人の表示名は、型の上で入らない（leave-group 要件 12.4）
            ["role": .value(role.rawValue), "group_deleted": .bool(groupDeleted), "completed": .bool(completed)]
        case let .leaveFailed(reason):
            ["reason": .value(reason.rawValue)]
        case let .reactionAdded(kind, source, replaced):
            // 絵文字そのものでなく名前を送る（異体字セレクタの有無で、同じ絵文字が集計で割れないように・要件 15.4）。
            // uid・グループ ID・投稿 ID は、型の上で入らない（要件 15.3）
            ["kind": .value(kind.rawValue), "source": .value(source.rawValue), "replaced": .bool(replaced)]
        case let .reactionRemoved(source):
            ["source": .value(source.rawValue)]
        case let .reactionFailed(action, reason):
            ["action": .value(action.rawValue), "reason": .value(reason.rawValue)]
        case let .reactionsViewed(reactionCount):
            ["reaction_count": .int(reactionCount)]
        }
    }
}

// MARK: - 画面名（要件 14.5・release-gate 要件 15.3）

/// そらともの主要画面の名前（既存の画面計測 `logScreen` で日本語の画面名として記録する）
enum SoratomoScreen: String, CaseIterable {
    case groupList = "そらともグループ一覧"
    case timeline = "そらともタイムライン"
    case compose = "そらとも投稿"
    case invite = "そらとも招待"
    case members = "そらともメンバー一覧"
    case skyDetail = "そらとも投稿詳細"
    /// ガイドラインの全文（release-gate 要件 15.3。同意を求める形と読むだけの形の両方）
    case guideline = "そらともガイドライン"
}

// MARK: - 送信の窓口

/// そらともの計測の窓口
///
/// 既存の計測の窓口（`LoggingService`）から送るので、Firebase Analytics と PostHog の両方に届く（要件 14.1）。
/// - Note: アプリは Debug ビルドでも送る。テスト用アカウントの操作は集計のときに uid で除く。
enum SoratomoAnalytics {
    /// イベントを記録する
    /// - Parameter event: 記録するイベント
    static func log(_ event: SoratomoEvent) {
        let parameters = event.parameters
        LoggingService.shared.logEvent(
            event.name,
            parameters: parameters.isEmpty ? nil : parameters.mapValues(\.loggingValue)
        )
    }

    /// 画面の表示を記録する（表示のたびではなく、画面の切り替えで 1 回）
    /// - Parameter screen: 表示した画面
    static func screen(_ screen: SoratomoScreen) {
        LoggingService.shared.logScreen(screen.rawValue)
    }
}
