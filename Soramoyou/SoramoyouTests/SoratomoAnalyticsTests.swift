//
//  SoratomoAnalyticsTests.swift
//  SoramoyouTests
//
//  そらともの計測（SoratomoEvent・SoratomoScreen と理由の写し方）のテスト ⭐️（tasks 10.2・release-gate 8）
//
//  期待値は requirements.md の要件 14 の表を写したもの。表を変えたら、ここも同時に変えること。
//  release-gate で足したものは .kiro/specs/soratomo-release-gate/requirements.md の要件 15 の表を写したもの。
//

@testable import Soramoyou
import XCTest

final class SoratomoAnalyticsTests: XCTestCase {
    // MARK: - 17 イベントの名前とパラメータ

    /// 要件 14 の表の 17 イベント（1 つずつ値を入れた例）と、期待する名前・パラメータ
    private let table: [(event: SoratomoEvent, name: String, parameters: [String: SoratomoAnalyticsValue])] = [
        (.opened(groupCount: 3), "soratomo_opened", ["group_count": .int(3)]),
        (.groupCreated, "soratomo_group_created", [:]),
        (.createFailed(.userLimit), "soratomo_create_failed", ["reason": .value("user_limit")]),
        (.inviteShared(.shareSheet), "soratomo_invite_shared", ["method": .value("share_sheet")]),
        (
            .groupJoined(alreadyMember: true), "soratomo_group_joined",
            ["source": .value("code"), "already_member": .bool(true)]
        ),
        (.joinFailed(.groupFull), "soratomo_join_failed", ["reason": .value("group_full")]),
        (
            .postCreated(hasCaption: false, durationMs: 4321), "soratomo_post_created",
            ["has_caption": .bool(false), "duration_ms": .int(4321)]
        ),
        (
            .postFailed(stage: .upload, reason: .timeout), "soratomo_post_failed",
            ["stage": .value("upload"), "reason": .value("timeout")]
        ),
        (
            .notificationPromptResult(choice: .allow, granted: true), "soratomo_notification_prompt_result",
            ["choice": .value("allow"), "granted": .bool(true)]
        ),
        (
            .notificationOpened(.notMember), "soratomo_notification_opened",
            ["type": .value("post_created"), "result": .value("not_member")]
        ),
        (.inviteCodeRegenerated, "soratomo_invite_code_regenerated", [:]),
        (.inviteRegenerateFailed(.notOwner), "soratomo_invite_regenerate_failed", ["reason": .value("not_owner")]),
        (.postDeleted(imageCleanup: .failed), "soratomo_post_deleted", ["image_cleanup": .value("failed")]),
        (.postDeleteFailed(.network), "soratomo_post_delete_failed", ["reason": .value("network")]),
        (.displayNameSaved(trigger: .join), "soratomo_display_name_saved", ["trigger": .value("join")]),
        (.displayNameFailed(.invalidLength), "soratomo_display_name_failed", ["reason": .value("invalid_length")]),
        (.membersViewed(memberCount: 20), "soratomo_members_viewed", ["member_count": .int(20)]),
    ]

    func testSeventeenEventsHaveFixedNamesAndParameters() {
        XCTAssertEqual(table.count, 17)
        for row in table {
            XCTAssertEqual(row.event.name, row.name)
            XCTAssertEqual(row.event.parameters, row.parameters, "\(row.name) のパラメータが表と違う")
        }
        // 名前は重複しない
        XCTAssertEqual(Set(table.map(\.name)).count, 17)
    }

    // MARK: - release-gate の 4 イベントの名前とパラメータ（release-gate 要件 15.1 の表）

    /// release-gate 要件 15.1 の表の 4 イベント（1 つずつ値を入れた例）と、期待する名前・パラメータ
    private let releaseGateTable: [(event: SoratomoEvent, name: String, parameters: [String: SoratomoAnalyticsValue])] = [
        (
            .reportSubmitted(reason: .harassment, source: .timeline), "soratomo_report_submitted",
            ["report_reason": .value("harassment"), "source": .value("timeline")]
        ),
        (.reportFailed(.notFound), "soratomo_report_failed", ["reason": .value("not_found")]),
        (.userBlocked(source: .detail), "soratomo_user_blocked", ["source": .value("detail")]),
        (
            .guidelineResult(choice: .decline, trigger: .entry, version: 1), "soratomo_guideline_result",
            ["choice": .value("decline"), "trigger": .value("entry"), "version": .int(1)]
        ),
    ]

