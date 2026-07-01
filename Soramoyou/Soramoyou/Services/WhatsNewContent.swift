//
//  WhatsNewContent.swift ⭐️
//  Soramoyou
//
//  アップデートで増えた新機能を、既存ユーザーに「1回だけ」紹介するための
//  コンテンツ定義・永続化キー・表示判定をまとめた single source of truth。
//
//  - 表示判定は純関数 `WhatsNewGate.shouldPresent` に隔離（テスト対象）。
//  - 新機能セットを更新したら `currentID` を新しい文字列に変えるだけで、
//    再び全既存ユーザーに「1回だけ」表示される（ビルド番号とは非連動にして
//    ビルド番号ドリフトでの誤発火を避ける）。
//

import SwiftUI

/// What's New（新機能紹介）のコンテンツと永続化キーの定義。
enum WhatsNewContent {

    /// 今回の新機能セットの識別子。
    /// 新機能を追加したら、この文字列を変更する（例: "2026-09-phase2"）。
    /// `lastSeenWhatsNewVersion` がこの値と一致していれば「既読」とみなす。
    static let currentID = "2026-07-gallery-explore"

    // MARK: - 永続化キー（UserDefaults / @AppStorage）

    /// 既読済みの What's New 識別子を保存するキー。
    static let lastSeenKey = "lastSeenWhatsNewVersion"

    /// オンボーディング完了フラグのキー（ContentView と共有。綴り厳密一致）。
    /// `true` = 旧バージョンからの既存ユーザー（オンボ済み）→ What's New 対象。
    static let onboardingCompletedKey = "hasCompletedOnboarding"

    // MARK: - 紹介ページ

    /// 今回（ギャラリー強化）の新機能紹介ページ。
    /// ギャラリー上部のヘッダーで「何ができるようになったか」を発見しやすく伝える。
    static let pages: [WhatsNewPage] = [
        WhatsNewPage(
            icon: "line.3.horizontal.decrease.circle.fill",
            badge: "新機能",
            title: "ギャラリーで絞り込み",
            description: "ギャラリー上部から時間帯や空の種類で\n絞り込み、新着・人気で並び替えできます",
            gradientColors: [
                Color(red: 0.42, green: 0.68, blue: 0.93),
                Color(red: 0.62, green: 0.82, blue: 0.98)
            ]
        ),
        WhatsNewPage(
            icon: "paintpalette.fill",
            badge: "色で探す",
            title: "空の色から見つける",
            description: "カラーパレットをタップすると\nその色の空だけを集めて表示します",
            gradientColors: [
                Color(red: 0.62, green: 0.52, blue: 0.92),
                Color(red: 0.42, green: 0.70, blue: 0.95)
            ]
        ),
        WhatsNewPage(
            icon: "rectangle.grid.1x2.fill",
            badge: "新しい見せ方",
            title: "シャッフル＆モザイク",
            description: "シャッフルでランダムに、モザイク表示で\n写真の形そのままに空を楽しめます",
            gradientColors: [
                Color(red: 0.99, green: 0.72, blue: 0.36),
                Color(red: 0.96, green: 0.52, blue: 0.42)
            ]
        )
    ]
}

// MARK: - WhatsNewPage Model

/// What's New の1ページぶんのデータ。
struct WhatsNewPage: Identifiable {
    let id = UUID()
    /// SF Symbol 名（showsShootingDiagram=true のページでは未使用）
    let icon: String
    /// アイコン上のバッジ文言（例: "新機能"）
    let badge: String
    let title: String
    let description: String
    /// 背景グラデーション（OnboardingView と統一感のある配色）
    let gradientColors: [Color]
    /// true の場合、SF Symbol の代わりに「撮り方の図解」(ShootingGuideDiagram)を表示する。
    var showsShootingDiagram: Bool = false
}

// MARK: - WhatsNewGate（表示判定・純関数）

/// What's New を表示すべきかを判定する純関数。UI/永続化に非依存でテスト可能。
enum WhatsNewGate {

    /// 表示すべきかを返す。
    /// - Parameters:
    ///   - currentID: 現在の新機能セット識別子（`WhatsNewContent.currentID`）。
    ///   - lastSeenID: 既読済みの識別子（未読なら ""）。
    ///   - hasCompletedOnboarding: オンボーディング完了済みか。
    ///     新規ユーザー（false）にはオンボ自体で新機能が伝わるため表示しない。
    /// - Returns: 「オンボ完了済み（＝既存ユーザー）」かつ「未読」のときだけ true。
    static func shouldPresent(
        currentID: String,
        lastSeenID: String,
        hasCompletedOnboarding: Bool
    ) -> Bool {
        // 新規ユーザーには出さない（アップデートした既存ユーザー限定）
        guard hasCompletedOnboarding else { return false }
        // 同じ識別子を既読なら出さない（1回だけ）
        return lastSeenID != currentID
    }
}
