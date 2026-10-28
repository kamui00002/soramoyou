//
//  ProfileOwnerName.swift ⭐️
//  Soramoyou
//
//  他人のプロフィールの欄の題で、持ち主をどう呼ぶか（1.18.0・PR-B）
//  「○○さんの空カレンダー」「○○さんのお気に入りの空」の「○○さんの」の部分を、ここ 1 か所で決める。
//  使う所: 他人のプロフィールの入口のボタン（`UserProfileView.sectionEntryTitle(for:)`）・
//  開いた先の画面の題（`SkyCalendarDiaryView` / `FavoritesView` の他人用の `titleText`）。
//  入口と開いた先の題を必ず同じ言い方にそろえるため、3 か所で別々に決めない。
//
//  ⚠️ 自分用の題（「空カレンダー」「私のお気に入りの空」）はこの型を使わない（持ち主を呼ぶ必要が無いため）。
//  ⚠️ 他人のプロフィール画面の名前の代わりの文（「ユーザー」「プロフィール」など）はこの型の対象外
//     （2026-10-24 利用者が範囲外にした）。通知（Cloud Functions の「だれか」）も別の PR で扱う。
//

import Foundation

/// 他人のプロフィールの欄の題で、持ち主を呼ぶ言い方 ⭐️ 1.18.0 PR-B
enum ProfileOwnerName {
    /// 表示名が無い人の呼び方（2026-10-24 利用者の決定）
    ///
    /// 名前が無いときに「さんの空カレンダー」のような名前の抜けた題や、だれのものか分からない
    /// 「空カレンダー」だけの題を出さないように、やわらかい呼び方で持ち主を指す。
    static let fallback = "空が好きなだれか"

    /// 「○○さんの」/「空が好きなだれかの」
    ///
    /// - 名前があれば、前後の空白と改行を落とした名前に「さんの」を付ける
    ///   （これまでの 3 か所の題と同じ振る舞い。`" そら "` → `"そらさんの"`）。
    /// - 名前が無い（nil・空文字・空白や改行だけ）なら `fallback` に「の」を付ける。
    ///
    /// 使い方: `ProfileOwnerName.possessive(name) + "空カレンダー"` →「そらさんの空カレンダー」
    /// - Parameter displayName: 持ち主の表示名（`PublicProfile.displayName` など。無いこともある）
    /// - Returns: 題の頭に付ける「○○さんの」または「空が好きなだれかの」
    static func possessive(_ displayName: String?) -> String {
        // 空白・改行だけの名前は「名前が無い」と同じに扱う（名前の抜けた「さんの」を出さないため）
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "\(name)さんの"
        }
        return "\(fallback)の"
    }
}
