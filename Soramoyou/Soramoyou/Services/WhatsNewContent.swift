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
    // 2026-09-16: 空カメラ（グリッド・水平線ガイド・空優先AE 付きのアプリ内カメラ）。
    // ⚠️ 空優先AE は段階 A と**同一ビルドで出荷**するためこの識別子を据え置く。
    //    後追いビルドに変わった場合は必ず新しい値へ変えること
    //    （段階 A で既読になるので、同じ ID のまま文言だけ足しても誰にも表示されない）。
    // ⚠️ 前回の "2026-09-favorites" は 1.10.0/1.10.1 で既に消費済み（＝全ユーザーが既読）。
    //    同じ識別子のまま機能を足しても誰にも表示されないため、必ず新しい値にする。
    static let currentID = "2026-09-sky-camera"

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

    /// 今回（2026-09 空カメラ）の新機能紹介ページ。
    /// アイコンは実UIと揃えている（camera.fill = 投稿画面「撮る」ボタン / cloud.sun = 空優先AE のトグル）。
    static let pages: [WhatsNewPage] = [
        WhatsNewPage(
            icon: "camera.fill",
            badge: "新機能",
            title: "空カメラ",
            description: "投稿の「撮る」から、グリッドと水平線ガイド付きで\n空を撮れるようになりました",
            gradientColors: [
                Color(red: 0.45, green: 0.72, blue: 0.98),
                Color(red: 0.20, green: 0.35, blue: 0.75),
            ]
        ),
        WhatsNewPage(
            icon: "cloud.sun",
            badge: "新機能",
            title: "空が白く飛ばない",
            description: "明るい空も白くつぶれにくくなりました\n上の ☁️ ボタンで切り替えられます",
            gradientColors: [
                Color(red: 0.99, green: 0.80, blue: 0.45),
                Color(red: 0.36, green: 0.58, blue: 0.90),
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
