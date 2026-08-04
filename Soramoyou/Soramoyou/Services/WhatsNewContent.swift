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
    // 2026-08-03: 「AIで自動編集」が候補選択方式に変更。空タイプを選ぶと、その空タイプで
    // 編集した記録から作った定番パターン（無ければ「あなたの定番」やおまかせプリセットへ
    // フォールバック）を1件提案する仕様（2026-08-05: description の文言を現行仕様に合わせて修正。
    // 複数の空タイプ別定番を並べて見比べる旧設計の説明のままだったため）。
    static let currentID = "2026-08-personal-default-candidates"

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

    /// 今回（2026-08）の新機能紹介ページ。
    /// アイコンは実UIで使われている SF Symbol と揃えている
    /// （AI自動編集の候補選択＝EditView の「AIで自動編集」ボタン）。
    static let pages: [WhatsNewPage] = [
        WhatsNewPage(
            icon: "wand.and.stars",
            badge: "AI自動編集",
            title: "パターンを選べるように",
            // ⚠️ 2026-08-05: currentID は変えていない（同一リリースサイクル内の文言修正であり、
            // 既読ユーザーへ再表示する必要は無いため）。現行仕様（空タイプを選ぶと、その空タイプ向けの
            // 定番1枚が提案される）に合わせて description のみ書き直した
            // （旧文言は「複数の空タイプ別定番を並べて見比べる」という初期設計の説明のままだった）。
            description: "「AIで自動編集」が候補から選ぶ方式に。\n空のタイプを選ぶと、あなたがその空で編集した記録から作ったパターンを提案します",
            gradientColors: [
                Color(red: 0.55, green: 0.48, blue: 0.90),
                Color(red: 0.85, green: 0.58, blue: 0.90),
            ]
        ),
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
