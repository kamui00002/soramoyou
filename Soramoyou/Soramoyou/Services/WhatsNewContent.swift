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
    // 2026-10-24: 1.18.0 = プロフィールの見せる/見せない（PR-B・計画書 ~/.claude/plans/profile-visibility-toggles.md）。
    //   1.16.0 の 2 ページ（リアクション・プロフィールからブロック）は出し切った（既読）ので載せない。
    //   1.18.0 の What's New は 2 ページの予定（利用者の決定）。2 ページ目（ホームを左右にめくる・写真を 2 回タップでいいね）は
    //   PR-H が足す。1.18.0 を出す前なら ID はこのままでよい（まだ公開していないので、既読にした人は検証用の端末だけ）。
    // 2026-10-21: そらとものリアクション（soratomo-reactions 8.4）。「プロフィールからブロック」（#192）はまだどの版でも
    //   出していないので、リアクションの後ろに 2 ページ目として残す（利用者の決定 2026-10-21・設計の U1 は
    //   「リアクションのページは 1 枚」と読む）。リアクションのページの文言は利用者が承認済み（tasks 10・2026-10-22）。
    // 2026-10-19: ほかの人のプロフィールの「…」からブロックできるようにした（C 項目 3・ブロックするとお互いのフォローも外れる）。
    //   1.15.0 のそらとも 2 ページは出し切った（既読）ので載せない（利用者の決定 2026-10-19）。
    // 2026-10-12: 1.15.0 = そらとも（友達グループで空を共有）の一般公開＋「グループを抜ける」（soratomo-public-launch 7.1）。
    //   1.13.0〜1.14.x は、クレームのある人だけに別の識別子で「先行公開」の紹介を出していた。1.15.0 で登録済みの
    //   全員が使えるようになったので、先行公開の紹介をやめ、全員向けのこの What's New に載せ直した。
    // ⚠️ 過去の値はすべて使えない（同じ ID のままページを足しても、既読の人には表示されない）。
    //    `WhatsNewGateTests.testCurrentIDDiffersFromPastIDs` が、下の一覧と違うことを確かめる（一覧に足したらテストにも足す）:
    //    - "2026-09-sky-camera"（空カメラ段階A＋空だけ編集）: 1.11.0 / 1.11.1 で全ユーザーが既読
    //    - "2026-09-sky-ae"（空優先AE 単独）: 検証用 build 102 のテスターが既読
    //    - "2026-09-ranking-recommended"（ランキング＋おすすめの空）: 未リリース。ページ構成が変わったので使わなかった
    //    - "2026-09-ranking-sky-ae"（いいねランキング＋私のおすすめの空＋空優先AE）: 1.12.0〜1.14.x で既読
    //    - "2026-10-soratomo-beta"（そらともの先行公開の紹介・別のキーで既読にしていた）: 紛らわしいので使わない
    //    - "2026-10-soratomo-public"（そらともの一般公開＋グループを抜ける）: 1.15.0 で既読
    //    - "2026-10-block-from-profile"（プロフィールからブロック単独）: 未リリース。リアクションと 2 ページにしたので使わなかった
    //    - "2026-10-soratomo-reactions"（そらとものリアクション＋プロフィールからブロック）: 1.16.0 で既読
    static let currentID = "2026-10-profile-visibility"

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

    /// 今回の新機能紹介ページ（1.18.0・今は 1 ページ。2 ページ目は PR-H が足す＝利用者の決定 2026-10-24）
    ///
    /// 1. プロフィールに見せるものを選べる（PR-B）。文言は下書き（利用者の承認待ち）。承認をもらったら、ここに「承認済み」と書く。
    ///    空カレンダーとお気に入りの空は既定で「見せない」なので、新しく見せられるようになったその 2 つを本文に出し、
    ///    プロフィール編集の「プロフィールに表示するもの」への導線を入れる。
    ///    ⚠️ 「フォロワーだけ」は見せ方の制限で壁ではない（公開の投稿は誰でも読める）ので、「フォロワー以外には見えません」とは書かない。
    ///    アイコンは person.text.rectangle（プロフィールのカード）。最初は eye（見せる）にしたが、実機で見た利用者が
    ///    「目が怖い」と言ったので差し替えた（利用者の決定 2026-10-25）。入口のメニューの「プロフィール編集」は pencil なので重ならない。
    /// 新規ユーザー向けのオンボーディングには入れない（計画書「（確定）新規ユーザーへの案内は不要」: 既定が OFF で、本人が編集画面で選ぶ機能のため）。
    /// ⚠️ 1.16.0 のページ（リアクション・プロフィールからブロック）は出し切った（既読）ので載せない。
    static let pages: [WhatsNewPage] = [
        WhatsNewPage(
            icon: "person.text.rectangle",
            badge: "新機能",
            // 題は 30pt で 1 行に収まらない（16 文字）。言葉の途中で折り返さないよう、意味の切れ目で改行する
            title: "プロフィールに\n見せるものを選べる",
            // 改行はほかのページの "\n" と同じ（複数行の文字列で書いている）
            description: """
            空カレンダーやお気に入りの空を
            フォロワーに見せられます
            プロフィール編集の
            「プロフィールに表示するもの」から
            """,
            gradientColors: [
                Color(red: 0.55, green: 0.78, blue: 0.86),
                Color(red: 0.36, green: 0.55, blue: 0.82),
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
