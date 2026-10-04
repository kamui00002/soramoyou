//
//  SoratomoGroupListView.swift
//  Soramoyou
//
//  そらとものグループ一覧 ⭐️
//  （tasks 13.1・design.md の SoratomoGroupListView・ViewModel・要件 5.1〜5.6・14.5・16.4）
//
//  - 所属グループを最新の活動の新しい順に並べ、各行にグループ名とメンバー数を出す。選ぶとタイムラインへ進む
//  - 「グループを作る」と「招待コードで参加」の 2 つの操作を常に出す。グループが無い間は、始め方の案内を出す
//  - 作成と参加のフォーム（13.2・13.3 の担当の `SoratomoGroupFormView`）は、ここからシートで出す
//

import SwiftUI

/// そらとものグループ一覧
struct SoratomoGroupListView: View {
    // MARK: - Properties

    /// そらともへの遷移を決めるルーター
    @ObservedObject var router: SoratomoRouter
    /// サービスの容れ物
    let dependencies: SoratomoDependencies

    /// 一覧の ViewModel
    @StateObject private var viewModel: SoratomoGroupListViewModel

    /// 出しているフォーム（作成か参加。nil なら出していない）
    @State private var formMode: SoratomoGroupFormMode?

    // MARK: - Init

    /// - Parameters:
    ///   - router: そらともへの遷移を決めるルーター
    ///   - dependencies: サービスの容れ物
    init(router: SoratomoRouter, dependencies: SoratomoDependencies) {
        self.router = router
        self.dependencies = dependencies
        _viewModel = StateObject(
            wrappedValue: SoratomoGroupListViewModel(
                groupService: dependencies.groupService,
                currentUid: dependencies.currentUid,
                // パスが空 = 入口から開いた。通知から開いたとき（パスにタイムラインがある）は soratomo_opened を記録しない
                logsOpened: router.path.isEmpty
            )
        )
    }

    // MARK: - Body

    var body: some View {
        content
            .navigationTitle("そらとも")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        router.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("そらともを閉じる")
                }
            }
            // 作成と参加の 2 つの操作は、一覧の状態に関わらず常に下に出す（要件 5.5）
            .safeAreaInset(edge: .bottom) {
                actionButtons
            }
            .sheet(item: $formMode) { mode in
                SoratomoGroupFormView(
                    mode: mode,
                    dependencies: dependencies,
                    onCompleted: { newPath in
                        // フォームが決めた行き先へ進む（作成 → タイムラインの上に招待、参加 → タイムライン）
                        formMode = nil
                        router.path = newPath
                        Task { await viewModel.load() }
                    },
                    onCancel: {
                        formMode = nil
                    }
                )
            }
            .task {
                await viewModel.load()
            }
            // タイムラインなどから一覧へ戻ったら読み直す（活動の順とメンバー数が変わっているかもしれないため）
            .onChange(of: router.path.isEmpty) { isEmpty in
                guard isEmpty else { return }
                Task { await viewModel.load() }
            }
            // 画面名の記録は根の画面（SoratomoRootView）がパスの変化で 1 回だけ行う（14.3 の点検で集約）
    }

    // MARK: - 中身

    /// 読み込みの状態ごとの中身
    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(groups) where groups.isEmpty:
            emptyGuide
        case let .loaded(groups):
            groupList(groups)
        case .error:
            errorView
        }
    }

    /// グループの一覧（選ぶとタイムラインへ進む）
    private func groupList(_ groups: [SoratomoGroup]) -> some View {
        List(groups) { group in
            NavigationLink(value: SoratomoDestination.timeline(groupId: group.id)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.body)
                        .lineLimit(1)
                    Text("\(group.memberCount)人")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            // VoiceOver では「グループ名、N人」と読む
            .accessibilityElement(children: .combine)
            .accessibilityHint("タイムラインを開きます")
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.load()
        }
    }

    /// グループが無い間の案内（要件 5.4）
    private var emptyGuide: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("まだグループがありません")
                .font(.headline)
            Text("グループを作るか、招待コードで参加して始めましょう")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 読み込みの失敗（固定の文言と、読み直しの操作）
    private var errorView: some View {
        VStack(spacing: 12) {
            Text(viewModel.errorMessage ?? SoratomoError.unknown.userMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("もう一度読み込む") {
                Task { await viewModel.load() }
            }
            .accessibilityHint("グループの一覧を読み直します")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 「グループを作る」と「招待コードで参加」の 2 つの操作
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                formMode = .create
            } label: {
                Label("グループを作る", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("グループを作る")

            Button {
                formMode = .join
            } label: {
                Label("招待コードで参加", systemImage: "ticket")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("招待コードで参加")
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
