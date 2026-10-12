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
    // 2026-10-12: 1.15.0 = そらとも（友達グループで空を共有）の一般公開＋「グループを抜ける」（soratomo-public-launch 7.1）。
    //   1.13.0〜1.14.x は、クレームのある人だけに別の識別子で「先行公開」の紹介を出していた。1.15.0 で登録済みの
    //   全員が使えるようになったので、先行公開の紹介をやめ、全員向けのこの What's New に載せ直した。
    // ⚠️ 過去の値はすべて使えない（同じ ID のままページを足しても、既読の人には表示されない）。
    //    `WhatsNewGateTests.testCurrentIDDiffersFromPastIDs` が、下の 5 つと違うことを確かめる:
    //    - "2026-09-sky-camera"（空カメラ段階A＋空だけ編集）: 1.11.0 / 1.11.1 で全ユーザーが既読
    //    - "2026-09-sky-ae"（空優先AE 単独）: 検証用 build 102 のテスターが既読
    //    - "2026-09-ranking-recommended"（ランキング＋おすすめの空）: 未リリース。ページ構成が変わったので使わなかった
    //    - "2026-09-ranking-sky-ae"（いいねランキング＋私のおすすめの空＋空優先AE）: 1.12.0〜1.14.x で既読
    //    - "2026-10-soratomo-beta"（そらともの先行公開の紹介・別のキーで既読にしていた）: 紛らわしいので使わない
    static let currentID = "2026-10-soratomo-public"

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

    /// 今回（1.15.0: そらともの一般公開）の新機能紹介ページ。文言は下書き（soratomo-public-launch 9.1 で利用者が確認する）。
    /// アイコンは実UIと揃えている（person.2.circle = ホーム右上のそらともの入口 `SoratomoEntryButton`、
    /// rectangle.portrait.and.arrow.right = タイムライン右上のメニューの「グループを抜ける」）。
    /// ⚠️ 1.12.0 のページ（ランキング・おすすめの空・空優先AE）は出し切った（既読）ので載せない。
    /// ⚠️ 1 ページ目の入口の言い方は、オンボーディングの「そらとも」のページ（`OnboardingView`）とそろえる。
    static let pages: [WhatsNewPage] = [
        WhatsNewPage(
            icon: "person.2.circle",
            badge: "新機能",
            title: "そらとも",
            description: "家族や友達だけの小さなグループで、\n撮った空を見せ合えます\nホーム右上のボタンから始めましょう",
            gradientColors: [
                Color(red: 0.55, green: 0.80, blue: 0.98),
                Color(red: 0.36, green: 0.58, blue: 0.90),
            ]
        ),
        WhatsNewPage(
            icon: "rectangle.portrait.and.arrow.right",
            badge: "新機能",
            title: "グループの出入り",
            description: "招待コードでグループに参加できます\n抜けたいときは、タイムライン右上のメニューの\n「グループを抜ける」から",
            gradientColors: [
                Color(red: 0.62, green: 0.78, blue: 0.95),
                Color(red: 0.40, green: 0.45, blue: 0.85),
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
