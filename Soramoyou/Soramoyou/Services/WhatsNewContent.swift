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
    // 2026-07-21: 1.9.4 で4新機能（空を整える／空カレンダー／連続記録／共有カード）を紹介。
    static let currentID = "2026-07-sky-tools"

    // MARK: - 永続化キー（UserDefaults / @AppStorage）

    /// 既読済みの What's New 識別子を保存するキー。
    static let lastSeenKey = "lastSeenWhatsNewVersion"

    /// オンボーディング完了フラグのキー（ContentView と共有。綴り厳密一致）。
    /// `true` = 旧バージョンからの既存ユーザー（オンボ済み）→ What's New 対象。
    static let onboardingCompletedKey = "hasCompletedOnboarding"

    /// Living Sky（空を動かす）初回コーチマークの既読フラグを保存するキー（EditView と共有）。
    /// What's New とは別枠の一度きり通知だが、永続化キーの置き場所はここに集約する運用に合わせる。
    static let hasSeenLivingSkyCoachMarkKey = "hasSeenLivingSkyCoachMark"

    // MARK: - 紹介ページ

    /// 今回（1.9.4）の新機能紹介ページ。
    /// アイコンは各機能の実UIで使われている SF Symbol と揃えている
    /// （空を整える=EditView の適用ボタン／空カレンダー=SkyCalendarDiaryView／
    ///   連続記録=SkyStreakChipView・SkyZukanView／共有カード=共有メニューの「共有カードを書き出す」）。
    static let pages: [WhatsNewPage] = [
        WhatsNewPage(
            icon: "cloud.sun.fill",
            badge: "自動補正",
            title: "空を整える",
            description: "編集画面で空の部分だけを自動で見つけて\n明るさや色みをワンタップで整えます",
            gradientColors: [
                Color(red: 0.40, green: 0.72, blue: 0.95),
                Color(red: 0.99, green: 0.75, blue: 0.45)
            ]
        ),
        WhatsNewPage(
            icon: "calendar",
            badge: "空図鑑",
            title: "空カレンダー",
            description: "プロフィールの「空図鑑」から開くと\nあの日の空をカレンダーで振り返れます",
            gradientColors: [
                Color(red: 0.46, green: 0.44, blue: 0.82),
                Color(red: 0.64, green: 0.60, blue: 0.92)
            ]
        ),
        WhatsNewPage(
            icon: "flame.fill",
            badge: "毎日の記録",
            title: "連続記録",
            description: "毎日空を投稿すると連続日数が記録され\n達成に応じてバッジがもらえます",
            gradientColors: [
                Color(red: 1.00, green: 0.62, blue: 0.32),
                Color(red: 0.94, green: 0.38, blue: 0.36)
            ]
        ),
        WhatsNewPage(
            icon: "square.and.arrow.up.on.square",
            badge: "書き出し",
            title: "共有カード",
            description: "共有メニューから日付入りの\nカードをInstagramやXへシェアできます",
            gradientColors: [
                Color(red: 0.68, green: 0.55, blue: 0.92),
                Color(red: 0.95, green: 0.56, blue: 0.76)
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
