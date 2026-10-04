//
//  SoratomoComposeView.swift
//  Soramoyou
//
//  そらともの投稿画面 ⭐️
//  （tasks 13.7・13.8・design.md の SoratomoComposeView・ViewModel・要件 6.1〜6.12・7.5・12.2・14.5・16.4）
//
//  - 開いたら、写真ライブラリから 1 枚だけ選ぶ画面（`SoratomoPhotoPicker`）を出す
//  - 選んだ写真のプレビューと、任意のキャプション欄（改行は取り除く・残り文字数を出す）
//  - 投稿先は、開いているグループ 1 つだけ（選ぶ欄は出さない・要件 6.5）
//  - 送信中は進み具合を出し、確定・閉じる・写真の選び直しを受け付けない
//  - 失敗したら、写真とキャプションを残したまま文言と「もう一度送る」を出す
//  ⚠️ init のシグネチャは変えない（呼び出し側のタイムライン＝13.5 が、この形で呼ぶ）。
//

import SwiftUI

/// 投稿画面（写真の選択・プレビュー・キャプション・送信）
///
/// タイムライン（13.5）がシートで出す。投稿先は `groupId` の 1 つだけ。
/// 投稿が完了したら `onFinished(true)`、送らずに閉じたら `onFinished(false)` を呼ぶ
/// （新しい投稿はタイムラインの監視で先頭に届く）。
struct SoratomoComposeView: View {
    // MARK: - Properties

    /// 投稿先のグループの ID
    let groupId: String
    /// サービスの容れ物
    let dependencies: SoratomoDependencies
    /// 閉じるときに呼ぶ（投稿が完了したら true）
    let onFinished: (Bool) -> Void

    /// 投稿の ViewModel
    @StateObject private var viewModel: SoratomoComposeViewModel

    /// 写真を選ぶ画面を出しているか
    @State private var isPickerPresented = false
    /// 画面の記録と、最初の写真選びを済ませたか（画面の切り替えで 1 回だけにするため）
    @State private var hasAppeared = false
    /// 完了を呼び出し側へ伝えたか（`onFinished(true)` を 2 回呼ばないため）
    @State private var hasReportedFinish = false

    // MARK: - Init

    /// - Parameters:
    ///   - groupId: 投稿先のグループの ID
    ///   - dependencies: サービスの容れ物
    ///   - onFinished: 閉じるときに呼ぶ（投稿が完了したら true）
    init(groupId: String, dependencies: SoratomoDependencies, onFinished: @escaping (Bool) -> Void) {
        self.groupId = groupId
        self.dependencies = dependencies
        self.onFinished = onFinished
        let network = dependencies.network
        _viewModel = StateObject(
            wrappedValue: SoratomoComposeViewModel(
                groupId: groupId,
                skyService: dependencies.skyService,
                imageStore: dependencies.imageStore,
                isOnline: { network.isOnline },
                currentUid: dependencies.currentUid
            )
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    photoSection
                    captionSection
                    statusSection
                }
                .padding()
            }
            .navigationTitle("空を投稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        onFinished(false)
                    }
                    // 送信中に閉じると、アップロード済みの画像の後始末ができなくなる
                    .disabled(viewModel.isBusy)
                    .accessibilityLabel("投稿せずに閉じる")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("投稿") {
                        Task { await viewModel.submit() }
                    }
                    .disabled(!viewModel.canSubmit)
                    .accessibilityLabel("この空を投稿する")
                }
            }
        }
        // 送信中は下へのスワイプでも閉じさせない
        .interactiveDismissDisabled(viewModel.isBusy)
        .sheet(isPresented: $isPickerPresented) {
            SoratomoPhotoPicker(
                onPicked: { data in
                    isPickerPresented = false
                    Task { await viewModel.selectPhoto(data) }
                },
                onCancel: {
                    isPickerPresented = false
                }
            )
            .ignoresSafeArea()
        }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            SoratomoAnalytics.screen(.compose)
            // 投稿ボタンから開いたら、まず写真を選ぶ画面を出す（要件 6.1）
            if viewModel.photoData == nil {
                isPickerPresented = true
            }
        }
        // 完了したらタイムラインへ戻る（新しい投稿は監視で先頭に届く・要件 6.8）
        .onReceive(viewModel.$phase) { phase in
            guard phase == .finished, !hasReportedFinish else { return }
            hasReportedFinish = true
            onFinished(true)
        }
    }

    // MARK: - 写真

    /// 選んだ写真のプレビューと、選ぶ・選び直すボタン
    @ViewBuilder
    private var photoSection: some View {
        if let preview = viewModel.previewImage {
            Image(uiImage: preview)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("選んだ空の写真")
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
                .frame(height: 220)
                .overlay {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }

        // 読めない写真を選んだときの文言（投稿は始めない・要件 7.5）
        if let message = viewModel.photoErrorMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }

        Button {
            isPickerPresented = true
        } label: {
            Label(viewModel.previewImage == nil ? "写真を選ぶ" : "写真を選び直す", systemImage: "photo.on.rectangle")
        }
        .disabled(viewModel.isBusy)
        .accessibilityLabel(viewModel.previewImage == nil ? "写真を選ぶ" : "写真を選び直す")
    }

    // MARK: - キャプション

    /// 任意のキャプション欄と残り文字数
    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 入力は ViewModel が改行を取り除いてから持つ（要件 6.3）
            TextField(
                "ひとこと（任意）",
                text: Binding(
                    get: { viewModel.caption },
                    set: { viewModel.updateCaption($0) }
                ),
                axis: .vertical
            )
            .lineLimit(1 ... 4)
            .textFieldStyle(.roundedBorder)
            .disabled(viewModel.isBusy)
            .accessibilityLabel("キャプション（任意）")

            // 残り文字数（コードポイントで数える）。超えている間は確定できない（要件 6.4）
            HStack {
                Spacer()
                if viewModel.isCaptionOverLimit {
                    Text("\(-viewModel.captionRemaining)文字オーバーしています（\(SoratomoTextRules.captionMax)文字まで）")
                        .foregroundStyle(.red)
                } else {
                    Text("残り\(viewModel.captionRemaining)文字")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    // MARK: - 進み具合と失敗

    /// 送信中の進み具合と、失敗の文言・再試行
    @ViewBuilder
    private var statusSection: some View {
        switch viewModel.phase {
        case .checking:
            progressRow(title: "確認しています", value: nil)
        case .encoding:
            progressRow(title: "写真を準備しています", value: nil)
        case let .uploading(progress):
            progressRow(title: "写真を送っています", value: progress)
        case .saving:
            progressRow(title: "投稿を保存しています", value: nil)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                // 再試行は利用者の操作だけ。自動では送り直さない（要件 12.3）
                Button {
                    Task { await viewModel.submit() }
                } label: {
                    Label("もう一度送る", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmit)
                .accessibilityLabel("もう一度送る")
            }
        case .editing, .finished:
            EmptyView()
        }
    }

    /// 進み具合の 1 行（`value` が nil なら回るだけの表示）
    private func progressRow(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value {
                ProgressView(value: value)
            } else {
                ProgressView()
            }
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
