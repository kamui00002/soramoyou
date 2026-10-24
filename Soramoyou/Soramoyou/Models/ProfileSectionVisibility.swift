//
//  ProfileSectionVisibility.swift ⭐️
//  Soramoyou
//
//  プロフィールの見せる/見せない（1.18.0・PR-B）
//  他人が自分のプロフィールを見たときに「おすすめの空・空カレンダー・お気に入りの空」を見せるかを、
//  本人がプロフィール編集の「プロフィールに表示するもの」で選ぶ。
//  値は `publicProfiles/{uid}` に Bool を 3 つ置く（計画書 ~/.claude/plans/profile-visibility-toggles.md の「データ」）。
//
//  ⚠️ 書き込みは `FirestoreServiceProtocol.updateProfileSectionVisibility` だけ（変えた欄だけを updateData する）。
//     `PublicProfile.toFirestoreData()`（丸ごと上書きの道）には入れない。丸ごと上書きで値が消えても、
//     読むときの既定値（`ProfileSectionVisibility.default`）＝カレンダーとお気に入りは「見せない」側に戻るだけにするため。
//

import Foundation

/// プロフィールに出す欄（他人がプロフィールを見たときに見せるかを、本人が選べる欄）⭐️
///
/// `rawValue` は計測（`profile_visibility_changed` / `user_profile_section_opened` の `section`）に送る値。
/// ⚠️ 計測の集計が名前に依存するので、`rawValue` は変えない。
enum ProfileSection: String, CaseIterable {
    /// 私のおすすめの空（見せる相手＝プロフィールを開ける全員）
    case recommendedSkies = "recommended_skies"
    /// 空カレンダー（見せる相手＝フォロワーだけ）
    case skyCalendar = "sky_calendar"
    /// お気に入りの空（見せる相手＝フォロワーだけ・公開の投稿だけ）
    case favorites

    /// `publicProfiles/{uid}` の項目名
    ///
    /// ⚠️ `firestore.rules` の `isValidProfileVisibility`（無い or bool）と
    ///    `canReadFavoritesOf`（`showsFavorites`）が同じ名前を見ている。変えるならルールと同時に。
    var firestoreField: String {
        switch self {
        case .recommendedSkies: "showsRecommendedSkies"
        case .skyCalendar: "showsSkyCalendar"
        case .favorites: "showsFavorites"
        }
    }
}

/// 3 つの欄の見せる/見せない ⭐️
///
/// `PublicProfile` が自動合成の `Codable` なので、この型も `Codable` にしておく
/// （Firestore への読み書きは `PublicProfile.init(from documentData:)` と専用の updateData が本筋）。
struct ProfileSectionVisibility: Equatable, Codable {
    var showsRecommendedSkies: Bool
    var showsSkyCalendar: Bool
    var showsFavorites: Bool

    /// 項目が無いとき（今いる人の見え方を変えない）: おすすめ＝見せる・カレンダー＝見せない・お気に入り＝見せない
    static let `default` = ProfileSectionVisibility(
        showsRecommendedSkies: true,
        showsSkyCalendar: false,
        showsFavorites: false
    )

    /// その欄を見せるか
    func isShown(_ section: ProfileSection) -> Bool {
        switch section {
        case .recommendedSkies: showsRecommendedSkies
        case .skyCalendar: showsSkyCalendar
        case .favorites: showsFavorites
        }
    }

    /// `other` と値が違う欄（変わった欄だけを書くため）
    ///
    /// 並びは `ProfileSection.allCases` の順（おすすめ → カレンダー → お気に入り）。
    func changedSections(from other: ProfileSectionVisibility) -> [ProfileSection] {
        ProfileSection.allCases.filter { isShown($0) != other.isShown($0) }
    }
}
