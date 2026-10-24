//
//  ProfileSectionVisibilityTests.swift ⭐️
//  SoramoyouTests
//
//  プロフィールの見せる/見せない（1.18.0・PR-B）のテスト
//  - `PublicProfile` が publicProfiles の 3 項目を既定値つきで読み、丸ごとの書き込み（toFirestoreData）には入れないこと
//  - `ProfileSectionVisibility` の既定値・欄ごとの値・変わった欄の取り出し
//  期待する値はすべて直に書く（同じ値から作った 2 つを比べて緑にしない）。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

final class ProfileSectionVisibilityTests: XCTestCase {
    // MARK: - PublicProfile の読み込み

    /// 項目が無い（今いる人全員）→ おすすめ＝見せる・カレンダー＝見せない・お気に入り＝見せない
    func testPublicProfile_項目が無ければ既定値で読む() throws {
        let profile = try PublicProfile(from: ["id": "u1", "createdAt": Timestamp(date: Date())])

        XCTAssertTrue(profile.sectionVisibility.showsRecommendedSkies)
        XCTAssertFalse(profile.sectionVisibility.showsSkyCalendar)
        XCTAssertFalse(profile.sectionVisibility.showsFavorites)
    }

    /// 型違い（"true" の文字列など）→ その欄は既定値
    func testPublicProfile_型違いは既定値で読む() throws {
        let profile = try PublicProfile(from: [
            "id": "u1",
            "showsRecommendedSkies": "false",
            "showsSkyCalendar": "true",
            "showsFavorites": ["true"],
        ])

        XCTAssertTrue(profile.sectionVisibility.showsRecommendedSkies, "文字列の \"false\" は見せない扱いにしない（既定の true）")
        XCTAssertFalse(profile.sectionVisibility.showsSkyCalendar, "文字列の \"true\" は見せる扱いにしない（既定の false）")
        XCTAssertFalse(profile.sectionVisibility.showsFavorites, "配列は見せる扱いにしない（既定の false）")
    }

    /// 3 つとも値がある → その値（既定値と逆の値で確かめる）
    func testPublicProfile_値があればその値で読む() throws {
        let profile = try PublicProfile(from: [
            "id": "u1",
            "showsRecommendedSkies": false,
            "showsSkyCalendar": true,
            "showsFavorites": true,
        ])

        XCTAssertFalse(profile.sectionVisibility.showsRecommendedSkies)
        XCTAssertTrue(profile.sectionVisibility.showsSkyCalendar)
        XCTAssertTrue(profile.sectionVisibility.showsFavorites)
    }

    /// 1 つだけ値がある → その欄だけその値・残りは既定値
    func testPublicProfile_一部だけ値があれば残りは既定値() throws {
        let profile = try PublicProfile(from: ["id": "u1", "showsFavorites": true])

        XCTAssertTrue(profile.sectionVisibility.showsRecommendedSkies)
        XCTAssertFalse(profile.sectionVisibility.showsSkyCalendar)
        XCTAssertTrue(profile.sectionVisibility.showsFavorites)
    }

    /// User から作った公開プロフィール（作成・丸ごと上書きの道）は既定値
    func testPublicProfile_Userから作ると既定値() {
        let visibility = PublicProfile(from: User(id: "u1")).sectionVisibility

        XCTAssertTrue(visibility.showsRecommendedSkies)
        XCTAssertFalse(visibility.showsSkyCalendar)
        XCTAssertFalse(visibility.showsFavorites)
    }

    // MARK: - PublicProfile の書き込み（丸ごと）

    /// toFirestoreData（createPublicProfile の setData に使う丸ごとの形）には 3 項目を入れない。
    /// 既定値と違う値を持たせても入らないことを確かめる（入ると丸ごと上書きで本人の選んだ値を巻き戻しうる）
    func testToFirestoreData_見せる見せないの3項目を書かない() {
        let profile = PublicProfile(
            id: "u1",
            sectionVisibility: ProfileSectionVisibility(
                showsRecommendedSkies: false,
                showsSkyCalendar: true,
                showsFavorites: true
            )
        )

        let data = profile.toFirestoreData()

        XCTAssertNil(data["showsRecommendedSkies"])
        XCTAssertNil(data["showsSkyCalendar"])
        XCTAssertNil(data["showsFavorites"])
        XCTAssertNil(data["sectionVisibility"])
    }

