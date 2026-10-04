//
//  SoratomoMembersView.swift
//  Soramoyou
//
//  そらとものメンバー一覧 ⭐️
//  （tasks 13.9・design.md の SoratomoMembersView・ViewModel・要件 14.5・16.4・19.1・19.2・19.3）
//
//  - タイムラインから開く。グループのメンバー全員の表示名とアイコンを出す
//  - 並びは、オーナーを先頭に、その後は参加順（並べるのは ViewModel）。オーナーに印を付ける
//  - 表示名とアイコンは `SoratomoProfileStore` から出す。未設定・未取得は既存の画面と同じ代替
//    （名前は「ユーザー」・アイコンは `UserAvatarView` のプレースホルダー）。uid から作った文字は使わない
//  - ⚠️ init のシグネチャ（groupId:dependencies:）は変えない（呼び出し側の SoratomoRootView が使うため）
//

import SwiftUI

/// グループのメンバー一覧
struct SoratomoMembersView: View {
    // MARK: - Properties

    /// 表示するグループの ID
    let groupId: String
    /// サービスの容れ物
    let dependencies: SoratomoDependencies

    /// メンバー一覧の ViewModel
    @StateObject private var viewModel: SoratomoMembersViewModel
    /// 表示名とアイコンの保持（容れ物は ObservableObject ではないので、変化を画面に出すため別に持つ）
    @ObservedObject private var profileStore: SoratomoProfileStore

    // MARK: - Init

    /// - Parameters:
    ///   - groupId: 表示するグループの ID
    ///   - dependencies: サービスの容れ物
    init(groupId: String, dependencies: SoratomoDependencies) {
        self.groupId = groupId
        self.dependencies = dependencies
        _viewModel = StateObject(
            wrappedValue: SoratomoMembersViewModel(
                groupId: groupId,
                groupService: dependencies.groupService
            )
        )
        _profileStore = ObservedObject(wrappedValue: dependencies.profileStore)
    }

    // MARK: - Body

    var body: some View {
        content
            .navigationTitle("メンバー")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await reload()
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
        case let .loaded(members):
            memberList(members)
        case .error:
            errorView
        }
    }

    /// メンバーの一覧（オーナーが先頭・その後は参加順）
    private func memberList(_ members: [SoratomoMember]) -> some View {
        List(members) { member in
            memberRow(member)
        }
        .listStyle(.plain)
        .refreshable {
            await reload()
        }
    }

    /// メンバー 1 人の行（アイコン・表示名・オーナーの印）
    private func memberRow(_ member: SoratomoMember) -> some View {
        let isOwner = member.role == .owner
        return HStack(spacing: 12) {
            // アイコン（写真が無い・取れていない間はプレースホルダー。既存のフォロー一覧と同じ部品）
            UserAvatarView(photoURL: profileStore.photoURL(for: member.id)?.absoluteString)
                .accessibilityHidden(true)

            Text(profileStore.displayName(for: member.id))
                .font(.body)
                .lineLimit(1)

            Spacer(minLength: 8)

            if isOwner {
                // オーナーの印（要件 19.3）
                Label("オーナー", systemImage: "crown.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
            }
        }
        .padding(.vertical, 4)
        // VoiceOver では「表示名、オーナー」と 1 つにまとめて読む
        .accessibilityElement(children: .combine)
    }

    /// 読み込みの失敗（固定の文言と、読み直しの操作）
    private var errorView: some View {
        VStack(spacing: 12) {
            Text(viewModel.errorMessage ?? SoratomoError.unknown.userMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("もう一度読み込む") {
                Task { await reload() }
            }
            .accessibilityLabel("もう一度読み込む")
            .accessibilityHint("メンバーの一覧を読み直します")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Private Methods

    /// メンバーを読み、読めたメンバーの表示名とアイコンを取りに行く
    ///
    /// 取得済みの uid は `prefetch` が取りに行かないので、何度呼んでもよい
    private func reload() async {
        await viewModel.load()
        await profileStore.prefetch(uids: viewModel.memberUids)
    }
}
