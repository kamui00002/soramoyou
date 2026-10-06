//
//  SoratomoNotificationPrimerView.swift ⭐️
//  Soramoyou
//
//  そらともの「通知の事前説明」と「設定の案内」の画面の部品（tasks 12.2・要件 10.1〜10.6・10.17）
//
//  どちらを出すかの判定は `SoratomoNotificationPrimer.decide()`（Services）が行う。
//  この画面は、判定の結果（`SoratomoPrimerDecision`）をそのまま受け取って、対応する中身を出すだけ。
//  シートとして出す場所（作成・参加の完了後）への組み込みは tasks 13.3 の担当。
//
//  ⚠️ 事前説明は、「通知を受け取る」か「あとで」のどちらかを必ず選ばせる（下へのスワイプで閉じさせない）。
//     選ぶ前に閉じられると「出した」記録が残らず、もう一度出てしまうため（要件 10.1・10.4 の「1 回だけ」）。
//  ⚠️ 文言に「グループごとに通知をオフにできる」と読めるものを入れない（要件 10.17）。
//     文言は `SoratomoNotificationPrimerCopy` に集め、単体テストで確かめる。
//

import SwiftUI
import UIKit
import UserNotifications

// MARK: - 文言

/// 事前説明と設定の案内の文言
///
/// 画面は文言をここからだけ読む（画面に直接書かない）。単体テストが、実際に出る文言を確かめられるようにするため。
enum SoratomoNotificationPrimerCopy {
    // MARK: 事前説明（要件 10.2）

    /// 事前説明の見出し
    static let primerTitle = "通知を受け取りますか？"
    /// 事前説明の説明文（要件 10.2 の文言）
    static let primerMessage = "友達が空を投稿したらお知らせします"
    /// 「通知を受け取る」の操作
    static let allowButton = "通知を受け取る"
    /// 「通知を受け取る」の VoiceOver の補足
    static let allowHint = "次に表示される確認で、通知を許可できます"
    /// 「あとで」の操作
    static let laterButton = "あとで"
    /// 「あとで」の VoiceOver の補足
    static let laterHint = "通知の確認は表示せず、この説明も、もう表示しません"

    // MARK: 設定の案内（要件 10.5）

    /// 設定の案内の見出し
    static let guideTitle = "通知がオフになっています"
    /// 設定の案内の説明文
    static let guideMessage = "友達の投稿をお知らせするには、設定アプリで通知を許可してください。"
    /// 設定アプリで通知を許可する手順
    static let guideSteps = [
        "「設定」アプリの「通知」から「そらもよう」を選びます",
        "「通知を許可」をオンにします",
    ]
    /// 設定アプリの通知の画面を開く操作
    static let guideOpenButton = "設定アプリの通知画面を開く"
    /// 設定アプリの通知の画面を開く操作の VoiceOver の補足
    static let guideOpenHint = "設定アプリが開きます"
    /// 設定の案内を閉じる操作
    static let guideCloseButton = "閉じる"

    /// 画面に出る文言のすべて（単体テストが、書いてはいけない言い方が無いかを確かめるために使う）
    static var allTexts: [String] {
        [
            primerTitle, primerMessage, allowButton, allowHint, laterButton, laterHint,
            guideTitle, guideMessage, guideOpenButton, guideOpenHint, guideCloseButton,
        ] + guideSteps
    }
}

// MARK: - 画面

/// 通知の事前説明、または設定の案内
///
/// - `decision` が `.showPrimer` なら事前説明、`.showSettingsGuide` なら設定の案内を出す。
///   `.none` のときは何も出さない（呼び出し側は、`.none` のときはこの画面を出さない想定）。
/// - 閉じる操作は持たない。選び終わった（または案内を閉じた）ことを `onFinished` で知らせるので、
///   呼び出し側がシートを閉じる。
struct SoratomoNotificationPrimerView: View {
    /// `SoratomoNotificationPrimer.decide()` の結果
    let decision: SoratomoPrimerDecision
    /// 判定と、選んだ操作の処理の窓口
    let primer: any SoratomoNotificationPrimerProtocol
    /// 選び終わった（または案内を閉じた）ときに呼ぶ。呼び出し側がシートを閉じる
    let onFinished: () -> Void

