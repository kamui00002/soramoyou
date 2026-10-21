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
    // 2026-10-21: そらとものリアクション（soratomo-reactions 8.4）。「プロフィールからブロック」（#192）はまだどの版でも
    //   出していないので、リアクションの後ろに 2 ページ目として残す（利用者の決定 2026-10-21・設計の U1 は
    //   「リアクションのページは 1 枚」と読む）。リアクションのページの文言は利用者が承認済み（tasks 10・2026-10-22）。
    // 2026-10-19: ほかの人のプロフィールの「…」からブロックできるようにした（C 項目 3・ブロックするとお互いのフォローも外れる）。
    //   1.15.0 のそらとも 2 ページは出し切った（既読）ので載せない（利用者の決定 2026-10-19）。
    // 2026-10-12: 1.15.0 = そらとも（友達グループで空を共有）の一般公開＋「グループを抜ける」（soratomo-public-launch 7.1）。
    //   1.13.0〜1.14.x は、クレームのある人だけに別の識別子で「先行公開」の紹介を出していた。1.15.0 で登録済みの
    //   全員が使えるようになったので、先行公開の紹介をやめ、全員向けのこの What's New に載せ直した。
    // ⚠️ 過去の値はすべて使えない（同じ ID のままページを足しても、既読の人には表示されない）。
    //    `WhatsNewGateTests.testCurrentIDDiffersFromPastIDs` が、下の 7 つと違うことを確かめる:
    //    - "2026-09-sky-camera"（空カメラ段階A＋空だけ編集）: 1.11.0 / 1.11.1 で全ユーザーが既読
    //    - "2026-09-sky-ae"（空優先AE 単独）: 検証用 build 102 のテスターが既読
    //    - "2026-09-ranking-recommended"（ランキング＋おすすめの空）: 未リリース。ページ構成が変わったので使わなかった
    //    - "2026-09-ranking-sky-ae"（いいねランキング＋私のおすすめの空＋空優先AE）: 1.12.0〜1.14.x で既読
    //    - "2026-10-soratomo-beta"（そらともの先行公開の紹介・別のキーで既読にしていた）: 紛らわしいので使わない
    //    - "2026-10-soratomo-public"（そらともの一般公開＋グループを抜ける）: 1.15.0 で既読
    //    - "2026-10-block-from-profile"（プロフィールからブロック単独）: 未リリース。リアクションと 2 ページにしたので使わなかった
    static let currentID = "2026-10-soratomo-reactions"

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

    /// 今回の新機能紹介ページ（2 ページ・利用者の決定 2026-10-21）
    ///
    /// 1. そらとものリアクション（soratomo-reactions 8.4）。文言は利用者が承認済み（tasks 10・2026-10-22）。変えるときは承認を取り直す。
    ///    アイコンは実UIと揃えている（face.smiling = カードの右下のリアクションのボタン）。絵文字は本文に入れない
    /// 2. C 項目 3: プロフィールからブロック。文言は利用者が承認済み（2026-10-19）。変えるときは承認を取り直す。
    ///    アイコンは実UIと揃えている（hand.raised = プロフィール右上の「…」の「このユーザーをブロック」）。
    /// 新規ユーザー向けのオンボーディングには、どちらも入れない（利用者の決定 2026-10-19・soratomo-reactions 要件 16.3）。
    /// ⚠️ 1.15.0 のページ（そらとも・グループの出入り）は出し切った（既読）ので載せない。
    ///    オンボーディングの「そらとも」のページ（`OnboardingView`）は、1.15.0 のそのページとそろえて作った。
    static let pages: [WhatsNewPage] = [
        WhatsNewPage(
            icon: "face.smiling",
            badge: "新機能",
            title: "空にリアクション",
            // 改行はほかのページの "\n" と同じ（複数行の文字列で書いている）
            description: """
            友達の空に、7つの絵文字から1つを選んで
            気持ちを送れます
            カードの右下のボタンから
            """,
            gradientColors: [
                Color(red: 0.96, green: 0.76, blue: 0.62),
                Color(red: 0.86, green: 0.52, blue: 0.56),
            ]
        ),
        WhatsNewPage(
            icon: "hand.raised",
            badge: "新機能",
            title: "プロフィールからブロック",
            description: "ほかの人のプロフィール右上の「…」から\nブロックできるようになりました\nお互いのフォローも外れます",
            gradientColors: [
                Color(red: 0.58, green: 0.72, blue: 0.90),
                Color(red: 0.38, green: 0.50, blue: 0.80),
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