    func testReleaseGateEventsHaveFixedNamesAndParameters() {
        XCTAssertEqual(releaseGateTable.count, 4)
        for row in releaseGateTable {
            XCTAssertEqual(row.event.name, row.name)
            XCTAssertEqual(row.event.parameters, row.parameters, "\(row.name) のパラメータが表と違う")
        }
        // 既存の 17 個と合わせても名前は重複しない
        XCTAssertEqual(Set((table + releaseGateTable).map(\.name)).count, 21)
    }

    func testNamesAndParameterKeysAreLowerSnakeCase() {
        // 要件 14.2: 英小文字のスネークケース。そらとものイベントは soratomo_ で始める
        let pattern = try! NSRegularExpression(pattern: "^[a-z]+(_[a-z]+)*$")
        func isSnakeCase(_ text: String) -> Bool {
            pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        for row in table + releaseGateTable {
            XCTAssertTrue(row.name.hasPrefix("soratomo_"), row.name)
            XCTAssertTrue(isSnakeCase(row.name), row.name)
            for key in row.event.parameters.keys {
                XCTAssertTrue(isSnakeCase(key), "\(row.name) のパラメータ名 \(key)")
            }
        }
    }

    // MARK: - 列挙の値（要件 14 の表）

    func testEnumValuesMatchRequirementTable() {
        XCTAssertEqual(
            SoratomoCreateFailReason.allCases.map(\.rawValue),
            ["user_limit", "invalid_name", "network", "flag_off", "unknown", "ng_word", "suspended", "consent_required"]
        )
        XCTAssertEqual(
            SoratomoJoinFailReason.allCases.map(\.rawValue),
            [
                "invalid_format", "not_found", "group_full", "user_limit", "network", "flag_off", "unknown",
                "suspended", "consent_required",
            ]
        )
        XCTAssertEqual(SoratomoPostFailStage.allCases.map(\.rawValue), ["precheck", "image", "upload", "save"])
        XCTAssertEqual(
            SoratomoPostFailReason.allCases.map(\.rawValue),
            [
                "offline", "daily_limit", "network", "unreadable", "too_large", "permission", "timeout", "background",
                "unknown", "ng_word",
            ]
        )
        XCTAssertEqual(SoratomoInviteShareMethod.allCases.map(\.rawValue), ["share_sheet", "copy"])
        XCTAssertEqual(SoratomoRegenerateFailReason.allCases.map(\.rawValue), ["not_owner", "network", "unknown"])
        XCTAssertEqual(SoratomoImageCleanup.allCases.map(\.rawValue), ["deleted", "failed"])
        XCTAssertEqual(SoratomoDeleteFailReason.allCases.map(\.rawValue), ["network", "unknown"])
        XCTAssertEqual(SoratomoDisplayNameTrigger.allCases.map(\.rawValue), ["create", "join"])
        XCTAssertEqual(SoratomoDisplayNameFailReason.allCases.map(\.rawValue), ["invalid_length", "network", "unknown"])
        XCTAssertEqual(SoratomoPrimerChoice.allCases.map(\.rawValue), ["allow", "later"])
        XCTAssertEqual(
            SoratomoNotificationOpenResult.allCases.map(\.rawValue),
            ["opened", "not_member", "flag_off", "signed_out"]
        )
        // release-gate 要件 15.1 の表の値（通報の理由は既存のルートの通報と同じ 5 つ・要件 5.3）
        XCTAssertEqual(
            ReportReason.allCases.map(\.rawValue),
            ["inappropriate", "spam", "harassment", "copyright", "other"]
        )
        XCTAssertEqual(SoratomoModerationSource.allCases.map(\.rawValue), ["detail", "timeline"])
        XCTAssertEqual(SoratomoReportFailReason.allCases.map(\.rawValue), ["network", "not_found", "unknown"])
        XCTAssertEqual(SoratomoGuidelineChoice.allCases.map(\.rawValue), ["agree", "decline"])
        XCTAssertEqual(SoratomoGuidelineTrigger.allCases.map(\.rawValue), ["create", "join", "entry"])
    }

    // MARK: - 画面名（要件 14.5・release-gate 要件 15.3）

    func testScreenNames() {
        XCTAssertEqual(
            SoratomoScreen.allCases.map(\.rawValue),
            [
                "そらともグループ一覧", "そらともタイムライン", "そらとも投稿", "そらとも招待", "そらともメンバー一覧", "そらとも投稿詳細",
                "そらともガイドライン",
            ]
        )
    }

    // MARK: - 失敗の種類 → 理由（表に無い組み合わせは unknown）

    /// 表に書いた組み合わせ以外は、すべて unknown になることを全種類で確かめる
    private func assertMapping<Reason: Equatable>(
        _ expected: [SoratomoError: Reason],
        unknown: Reason,
        _ map: (SoratomoError) -> Reason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for error in SoratomoError.allCases {
            XCTAssertEqual(map(error), expected[error] ?? unknown, "\(error)", file: file, line: line)
        }
    }

    func testCreateFailReasonMapping() {
        assertMapping(
            [
                .userLimit: .userLimit, .invalidName: .invalidName, .network: .network, .flagOff: .flagOff,
                // release-gate 要件 15.2。アプリが古いときも、サーバーが拒否した理由は consent_required
                .ngWord: .ngWord, .suspended: .suspended, .consentRequired: .consentRequired, .outdatedApp: .consentRequired,
            ],
            unknown: SoratomoCreateFailReason.unknown,
            SoratomoCreateFailReason.init
        )
    }

    func testJoinFailReasonMapping() {
        assertMapping(
            [
                .invalidFormat: .invalidFormat, .notFound: .notFound, .groupFull: .groupFull,
                .userLimit: .userLimit, .network: .network, .flagOff: .flagOff,
                // release-gate 要件 15.2。参加には NG ワードの検査が無い（ng_word は作成と投稿だけ）
                .suspended: .suspended, .consentRequired: .consentRequired, .outdatedApp: .consentRequired,
            ],
            unknown: SoratomoJoinFailReason.unknown,
            SoratomoJoinFailReason.init
        )
    }

    func testRegenerateDeleteAndDisplayNameReasonMapping() {
        assertMapping(
            [.notOwner: .notOwner, .network: .network],
            unknown: SoratomoRegenerateFailReason.unknown,
            SoratomoRegenerateFailReason.init
        )
        assertMapping([.network: .network], unknown: SoratomoDeleteFailReason.unknown, SoratomoDeleteFailReason.init)
        assertMapping(
            [.displayNameInvalid: .invalidLength, .network: .network],
            unknown: SoratomoDisplayNameFailReason.unknown,
            SoratomoDisplayNameFailReason.init
        )
    }

    func testPostFailReasonMappingAfterPrecheck() {
        // 事前確認を通った後（image・upload・save）は、通信の失敗を network にする
        for stage in [SoratomoPostFailStage.image, .upload, .save] {
            assertMapping(
                [
                    .network: .network, .dailyLimit: .dailyLimit, .imageUnreadable: .unreadable,
                    .imageTooLarge: .tooLarge, .permissionDenied: .permission, .uploadTimeout: .timeout,
                    .backgroundExpired: .background,
                    // release-gate 要件 15.2
                    .ngWord: .ngWord,
                ],
                unknown: SoratomoPostFailReason.unknown
            ) { SoratomoPostFailReason(stage: stage, error: $0) }
        }
    }

    func testReportFailReasonMapping() {
        // release-gate 要件 15.1: 投稿がもう無いときは not_found
        assertMapping(
            [.network: .network, .skyGone: .notFound],
            unknown: SoratomoReportFailReason.unknown,
            SoratomoReportFailReason.init
        )
    }

    func testPostFailReasonOfflineOnlyAtPrecheck() {
        // 事前確認で通信が無いときだけ offline。日次件数の上限は daily_limit
        XCTAssertEqual(SoratomoPostFailReason(stage: .precheck, error: .network), .offline)
        XCTAssertEqual(SoratomoPostFailReason(stage: .precheck, error: .dailyLimit), .dailyLimit)
        XCTAssertEqual(SoratomoPostFailReason(stage: .save, error: .network), .network)
        // 表に無い組み合わせ（投稿の flagOff・notMember）は unknown
        XCTAssertEqual(SoratomoPostFailReason(stage: .save, error: .flagOff), .unknown)
        XCTAssertEqual(SoratomoPostFailReason(stage: .save, error: .notMember), .unknown)
    }

    // MARK: - 送る形

    func testLoggingValueKeepsTypes() {
        // Firebase Analytics と PostHog へは、文字列・整数・真偽値のまま渡す（既存の push_pref_changed と同じ）
        XCTAssertEqual(SoratomoAnalyticsValue.value("copy").loggingValue as? String, "copy")
        XCTAssertEqual(SoratomoAnalyticsValue.int(7).loggingValue as? Int, 7)
        XCTAssertEqual(SoratomoAnalyticsValue.bool(true).loggingValue as? Bool, true)
    }
}
