//
//  SoratomoGuideline.swift
//  Soramoyou
//
//  そらともガイドライン（作成・参加・入口で同意を求める決まり）⭐️
//  （release-gate 8・design.md の「同意」の節）
//
//  版の定数（8）に、本文の 4 つの節・同意の状態・入口の判定を足した（release-gate 9.5・要件 10.2・10.13）。
//  同意の状態を読むサービスは `SoratomoGuidelineService`、全文の画面は `SoratomoGuidelineView`。
//
//  ⚠️ 全文はアプリの中に置く（既存の利用規約は変えない・要件 13.7）。
//  ⚠️ 本文は下書き（tasks 12.1 で利用者が確認する）。4 つの節の語句は単体テストで固定している。
//

import Foundation

/// そらともガイドライン
enum SoratomoGuideline {
    /// このアプリが知っているガイドラインの版
    ///
    /// サーバーが拒否に付ける版（`consent_required`・`outdated_guideline` の `details.currentVersion`）がこれより大きければ、
    /// アプリが古いので、全文を出さずにアップデートを案内する（`SoratomoGroupService.mapCallableError`）。
    /// ⚠️ functions/soratomoCore.js の GUIDELINE_VERSION と一致させる（両方の単体テストで値を固定している）
    static let currentVersion = 1

    /// 本文の 1 つの節
    struct Section: Equatable, Sendable {
        /// 見出し
        let title: String
        /// 本文
        let body: String
    }

    /// 開発者への連絡先（設定の「お問い合わせ」と同じ。アプリとプライバシーポリシーに載せ済み）
    static let contactEmail = SupportContact.email

    /// 本文の前置き
    static let introduction = "そらともは、招待した友達だけで空の写真を見せ合う場所です。みんなが気持ちよく使えるよう、次のことを守ってください。"

    /// 本文の 4 つの節（要件 10.13）
    ///
    /// 1. 不快なコンテンツや迷惑行為を許容しないこと
    /// 2. 違反した投稿を開発者が削除し、違反した利用者のそらともの利用を停止すること
    /// 3. 通報とブロックの方法
    /// 4. 開発者への連絡の方法
    static let sections: [Section] = [
        Section(
            title: "不快なコンテンツや迷惑行為は許容しません",
            body: "そらともでは、不快なコンテンツや迷惑行為を一切許容しません。"
                + "性的・暴力的な写真、差別や誹謗中傷、嫌がらせ、なりすまし、空と関係のない宣伝などを投稿しないでください。"
        ),
        Section(
            title: "違反があったときの対応",
            body: "ガイドラインに違反した投稿は、開発者が確認して削除します。"
                + "違反した利用者は、そらともの利用を停止することがあります。"
        ),
        Section(
            title: "通報とブロックの方法",
            body: "気になる投稿は、投稿の長押しか「…」のメニューから通報できます。"
                + "同じメニューから投稿者をブロックすると、その人の投稿が表示されなくなります。"
                + "通報やブロックをしたことは、相手には知らされません。"
        ),
        Section(
            title: "開発者への連絡",
            body: "困ったことがあれば、設定の「お問い合わせ」か、メール（\(contactEmail)）で開発者に連絡してください。"
        ),
    ]
}

// MARK: - 同意の状態（release-gate 9.5）

/// 本人の同意の状態（`soratomoUsers/{uid}` の `guidelineVersion` と `groupCount`）
struct SoratomoConsentStatus: Equatable, Sendable {
    /// 同意した版（同意していなければ nil）
    let agreedVersion: Int?
    /// 所属しているグループの数
    let groupCount: Int

    /// このアプリの版以上に同意しているか
    ///
    /// 「以上」にするのは、新しい版のアプリで同意した人を、古い版のアプリで止めないため。
    var hasAgreedCurrent: Bool {
        guard let agreedVersion else { return false }
        return agreedVersion >= SoratomoGuideline.currentVersion
    }
}

// MARK: - 入口の判定（release-gate 9.5）

/// そらともの入口で、ガイドラインの全文を出すかの判定（要件 10.2）
enum SoratomoEntryGate {
    /// 入口で全文を出すか
    ///
    /// - 同意済みでなく、所属があるときだけ出す（所属が無い人は、作成と参加の前に同意を求める）
    /// - 状態を読めなかった（nil）ときは出さない（作成と参加はサーバーが同意を確かめて守る）
    static func needsGuideline(status: SoratomoConsentStatus?) -> Bool {
        guard let status else { return false }
        return !status.hasAgreedCurrent && status.groupCount > 0
    }
}
