//
//  ReactedUsersView.swift
//  Soramoyou
//
//  「あなたの空に反応した人」一覧画面 ⭐️
//
//  プロフィールから push 遷移して開く。行 = アバター + 表示名 + 反応件数、
//  右にフォローボタン。タップで UserProfileView へ。
//
//  ⚠️ この画面は必ず NavigationView の中で push される前提（ProfileView から開く）。
//  ⚠️ 対象は「最近の投稿（最大30件）への反応」。Firestore の `in` 上限による割り切りで、
//     画面の文言もそう名乗る（すべての投稿の反応が出るかのように書かない）。
//

import SwiftUI

struct ReactedUsersView: View {
    // MARK: - Properties

    @StateObject private var viewModel: ReactedUsersViewModel

    // MARK: - Initializer

    init(ownUserId: String?) {
        _viewModel = StateObject(wrappedValue: ReactedUsersViewModel(ownUserId: ownUserId))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // 空のグラデーション背景（他画面と統一）
            LinearGradient(
                colors: DesignTokens.Colors.daySkyGradient,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            contentSection
        }
        .navigationTitle("反応してくれた人")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .refreshable {
            await viewModel.load()
        }
        .alert("お知らせ", isPresented: Binding(errorMessage: $viewModel.errorMessage)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
            }
        }
        .task {
            // push 画面なので画面ログは自前で送る（.onAppear は複数回発火するため .task）
            LoggingService.shared.logScreen("反応してくれた人")
            await viewModel.load()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentSection: some View {
        if viewModel.isLoading, viewModel.reactedUsers.isEmpty {
            LoadingStateView(type: .initial)
        } else if let error = viewModel.lastError, viewModel.reactedUsers.isEmpty {
            ErrorStateView(
                error: error,
                retryAction: { await viewModel.load() },
                secondaryAction: nil,
                secondaryActionTitle: nil
            )
        } else if viewModel.reactedUsers.isEmpty {
            EmptyStateView(type: .custom(
                icon: "heart",
                title: "まだ反応はありません",
                description: "空を投稿すると、いいねしてくれた人がここに並びます",
                actionTitle: nil
            ))
        } else {
            listSection
        }
    }

    private var listSection: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.md) {
                // ⚠️ 「最近の投稿」であることを明示する。全期間の反応が出ると誤解させない
                Text("最近の投稿に、いいねしてくれた人です")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, DesignTokens.Spacing.xs)

                ForEach(viewModel.reactedUsers) { user in
                    userRow(for: user)
                }

                // タブバー分の余白
                Spacer().frame(height: 80)
            }
            .padding(.horizontal, DesignTokens.Spacing.screenMargin)
            .padding(.top, DesignTokens.Spacing.sm)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func userRow(for user: ReactedUser) -> some View {
        let profile = viewModel.profilesByUserId[user.id]

        HStack(spacing: DesignTokens.Spacing.md) {
            if user.id == viewModel.ownUserId {
                // 自分自身は集約時に除外しているので通常は出ないが、防御的に遷移させない
                rowContent(user: user, profile: profile)
            } else {
                NavigationLink {
                    UserProfileView(targetUserId: user.id, ownUserId: viewModel.ownUserId)
                } label: {
                    // 行の余白・カード背景までタップ可能領域を広げる
                    rowContent(user: user, profile: profile)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // ⚠️ NavigationLink に accessibilityLabel を付けると、中の Text
                //    （表示名・件数）は VoiceOver から読み上げられなくなる。
                //    件数はこの一覧の主役なので accessibilityValue で明示的に戻す。
                .accessibilityLabel("\(profile?.displayName ?? "ユーザー") のプロフィールを開く")
                .accessibilityValue("\(user.reactionCount)件のいいね")
            }

            Spacer(minLength: 0)

            if viewModel.canToggleFollow(for: user.id) {
                followButton(for: user.id, profile: profile)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                .fill(.ultraThinMaterial.opacity(0.4))
        )
    }

    /// 行の中身（アバター + 表示名 + 反応件数）
    private func rowContent(user: ReactedUser, profile: PublicProfile?) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            UserAvatarView(photoURL: profile?.photoURL)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.displayName ?? "ユーザー")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                // 件数は取得した like ドキュメントから数えた実数（likesCount は使わない）
                Text("\(user.reactionCount)件のいいね")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }

    /// フォローボタン（見た目は共通部品 `FollowActionButton`）
    ///
    /// ⚠️ 文言は ViewModel の `followButtonTitle(for:)` に置く。View の private に置くと
    ///    テストで固定できず、判定の取り違えが検出できない（PR #97 の D1 の教訓）。
    private func followButton(for userId: String, profile: PublicProfile?) -> some View {
        FollowActionButton(
            title: viewModel.followButtonTitle(for: userId),
            isFollowing: viewModel.isFollowingUser(userId),
            isToggling: viewModel.isTogglingFollow(for: userId),
            displayName: profile?.displayName ?? "ユーザー"
        ) {
            Task { await viewModel.toggleFollow(userId: userId) }
        }
    }
}
