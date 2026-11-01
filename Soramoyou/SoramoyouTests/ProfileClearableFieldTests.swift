//
//  ProfileClearableFieldTests.swift
//  SoramoyouTests
//
//  プロフィール編集で「消す」項目（ProfileClearableField）が、書き込む内容に
//  FieldValue.delete() を正しく足すかを確かめる ⭐️
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

final class ProfileClearableFieldTests: XCTestCase {
    /// 消すと指定した項目に FieldValue.delete() が入ること（merge の setData / updateData でキーごと消える）。
    /// 入らないと nil の項目はキーが無いまま書かれ、古い表示名・アイコンが残る。
    func testApplyingDeletes_消す項目に削除の印が入る() {
        // Given: 表示名もアイコンも nil の User（toFirestoreData は 2 つのキーを入れない）
        let user = User(id: "test-user-id", displayName: nil, photoURL: nil)

        // When
        let data = ProfileClearableField.applyingDeletes([.displayName, .photoURL], to: user.toFirestoreData())

        // Then
        XCTAssertEqual(data["displayName"] as? FieldValue, FieldValue.delete())
        XCTAssertEqual(data["photoURL"] as? FieldValue, FieldValue.delete())
        // 他の項目は変えない
        XCTAssertEqual(data["id"] as? String, "test-user-id")
    }

    /// 値が入っている項目は、消すと指定されても消さずに値を書くこと（値を優先する）。
    func testApplyingDeletes_値がある項目は消さない() {
        // Given
        let user = User(id: "test-user-id", displayName: "空の人", photoURL: nil)

        // When
        let data = ProfileClearableField.applyingDeletes([.displayName, .photoURL], to: user.toFirestoreData())

        // Then
        XCTAssertEqual(data["displayName"] as? String, "空の人")
        XCTAssertEqual(data["photoURL"] as? FieldValue, FieldValue.delete())
    }

    /// 何も指定しなければ、書き込む内容は今までと同じ（サインアップなど他の呼び出しの意味を変えない）。
    func testApplyingDeletes_指定が無ければ何も足さない() {
        // Given
        let user = User(id: "test-user-id", displayName: nil, photoURL: nil)

        // When
        let data = ProfileClearableField.applyingDeletes([], to: user.toFirestoreData())

        // Then
        XCTAssertNil(data["displayName"])
        XCTAssertNil(data["photoURL"])
        XCTAssertEqual(data.count, user.toFirestoreData().count)
    }
}
