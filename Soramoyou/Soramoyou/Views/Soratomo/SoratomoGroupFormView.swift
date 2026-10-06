//
//  SoratomoGroupFormView.swift
//  Soramoyou
//
//  ⭐️ グループの作成と、招待コードでの参加のシート（tasks 13.2・13.3。骨組みは 13.1 で置いた）
//  ⚠️ init のシグネチャは変えない（呼び出し側の SoratomoRootView などを、担当は触らないため）。
//     足したいものがあれば、変えずに「共有ファイルへの追加依頼」として報告する。
//

import SwiftUI

/// 作成と参加のどちらのフォームか（一覧のシートの `item` に使う）
enum SoratomoGroupFormMode: String, Identifiable {
    /// グループを作る
    case create
    /// 招待コードで参加する
    case join

    var id: String { rawValue }
}

/// グループの作成と、招待コードでの参加のフォーム（一覧からシートで出す）
///
/// 表示名の事前入力（13.2）→ 作成か参加（13.3）→ 通知の事前説明（12.2）までを、このシートの中で行う。
/// 成功したら、進む先のパスを `onCompleted` で返す（一覧がルーターのパスに入れる）。
/// - 作成の成功: `[.timeline(groupId:), .invite(groupId:)]`（招待の画面から戻るとタイムライン）
/// - 参加の成功（既存のメンバーだった場合も）: `[.timeline(groupId:)]`
/// 閉じるだけのときは `onCancel`。
///
/// 流れと状態は `SoratomoGroupFormViewModel` が持ち、この画面は段（`step`）ごとの中身を出すだけ。
/// ⚠️ 処理中と、事前説明・設定の案内を出している間は、閉じる操作も下へのスワイプも受け付けない
///    （事前説明を選ばずに閉じると「出した」記録が残らず、次にもう一度出てしまうため・要件 10.1・10.4）。
struct SoratomoGroupFormView: View {
    /// 作成か参加か
    let mode: SoratomoGroupFormMode
    /// サービスの容れ物
    let dependencies: SoratomoDependencies
    /// 成功したときに、進む先のパスを渡す
    let onCompleted: ([SoratomoDestination]) -> Void
    /// 何もせずに閉じるとき
    let onCancel: () -> Void

    /// シートの流れの ViewModel
    @StateObject private var viewModel: SoratomoGroupFormViewModel

    /// グループ名か招待コードの入力欄にフォーカスがあるか
    @FocusState private var isFormFieldFocused: Bool

    // MARK: - Init

    /// - Parameters:
    ///   - mode: 作成か参加か
    ///   - dependencies: サービスの容れ物（ViewModel には中身だけを渡す）
    ///   - onCompleted: 成功したときに、進む先のパスを受け取る
    ///   - onCancel: 何もせずに閉じるとき
    init(
        mode: SoratomoGroupFormMode,
        dependencies: SoratomoDependencies,
        onCompleted: @escaping ([SoratomoDestination]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.dependencies = dependencies
        self.onCompleted = onCompleted
        self.onCancel = onCancel
        let network = dependencies.network
        _viewModel = StateObject(
            wrappedValue: SoratomoGroupFormViewModel(
                mode: mode,
                groupService: dependencies.groupService,
                profileService: dependencies.profileService,
                primer: dependencies.primer,
                isOnline: { network.isOnline },
                currentUid: dependencies.currentUid,
                onCompleted: onCompleted
            )
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                // 背景を雲つきの空に（表示名の入力・通知の事前説明もこの content の中に出る）
                .soratomoSkyBackground()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // 事前説明・設定の案内の間は、閉じる操作を出さない（選び終わると onFinished で閉じる）
                    if !isShowingPrimer {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる", action: onCancel)
                                .disabled(!viewModel.canCancel)
                                .accessibilityLabel(cancelAccessibilityLabel)
                        }
                    }
                }
        }
        // 処理中と、事前説明・設定の案内の間は、下へのスワイプで閉じさせない
        .interactiveDismissDisabled(!viewModel.canCancel)
        .task {
            await viewModel.start()
        }
    }

    // MARK: - 中身

    /// 段ごとの中身
    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .checking:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("準備しています")
        case let .checkFailed(message):
            checkFailedView(message: message)
        case .displayName:
            SoratomoDisplayNameStep(
                displayName: $viewModel.displayNameInput,
                errorMessage: viewModel.errorMessage,
                isSaving: viewModel.isProcessing,
                onSave: {
                    Task { await viewModel.saveDisplayName() }
                }
            )
        case .form:
            formView
        case let .primer(decision):
            SoratomoNotificationPrimerView(
                decision: decision,
                primer: dependencies.primer,
                onFinished: {
                    viewModel.finishPrimer()
                }
            )
        }
    }

    /// 表示名が要るかを確かめられなかったとき（先へは進ませず、やり直しだけを出す）
    private func checkFailedView(message: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await viewModel.start() }
            } label: {
                Text("もう一度試す")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("もう一度試す")
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// グループ名か招待コードの入力（13.3）
    private var formView: some View {
        Form {
            Section {
                switch mode {
                case .create:
                    TextField("グループ名", text: $viewModel.groupNameInput)
                        .submitLabel(.done)
                        .focused($isFormFieldFocused)
                        .disabled(viewModel.isProcessing)
                        .onSubmit(submit)
                        .accessibilityLabel("グループ名")
                case .join:
                    TextField("例: ABCD-EFGH", text: $viewModel.inviteCodeInput)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .submitLabel(.join)
                        .focused($isFormFieldFocused)
                        .disabled(viewModel.isProcessing)
                        .onSubmit(submit)
                        .accessibilityLabel("招待コード")
                        .accessibilityHint("友達から届いた8文字の招待コードを入力します")
                }
            } header: {
                Text(mode == .create ? "グループ名" : "招待コード")
            } footer: {
                // 入力の条件はいつも出す（数字は SoratomoTextRules・SoratomoInviteCode の定数と一致させる）
                switch mode {
                case .create:
                    Text("1〜\(SoratomoTextRules.groupNameMax)文字で入力してください")
                case .join:
                    Text("\(SoratomoInviteCode.length)文字の英数字です。ハイフンや空白、大文字と小文字の違いは気にしなくて大丈夫です")
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .accessibilityLabel(errorMessage)
                }
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if viewModel.isProcessing {
                            ProgressView()
                        } else {
                            Text(mode == .create ? "グループを作る" : "参加する")
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .frame(minHeight: 44)
                }
                .disabled(viewModel.isProcessing)
                .accessibilityLabel(submitAccessibilityLabel)
            }
        }
        .onAppear {
            isFormFieldFocused = true
        }
    }

    // MARK: - Private

    /// 確定する（二重の確定は ViewModel の phase で防ぐ）
    private func submit() {
        Task { await viewModel.submit() }
    }

    /// 事前説明か設定の案内を出しているか
    private var isShowingPrimer: Bool {
        if case .primer = viewModel.step { return true }
        return false
    }

    /// ナビゲーションの見出し
    private var title: String {
        mode == .create ? "グループを作る" : "招待コードで参加"
    }

    /// 閉じるボタンの VoiceOver のラベル
    private var cancelAccessibilityLabel: String {
        mode == .create ? "グループを作らずに閉じる" : "参加せずに閉じる"
    }

    /// 確定のボタンの VoiceOver のラベル
    private var submitAccessibilityLabel: String {
        if viewModel.isProcessing {
            return mode == .create ? "グループを作っています" : "参加しています"
        }
        return mode == .create ? "グループを作る" : "招待コードで参加する"
    }
}
