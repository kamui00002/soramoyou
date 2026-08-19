//
//  FollowListView.swift
//  Soramoyou
//
//  フォロワー / フォロー中一覧画面 ⭐️ Issue #2（PR-5）
//
//  プロフィールのカウンタ（フォロワー / フォロー中）タップで push 遷移して開く。
//  行 = アバター + 表示名 + bio。行タップで UserProfileView へ。
//  「自分のフォロワー一覧」でのみ、確認ダイアログ付きの削除ボタンを出す。
//
//  ⚠️ この画面は必ず NavigationView の中で push される前提
//     （ProfileView / UserProfileView の呼び出し元はいずれも NavigationView 内）。
//

import SwiftUI

struct FollowListView: View {
    // MARK: - Properties

    @StateObject private var viewModel: FollowListViewModel

    /// 削除確認ダイアログの対象（nil なら非表示）
    @State private var removalCandidate: Follow?

    // MARK: - Initializer

    init(listType: FollowListType, targetUserId: String, ownUserId: String?) {
        _viewModel = StateObject(
            wrappedValue: FollowListViewModel(
                listType: listType,
                targetUserId: targetUserId,
                ownUserId: ownUserId
            )
        )
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
        .navigationTitle(viewModel.listType.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .refreshable {
            await viewModel.fetchFirstPage()
        }
        // フォロワー削除・追加ページ取得のエラーは必ず見せる
        .alert("お知らせ", isPresented: Binding(errorMessage: $viewModel.errorMessage)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            if let message = viewModel.errorMessage {
                Text(message)
            }
        }
        // フォロワー削除の確認ダイアログ（不可逆操作なので必ず挟む）
        .confirmationDialog(
            removalConfirmationTitle,
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("フォロワーから削除", role: .destructive) {
                if let candidate = removalCandidate {
                    Task { await viewModel.removeFollower(userId: candidate.followerId) }
                }
                removalCandidate = nil
            }
            Button("キャンセル", role: .cancel) {
                removalCandidate = nil
            }
        } message: {
            Text("相手に通知されません。相手はあなたを再びフォローできます。")
        }
        // ⚠️ 画面計装は .task で行う。.onAppear は復帰のたびに複数回発火するため
        //    （cf. TagDetailView / SkyZukanView のコメント）。
        .task {
            LoggingService.shared.logScreen(
                viewModel.listType == .followers ? "フォロワー一覧" : "フォロー中一覧"
            )
            LoggingService.shared.logEvent("follow_list_opened", parameters: [
                "list_type": viewModel.listType.rawValue,
                "is_own_list": viewModel.ownUserId == viewModel.targetUserId,
            ])
            await viewModel.fetchFirstPage()
        }
    }

    /// 削除確認ダイアログのタイトル（表示名が取れていれば名前入りにする）
    private var removalConfirmationTitle: String {
        guard let candidate = removalCandidate else { return "フォロワーから削除しますか？" }
        let name = viewModel.profilesByUserId[candidate.followerId]?.displayName ?? "このユーザー"
        return "\(name)さんをフォロワーから削除しますか？"
    }

    // MARK: - Content

    /// ローディング / エラー / 空 / 一覧 の出し分け
    @ViewBuilder
    private var contentSection: some View {
        if viewModel.isLoading, viewModel.follows.isEmpty {
            LoadingStateView(type: .initial)
        } else if let error = viewModel.lastError, viewModel.follows.isEmpty {
            ErrorStateView(
                error: error,
                retryAction: { await viewModel.fetchFirstPage() },
                secondaryAction: nil,
                secondaryActionTitle: nil
            )
        } else if viewModel.follows.isEmpty {
            // 空状態は既存の EmptyStateView を文言込みでそのまま使う
            // （action を渡さないので「検索する」ボタンは出ない）
            EmptyStateView(
                type: viewModel.listType == .followers ? .followers : .following
            )
        } else {
            followList
        }
    }

    /// ユーザー一覧（ページング付き）
    private var followList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(viewModel.follows) { follow in
                    userRow(for: follow)
                        .onAppear { loadNextPageIfNeeded(currentFollow: follow) }
                }

                if viewModel.isLoadingMore {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .padding(.vertical, DesignTokens.Spacing.lg)
                }

                // タブバー分の余白
                Spacer()
                    .frame(height: 60)
            }
            .padding(.horizontal, DesignTokens.Spacing.screenMargin)
            .padding(.top, DesignTokens.Spacing.sm)
        }
    }

    // MARK: - Row

    /// ユーザー 1 行分（タップでプロフィールへ・自分の行だけ遷移なし）
    @ViewBuilder
    private func userRow(for follow: Follow) -> some View {
        let userId = viewModel.displayUserId(for: follow)
        let profile = viewModel.profilesByUserId[userId]

        HStack(spacing: DesignTokens.Spacing.md) {
            if userId == viewModel.ownUserId {
                // 自分自身の行はプロフィールタブで見るほうが自然なので遷移させない
                // （HomeView / TagDetailView の onAuthorTapped と同じ方針）
                rowContent(profile: profile)
            } else {
                NavigationLink {
                    UserProfileView(targetUserId: userId, ownUserId: viewModel.ownUserId)
                } label: {
                    rowContent(profile: profile)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(profile?.displayName ?? "ユーザー") のプロフィールを開く")
            }

            Spacer(minLength: 0)

            // フォロワー削除は「自分のフォロワー一覧」でのみ
            if viewModel.isOwnFollowersList {
                removeButton(for: follow, profile: profile)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                .fill(.ultraThinMaterial.opacity(0.4))
        )
    }

    /// 行の中身（アバター + 表示名 + bio）
    private func rowContent(profile: PublicProfile?) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            avatarView(profile: profile)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.displayName ?? "ユーザー")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let bio = profile?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
    }

    /// アバター（取得失敗・未設定はプレースホルダ）
    @ViewBuilder
    private func avatarView(profile: PublicProfile?) -> some View {
        if let urlString = profile?.photoURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    placeholderAvatar
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
        } else {
            placeholderAvatar
        }
    }

    private var placeholderAvatar: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .frame(width: 44, height: 44)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.7))
            )
    }

    /// フォロワー削除ボタン（確認ダイアログを開くだけ。削除自体は ViewModel が行う）
    private func removeButton(for follow: Follow, profile: PublicProfile?) -> some View {
        Button {
            removalCandidate = follow
        } label: {
            Text("削除")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .background(
                    Capsule().fill(Color.white.opacity(0.15))
                )
        }
        .disabled(viewModel.isRemovingFollower)
        .accessibilityLabel("\(profile?.displayName ?? "ユーザー") をフォロワーから削除")
    }

    // MARK: - Pagination

    /// 一番下の行が見えたら次ページを読む
    private func loadNextPageIfNeeded(currentFollow: Follow) {
        guard currentFollow.id == viewModel.follows.last?.id,
              !viewModel.isLoadingMore,
              viewModel.hasMore
        else { return }

        Task { await viewModel.loadMore() }
    }
}
