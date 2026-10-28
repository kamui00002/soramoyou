//
//  ProfileSectionEntryButton.swift ⭐️
//  Soramoyou
//
//  他人のプロフィールに出す「○○さんの空カレンダー」「○○さんのお気に入りの空」の入口のボタン（1.18.0・PR-B）
//  計画書 ~/.claude/plans/profile-visibility-toggles.md の「アプリ」「(c) フォロー・入口ボタン・スイッチ」
//
//  見た目は自分のプロフィール（ProfileView）の「私のお気に入りの空」「空カレンダーを見る」の入口と同じ
//  （アイコン＋文言＋右向きの矢印・ガラスの角丸）。押すと少し沈む（HomeView.swift の CardButtonStyle）。
//
//  ⚠️ ここは「見た目だけ」を持つ部品にする。入口を出すかどうかは UserProfileViewModel の
//     `skyCalendarEntryState` / `favoritesEntryState`、押したときの処理（触覚・計測・シートや push）は呼び出し側が持つ。
//

import SwiftUI

/// 他人のプロフィールの欄（空カレンダー・お気に入りの空）への入口のボタン ⭐️
///
/// ## 使い方
/// ```swift
/// // シートで開く入口（空カレンダー）
/// ProfileSectionEntryButton(title: "○○さんの空カレンダー", systemImage: "calendar") {
///     isShowingCalendar = true
/// }
///
/// // push で開く入口（お気に入りの空）も同じくボタンにして、進めるのは見えない NavigationLink に任せる
/// // （UserProfileView の favoritesPushLink）。NavigationLink に label だけ借りて
/// // `.simultaneousGesture` で計測する形は、iPhone で開いても計測が残らなかった（1.18.0・TestFlight 118）
/// ProfileSectionEntryButton(title: "○○さんのお気に入りの空", systemImage: "bookmark") {
///     isShowingFavorites = true
/// }
/// ```
struct ProfileSectionEntryButton: View {
    /// ボタンの文言（例「○○さんの空カレンダー」）
    let title: String
    /// 左に出す SF Symbols の名前（例 "calendar" / "bookmark"）
    let systemImage: String
    /// 押したときの処理
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Self.label(title: title, systemImage: systemImage)
        }
        // 押すと少し沈む（ScrollView の中でもスクロールとぶつからない ButtonStyle・HomeView.swift と同じもの）
        .buttonStyle(CardButtonStyle())
    }

    /// 入口の見た目（`NavigationLink` の label にもそのまま使えるように、ボタンの外に出している）
    /// - Parameters:
    ///   - title: 文言
    ///   - systemImage: 左に出す SF Symbols の名前
    /// - Returns: アイコン＋文言＋矢印をガラスの角丸に載せた見た目
    static func label(title: String, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
                // 読み上げ（VoiceOver）では文言だけを読ませる（アイコンの名前まで読むと長くなる）
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .accessibilityHidden(true)
        }
        // ここから下は ProfileView の「私のお気に入りの空」「空カレンダーを見る」の入口と同じ値
        .font(.subheadline.weight(.semibold))
        .foregroundColor(DesignTokens.Colors.textPrimary)
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                .fill(.ultraThinMaterial)
        )
        // 角丸の内側の余白まで押せるようにする（Spacer の所を押しても反応するように）
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
    }
}
