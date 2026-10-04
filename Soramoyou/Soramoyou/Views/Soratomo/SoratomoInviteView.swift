//
//  SoratomoInviteView.swift
//  Soramoyou
//
//  そらともの招待コードの共有と再発行 ⭐️
//  （tasks 13.4・design.md の SoratomoInviteView・ViewModel・要件 3.4〜3.8・3.11・3.12・14.5・16.4）
//
//  - 招待コードを「XXXX-XXXX」の形で大きく出し、共有（招待文の 4 行を共有シートへ）とコピーの 2 つの操作を置く
//  - 再発行の操作はオーナーにだけ出し、確認を出してから行う
//  - タイムラインからこの画面へ進む導線は、タイムラインの担当（13.5）が置く（要件 3.7）
//  ⚠️ init のシグネチャは変えない（呼び出し側の SoratomoRootView を、担当は触らないため）。
//

import SwiftUI
import UIKit

/// 招待コードの共有と再発行
///
/// グループ名・招待コード・オーナーは `observeGroup` で取り、オーナーかどうかは `dependencies.currentUid()` と
/// `ownerId` を比べて決める。
struct SoratomoInviteView: View {
    // MARK: - Properties

    /// 表示するグループの ID
    let groupId: String
    /// サービスの容れ物
    let dependencies: SoratomoDependencies

    /// 招待の ViewModel
    @StateObject private var viewModel: SoratomoInviteViewModel

    /// 共有シートを出しているか
    @State private var isShowingShareSheet = false
    /// 共有シートに渡す招待文（ボタンを押した時点の内容で固定する）
    @State private var shareText = ""
    /// 再発行の確認を出しているか
    @State private var isConfirmingRegenerate = false

    // MARK: - Init

    /// - Parameters:
    ///   - groupId: 表示するグループの ID
    ///   - dependencies: サービスの容れ物
    init(groupId: String, dependencies: SoratomoDependencies) {
        self.groupId = groupId
        self.dependencies = dependencies
        _viewModel = StateObject(
            wrappedValue: SoratomoInviteViewModel(
                groupId: groupId,
                groupService: dependencies.groupService,
                currentUid: dependencies.currentUid
            )
        )
    }

    // MARK: - Body

    var body: some View {
        content
            .navigationTitle("友達を招待")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // 画面名「そらとも招待」を記録し、グループの監視を始める（張り直しは ViewModel が防ぐ）
                SoratomoAnalytics.screen(.invite)
                viewModel.start()
            }
            .sheet(isPresented: $isShowingShareSheet) {
                SoratomoInviteActivitySheet(text: shareText)
            }
            .confirmationDialog(
                "招待コードを再発行しますか？",
                isPresented: $isConfirmingRegenerate,
                titleVisibility: .visible
            ) {
                Button("再発行する", role: .destructive) {
                    Task { await viewModel.regenerate() }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("いまの招待コードは使えなくなります。")
            }
            .alert(
                viewModel.regenerateErrorMessage ?? "",
                isPresented: Binding(
                    get: { viewModel.regenerateErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.regenerateErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            }
    }

    /// 読み込みの状態に応じた中身
    @ViewBuilder
    private var content: some View {
        if let inviteCode = viewModel.inviteCode {
            loadedContent(inviteCode: inviteCode)
        } else if let message = viewModel.loadErrorMessage {
            // グループを一度も読めなかった（メンバーでない・通信できないなど）。固定の文言だけを出す
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            .padding()
        } else {
            ProgressView()
        }
    }

    /// 招待コードを読めた後の中身
    private func loadedContent(inviteCode: SoratomoInviteCode) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                if let groupName = viewModel.groupName {
                    Text("「\(groupName)」に友達を招待しよう")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }

                // 招待コード（4 文字ごとにハイフンで区切る・要件 3.4）
                VStack(spacing: 8) {
                    Text("招待コード")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(inviteCode.displayText)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)
                        .accessibilityLabel("招待コード \(inviteCode.displayText)")
                }
                .padding(.vertical, 8)

                actionButtons

                if viewModel.isOwner {
                    regenerateSection
                }
            }
            .padding()
        }
    }

    /// 共有とコピーの 2 つの操作
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                guard let text = viewModel.inviteText else { return }
                shareText = text
                // 「共有シートを開いた」ときに記録する（要件 14 の表）
                viewModel.recordShareSheetOpened()
                isShowingShareSheet = true
            } label: {
                Label("招待文を共有", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("招待文を共有する")
            .accessibilityHint("グループ名と招待コードを含む招待文を、ほかのアプリで送ります")

            Button {
                viewModel.copyInviteCode()
            } label: {
                Label(
                    viewModel.didCopy ? "コピーしました" : "コードをコピー",
                    systemImage: viewModel.didCopy ? "checkmark" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(viewModel.didCopy ? "招待コードをコピーしました" : "招待コードをコピーする")
        }
    }

    /// 再発行の操作（オーナーにだけ出す・要件 3.8）
    private var regenerateSection: some View {
        VStack(spacing: 8) {
            Button {
                isConfirmingRegenerate = true
            } label: {
                if viewModel.isRegenerating {
                    ProgressView()
                } else {
                    Label("招待コードを再発行", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(viewModel.isRegenerating)
            .accessibilityLabel("招待コードを再発行する")
            .accessibilityHint("いまの招待コードは使えなくなり、新しいコードに変わります")

            Text("再発行すると、いまの招待コードでは参加できなくなります。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
    }
}

// MARK: - 共有シート

/// 招待文を渡す共有シート（UIActivityViewController を SwiftUI で包む）
///
/// iOS 16 の `ShareLink` は押した瞬間に処理を差し込めず、「共有シートを開いた」記録が取りにくいので、
/// ボタンの操作で記録してから、このシートを出す。
private struct SoratomoInviteActivitySheet: UIViewControllerRepresentable {
    /// 共有する招待文
    let text: String

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
