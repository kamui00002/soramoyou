//
//  VisibilityTests.swift
//  SoramoyouTests
//
//  投稿の公開設定の説明文のテスト ⭐️（C 項目 4）
//
//  投稿情報画面で「フォロワーのみ」「非公開」を選んだときに、誰の画面に表示されるかの説明を出す。
//  文はフォロワーのみが 10/19、非公開が 11/19 のユーザー承認。アプリの画面で表示される相手のことだけを書き、言い切りはしない。
//

@testable import Soramoyou
import XCTest

final class VisibilityTests: XCTestCase {
    func testFollowersNoteIsTheApprovedText() {
        // 画面に出る文（10/19 ユーザー承認・文末の句点なし）
        XCTAssertEqual(
            Visibility.followers.selectionNote,
            "あなたをフォローしている人に表示されます。フォローは誰でもできます。あなたがブロックした人には表示されません"
        )
    }

    func testPrivateNoteIsTheApprovedText() {
        // 画面に出る文（11/19 ユーザー承認・文末の句点なし）
        XCTAssertEqual(
            Visibility.private.selectionNote,
            "あなただけに表示されます。ほかの人の画面には表示されません"
        )
    }

    func testPublicHasNoNote() {
        // 公開では説明を出さない
        XCTAssertNil(Visibility.public.selectionNote)
    }

    func testRawValuesAndDisplayNamesAreUnchanged() {
        // Firestore に保存する値と、全画面に出る表示名は変えていないことの見張り
        XCTAssertEqual(Visibility.public.rawValue, "public")
        XCTAssertEqual(Visibility.followers.rawValue, "followers")
        XCTAssertEqual(Visibility.private.rawValue, "private")
        XCTAssertEqual(Visibility.public.displayName, "公開")
        XCTAssertEqual(Visibility.followers.displayName, "フォロワーのみ")
        XCTAssertEqual(Visibility.private.displayName, "非公開")
    }
}
