//
//  SoratomoGuidelineView.swift ⭐️
//  Soramoyou
//
//  そらともガイドラインの全文の画面（release-gate 9.5・要件 10.3・10.12・10.13・15.1・15.3）
//
//  2 つの形を持つ。
//  - 同意を求める形（`.consent`）: 「同意する」と「同意しない」。選んだら `soratomo_guideline_result` を記録する
//  - 読むだけの形（`.readOnly`）: 「閉じる」だけ（グループ一覧のツールバーから開く・要件 10.12）
//  表示のたびに、画面名「そらともガイドライン」を 1 回記録する（要件 15.3）。
//
//  ⚠️ 同意の記録（Callable）は呼び出し側（入口・作成と参加の ViewModel）の責務。この画面は選んだことを伝えるだけ。
//     入口・作成・参加への組み込みは release-gate 10.4・10.5、一覧の「ガイドライン」は 10.5。
//

import SwiftUI

/// そらともガイドラインの全文の画面
struct SoratomoGuidelineView: View {
    /// 画面の形
    enum Mode {
        /// 同意を求める形
        /// - trigger: 全文を出したきっかけ（計測に使う）
        /// - isAgreeing: 同意を記録している途中か（途中はボタンを押せなくする）
        /// - onAgree: 「同意する」を選んだ
        /// - onDecline: 「同意しない」を選んだ
        case consent(
            trigger: SoratomoGuidelineTrigger,
            isAgreeing: Bool,
            onAgree: () -> Void,
            onDecline: () -> Void
        )
        /// 読むだけの形（「閉じる」を選んだら onClose）
        case readOnly(onClose: () -> Void)
    }

    let mode: Mode

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("そらともガイドライン")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(SoratomoGuideline.introduction)
                        .font(.body)
                    ForEach(Array(SoratomoGuideline.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Text(section.body)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            buttons
                .padding(20)
        }
        .onAppear {
            // 表示のたびに画面名を 1 回記録する（要件 15.3）
            SoratomoAnalytics.screen(.guideline)
        }
    }

    // MARK: - ボタン

    @ViewBuilder
    private var buttons: some View {
        switch mode {
        case let .consent(trigger, isAgreeing, onAgree, onDecline):
            VStack(spacing: 12) {
                Button {
                    log(.agree, trigger: trigger)
                    onAgree()
                } label: {
                    HStack(spacing: 8) {
                        if isAgreeing {
                            ProgressView()
                        }
                        Text("同意する")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("同意しない") {
                    log(.decline, trigger: trigger)
                    onDecline()
                }
                .controlSize(.large)
            }
            .disabled(isAgreeing)
        case let .readOnly(onClose):
            Button {
                onClose()
            } label: {
                Text("閉じる")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    /// 選んだ操作を記録する（要件 15.1）
    private func log(_ choice: SoratomoGuidelineChoice, trigger: SoratomoGuidelineTrigger) {
        SoratomoAnalytics.log(.guidelineResult(choice: choice, trigger: trigger, version: SoratomoGuideline.currentVersion))
    }
}
