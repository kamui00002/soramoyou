//
//  SoratomoModelsTests.swift
//  SoramoyouTests
//
//  そらとものモデル（画像のパス）と、既存の User に足した「そらとも通知」のテスト ⭐️（tasks 10.4）
//
//  ⚠️ User の既存のテスト（testUserToFirestoreDocument）は main で既に落ちているため、
//     そらともの分はこのファイルに分けている（既存の失敗と混ぜない）。
//

@testable import Soramoyou
import XCTest

final class SoratomoModelsTests: XCTestCase {
    // MARK: - 画像のパス

    func testImagePathsFollowStorageRuleLayout() {
        // storage.rules の match /soratomo/{groupId}/{authorId}/{skyId}/{fileName} と同じ並び
        let paths = SoratomoImagePaths(groupId: "g1", authorId: "u1", skyId: "s1")
        XCTAssertEqual(paths.display, "soratomo/g1/u1/s1/display.jpg")
        XCTAssertEqual(paths.thumbnail, "soratomo/g1/u1/s1/thumb.jpg")
    }

    func testSkyDerivesImagePathsFromIds() {
        let sky = SoratomoSky(
            id: "sky9", groupId: "group7", authorId: "author3", caption: nil,
            pixelWidth: 2048, pixelHeight: 1536, createdAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(sky.imagePaths, SoratomoImagePaths(groupId: "group7", authorId: "author3", skyId: "sky9"))
        XCTAssertEqual(sky.imagePaths.display, "soratomo/group7/author3/sky9/display.jpg")
    }

    // MARK: - User の「そらとも通知」

    func testNotifySoratomoDefaultMatchesFunctions() {
        // ⚠️ functions/soratomoCore.js の SORATOMO_PREF_DEFAULT（true）と一致させる
        XCTAssertTrue(User.notifySoratomoDefault)
    }

    func testNotifySoratomoIsNotWrittenByToFirestoreData() {
        // User 全体の書き込み（updateUser の setData(merge)）に載せない。ON でも OFF でも未設定でもキーが無い
        let values: [Bool?] = [true, false, nil]
        for value in values {
            let user = User(id: "u1", notifySoratomo: value)
            XCTAssertNil(user.toFirestoreData()["notifySoratomo"], "notifySoratomo=\(String(describing: value))")
        }
    }

    func testNotifySoratomoMissingMeansOn() throws {
        // 旧ユーザー（項目が無い）は nil で、実際に使う値は ON
        let user = try User(from: ["id": "u1"])
        XCTAssertNil(user.notifySoratomo)
        XCTAssertTrue(user.notifySoratomoEnabled)
    }

    func testNotifySoratomoReadsSavedValue() throws {
        let off = try User(from: ["id": "u1", "notifySoratomo": false])
        XCTAssertEqual(off.notifySoratomo, false)
        XCTAssertFalse(off.notifySoratomoEnabled)

        let on = try User(from: ["id": "u1", "notifySoratomo": true])
        XCTAssertEqual(on.notifySoratomo, true)
        XCTAssertTrue(on.notifySoratomoEnabled)
    }

    func testNotifySoratomoNonBooleanFallsBackToOn() throws {
        // 真偽値でない値は未保存と同じ扱い（Functions の prefEnabled と同じ読み方）
        let user = try User(from: ["id": "u1", "notifySoratomo": "off"])
        XCTAssertNil(user.notifySoratomo)
        XCTAssertTrue(user.notifySoratomoEnabled)
    }

    func testUserFromFirebaseAuthStartsUnset() {
        // 新規の User（init(from: FirebaseAuth.User) と同じ既定）は未設定
        XCTAssertNil(User(id: "u1").notifySoratomo)
        XCTAssertTrue(User(id: "u1").notifySoratomoEnabled)
    }

    // MARK: - 既存の 3 つの通知設定が変わっていないこと（要件 13.7）

    func testExistingNotificationPreferencesUnchanged() throws {
        // 書き込みの項目と既定値（reactions=true / following=true / everyone=false）
        let data = User(id: "u1").toFirestoreData()
        XCTAssertEqual(data["notifyReactions"] as? Bool, true)
        XCTAssertEqual(data["notifyNewPostsFromFollowing"] as? Bool, true)
        XCTAssertEqual(data["notifyNewPostsFromEveryone"] as? Bool, false)

        // 読み込みで欠落したときの既定値も同じ
        let missing = try User(from: ["id": "u1"])
        XCTAssertTrue(missing.notifyReactions)
        XCTAssertTrue(missing.notifyNewPostsFromFollowing)
        XCTAssertFalse(missing.notifyNewPostsFromEveryone)

        // そらとも通知を OFF にしても、既存の 3 つは影響を受けない
        let soratomoOff = try User(from: ["id": "u1", "notifySoratomo": false])
        XCTAssertTrue(soratomoOff.notifyReactions)
        XCTAssertTrue(soratomoOff.notifyNewPostsFromFollowing)
        XCTAssertFalse(soratomoOff.notifyNewPostsFromEveryone)
    }

    func testUserWriteKeysAreUnchangedBySoratomo() {
        // そらともを足しても、User 全体の書き込みの項目は増えない（全項目を入れた User で確かめる）
        let user = User(
            id: "u1", email: "a@example.com", displayName: "そら", photoURL: "https://example.com/a.jpg",
            bio: "bio", customEditTools: ["exposure"], customEditToolsOrder: ["exposure"],
            blockedUserIds: ["u2"], followedTags: ["空"], notifySoratomo: false
        )
        XCTAssertEqual(
            Set(user.toFirestoreData().keys),
            [
                "id", "createdAt", "updatedAt", "email", "displayName", "photoURL", "bio",
                "customEditTools", "customEditToolsOrder", "followersCount", "followingCount", "postsCount",
                "notifyReactions", "notifyNewPostsFromFollowing", "notifyNewPostsFromEveryone", "blockedUserIds",
            ]
        )
    }
}
