//
//  WhatsNewGateTests.swift
//  SoramoyouTests
//
//  What's New（新機能紹介）の表示判定 純関数テスト。
//  「アップデートした既存ユーザーに1回だけ」を保証する条件を検証する。
//

import XCTest
@testable import Soramoyou

final class WhatsNewGateTests: XCTestCase {

    private let currentID = "v-current"

    /// 既存ユーザー（オンボ完了）で未読 → 表示する
    func testExistingUserUnseenShouldPresent() {
        XCTAssertTrue(WhatsNewGate.shouldPresent(
            currentID: currentID,
            lastSeenID: "",
            hasCompletedOnboarding: true
        ))
    }

    /// 既存ユーザーで同じ識別子を既読 → 出さない（1回だけ）
    func testExistingUserAlreadySeenShouldNotPresent() {
        XCTAssertFalse(WhatsNewGate.shouldPresent(
            currentID: currentID,
            lastSeenID: currentID,
            hasCompletedOnboarding: true
        ))
    }

    /// 既存ユーザーで「前回の別の新機能セット」を既読 → 今回ぶんは未読なので表示する
    func testExistingUserSeenOlderSetShouldPresent() {
        XCTAssertTrue(WhatsNewGate.shouldPresent(
            currentID: currentID,
            lastSeenID: "older-set",
            hasCompletedOnboarding: true
        ))
    }

    /// 新規ユーザー（オンボ未完了）には未読でも出さない（アップデート既存ユーザー限定）
    func testNewUserShouldNeverPresent() {
        XCTAssertFalse(WhatsNewGate.shouldPresent(
            currentID: currentID,
            lastSeenID: "",
            hasCompletedOnboarding: false
        ))
    }

    /// 新規ユーザーがオンボ完了時に既読化されたケースでも出さない
    func testNewUserMarkedSeenShouldNotPresent() {
        XCTAssertFalse(WhatsNewGate.shouldPresent(
            currentID: currentID,
            lastSeenID: currentID,
            hasCompletedOnboarding: false
        ))
    }

    /// 実際の `WhatsNewContent.currentID` を使った受け入れ条件の確認
    func testRealCurrentIDBehavior() {
        // 既存・未読 → 出る
        XCTAssertTrue(WhatsNewGate.shouldPresent(
            currentID: WhatsNewContent.currentID,
            lastSeenID: "",
            hasCompletedOnboarding: true
        ))
        // 既存・既読 → 出ない
        XCTAssertFalse(WhatsNewGate.shouldPresent(
            currentID: WhatsNewContent.currentID,
            lastSeenID: WhatsNewContent.currentID,
            hasCompletedOnboarding: true
        ))
    }
}