    var body: some View {
        switch decision {
        case .showPrimer:
            SoratomoNotificationPrimerContent(primer: primer, onFinished: onFinished)
        case .showSettingsGuide:
            SoratomoNotificationPrimerSettingsGuideContent(primer: primer, onFinished: onFinished)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - 事前説明の中身

/// 事前説明（「通知を受け取る」「あとで」）
private struct SoratomoNotificationPrimerContent: View {
    let primer: any SoratomoNotificationPrimerProtocol
    let onFinished: () -> Void

    /// 選んだ操作を処理している間は true（連打を防ぎ、ボタンを無効にする）
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer(minLength: DesignTokens.Spacing.md)

            SoratomoNotificationPrimerIcon(systemName: "bell.badge.fill")

            Text(SoratomoNotificationPrimerCopy.primerTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(SoratomoNotificationPrimerCopy.primerMessage)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: DesignTokens.Spacing.md)

            VStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    choose(.allow)
                } label: {
                    Text(SoratomoNotificationPrimerCopy.allowButton)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(SoratomoNotificationPrimerCopy.allowHint)

                Button {
                    choose(.later)
                } label: {
                    Text(SoratomoNotificationPrimerCopy.laterButton)
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(SoratomoNotificationPrimerCopy.laterHint)
            }
            .disabled(isProcessing)
        }
        .padding(DesignTokens.Spacing.lg)
        // 選ばずに閉じられると「出した」記録が残らない。必ず 2 つのどちらかを選ばせる
        .interactiveDismissDisabled(true)
    }

    /// 選んだ操作を処理して、終わったら呼び出し側に知らせる
    private func choose(_ choice: SoratomoPrimerChoice) {
        // 処理中の連打は無視する（`handle(choice:)` 側でも二重の処理は防ぐ）
        guard !isProcessing else { return }
        isProcessing = true
        Task { @MainActor in
            _ = await primer.handle(choice: choice)
            isProcessing = false
            onFinished()
        }
    }
}

// MARK: - 設定の案内の中身

/// 設定の案内（設定アプリで通知を許可する方法と、設定アプリの通知の画面を開く操作）
private struct SoratomoNotificationPrimerSettingsGuideContent: View {
    let primer: any SoratomoNotificationPrimerProtocol
    let onFinished: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.Spacing.lg) {
                SoratomoNotificationPrimerIcon(systemName: "bell.slash.fill")
                    .padding(.top, DesignTokens.Spacing.md)

                Text(SoratomoNotificationPrimerCopy.guideTitle)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(SoratomoNotificationPrimerCopy.guideMessage)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                stepsSection

                VStack(spacing: DesignTokens.Spacing.sm) {
                    Button {
                        openNotificationSettings()
                    } label: {
                        Text(SoratomoNotificationPrimerCopy.guideOpenButton)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(SoratomoNotificationPrimerCopy.guideOpenHint)

                    Button {
                        onFinished()
                    } label: {
                        Text(SoratomoNotificationPrimerCopy.guideCloseButton)
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(DesignTokens.Spacing.lg)
        }
        // 案内が表示されたら「出した」記録を残す。下へのスワイプで閉じられても、もう一度出さないため
        // （何度呼ばれても同じ。呼び出し側が先に記録していても害は無い）
        .onAppear { primer.markSettingsGuideShown() }
    }

    /// 手順（番号つき）
    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            ForEach(Array(SoratomoNotificationPrimerCopy.guideSteps.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 30, height: 30)
                        Text("\(index + 1)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                    .accessibilityHidden(true)

                    Text(text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                // VoiceOver では「1」と手順の文を別々に読ませず、1 つにまとめて読む
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(index + 1)、\(text)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 設定アプリの、このアプリの通知の画面を開く
    ///
    /// 通知の画面の URL が作れないときは、このアプリの設定の画面を開く。
    private func openNotificationSettings() {
        let url = URL(string: UIApplication.openNotificationSettingsURLString)
            ?? URL(string: UIApplication.openSettingsURLString)
        guard let url else { return }
        openURL(url)
    }
}

// MARK: - 共通の部品

/// 見出しの上のアイコン（空の色のグラデーションの丸）
private struct SoratomoNotificationPrimerIcon: View {
    let systemName: String

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [DesignTokens.Colors.skyBlue, DesignTokens.Colors.pastelPurple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 96, height: 96)
            Image(systemName: systemName)
                .font(.system(size: 42))
                .foregroundColor(.white)
        }
        // 見た目だけの飾り。VoiceOver には見出しと説明文を読ませる
        .accessibilityHidden(true)
    }
}

// MARK: - プレビュー

#Preview("事前説明") {
    // 本物の許可ダイアログを出さないよう、許可の要求を差し替える
    SoratomoNotificationPrimerView(
        decision: .showPrimer,
        primer: SoratomoNotificationPrimer(
            readAuthorizationStatus: { .notDetermined },
            defaults: UserDefaults(suiteName: "SoratomoNotificationPrimerPreview") ?? .standard,
            requestAuthorization: { true },
            log: { _ in }
        ),
        onFinished: {}
    )
}

#Preview("設定の案内") {
    SoratomoNotificationPrimerView(
        decision: .showSettingsGuide,
        primer: SoratomoNotificationPrimer(
            readAuthorizationStatus: { .denied },
            defaults: UserDefaults(suiteName: "SoratomoNotificationPrimerPreview") ?? .standard,
            requestAuthorization: { false },
            log: { _ in }
        ),
        onFinished: {}
    )
}