    // MARK: - ProfileSectionVisibility

    /// 既定値: おすすめ＝見せる・カレンダー＝見せない・お気に入り＝見せない（今いる人の見え方を変えない）
    func testDefault_おすすめだけ見せる() {
        let visibility = ProfileSectionVisibility.default

        XCTAssertTrue(visibility.showsRecommendedSkies)
        XCTAssertFalse(visibility.showsSkyCalendar)
        XCTAssertFalse(visibility.showsFavorites)
    }

    /// isShown は欄ごとに対応する項目を返す（3 つとも違う組み合わせで確かめる）
    func testIsShown_欄ごとの値を返す() {
        let visibility = ProfileSectionVisibility(
            showsRecommendedSkies: false,
            showsSkyCalendar: true,
            showsFavorites: false
        )

        XCTAssertFalse(visibility.isShown(.recommendedSkies))
        XCTAssertTrue(visibility.isShown(.skyCalendar))
        XCTAssertFalse(visibility.isShown(.favorites))
    }

    /// 同じ値どうし → 変わった欄は無い
    func testChangedSections_同じなら空() {
        let visibility = ProfileSectionVisibility(
            showsRecommendedSkies: true,
            showsSkyCalendar: true,
            showsFavorites: false
        )
        let same = ProfileSectionVisibility(
            showsRecommendedSkies: true,
            showsSkyCalendar: true,
            showsFavorites: false
        )

        XCTAssertEqual(visibility.changedSections(from: same), [])
    }

    /// 1 つだけ変えた → その欄だけ
    func testChangedSections_1つだけ変えたらその欄だけ() {
        let edited = ProfileSectionVisibility(
            showsRecommendedSkies: true,
            showsSkyCalendar: true,
            showsFavorites: false
        )

        XCTAssertEqual(edited.changedSections(from: .default), [.skyCalendar])
    }

    /// 離れた 2 つを変えた → その 2 つを allCases の順（おすすめ → お気に入り）で
    func testChangedSections_2つ変えたら並びは欄の順() {
        let edited = ProfileSectionVisibility(
            showsRecommendedSkies: false,
            showsSkyCalendar: false,
            showsFavorites: true
        )

        XCTAssertEqual(edited.changedSections(from: .default), [.recommendedSkies, .favorites])
    }

    /// 3 つとも変えた → 3 つとも
    func testChangedSections_3つとも変えたら3つとも() {
        let edited = ProfileSectionVisibility(
            showsRecommendedSkies: false,
            showsSkyCalendar: true,
            showsFavorites: true
        )

        XCTAssertEqual(edited.changedSections(from: .default), [.recommendedSkies, .skyCalendar, .favorites])
    }

    // MARK: - ProfileSection の名前（ルール・計測と結びついている）

    /// publicProfiles の項目名（firestore.rules の isValidProfileVisibility・canReadFavoritesOf と同じ名前）
    func testFirestoreField_ルールと同じ項目名() {
        XCTAssertEqual(ProfileSection.recommendedSkies.firestoreField, "showsRecommendedSkies")
        XCTAssertEqual(ProfileSection.skyCalendar.firestoreField, "showsSkyCalendar")
        XCTAssertEqual(ProfileSection.favorites.firestoreField, "showsFavorites")
    }

    /// 計測（profile_visibility_changed などの section）に送る値
    func testRawValue_計測に送る値() {
        XCTAssertEqual(ProfileSection.recommendedSkies.rawValue, "recommended_skies")
        XCTAssertEqual(ProfileSection.skyCalendar.rawValue, "sky_calendar")
        XCTAssertEqual(ProfileSection.favorites.rawValue, "favorites")
    }

    /// 欄は 3 つでこの順（編集画面の並びと changedSections の並び）
    func testAllCases_3つでこの順() {
        XCTAssertEqual(ProfileSection.allCases, [.recommendedSkies, .skyCalendar, .favorites])
    }
}
