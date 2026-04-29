//
//  UserProfileView.swift
//  Soramoyou
//
//  他ユーザーのプロフィール画面 ⭐️ Issue #2
//
//  投稿カードから著者名/アバターをタップして遷移し、フォロー操作を行える。
//

import SwiftUI

struct UserProfileView: View {
    @StateObject private var viewModel: UserProfileViewModel
    @Environment(\.dismiss) private var dismiss

    init(targetUserId: String, ownUserId: String?) {
        _viewModel = StateObject(
            wrappedValue: UserProfileViewModel(
                targetUserId: targetUserId,
                ownUserId: ownUserId
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.Spacing.lg) {
                headerSection
                if !viewModel.isOwnProfile {
                    followButton
                }
                statsRow
                postsGrid
            }
            .padding(DesignTokens.Spacing.screenMargin)
        }
        .background(DesignTokens.Colors.detailBackground.ignoresSafeArea())
        .navigationTitle(viewModel.user?.displayName ?? "プロフィール")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
        }
        .alert("エラー", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            avatarView
            Text(viewModel.user?.displayName ?? "ユーザー")
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
            if let bio = viewModel.user?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, DesignTokens.Spacing.lg)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let urlString = viewModel.user?.photoURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholderAvatar
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1))
            .accessibilityLabel("\(viewModel.user?.displayName ?? "ユーザー") のプロフィール画像")
        } else {
            placeholderAvatar
                .accessibilityLabel("\(viewModel.user?.displayName ?? "ユーザー") のプロフィール画像")
        }
    }

    private var placeholderAvatar: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .frame(width: 96, height: 96)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.7))
            )
    }

    // MARK: - Follow Button

    private var followButton: some View {
        Button {
            Task { await viewModel.toggleFollow() }
        } label: {
            HStack(spacing: 6) {
                if viewModel.isFollowOperationInFlight {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: viewModel.isFollowing ? "checkmark" : "plus")
                }
                Text(viewModel.isFollowing ? "フォロー中" : "フォロー")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(viewModel.isFollowing
                          ? Color.white.opacity(0.15)
                          : DesignTokens.Colors.skyBlue)
            )
            .foregroundColor(.white)
        }
        .accessibilityLabel(viewModel.isFollowing ? "フォロー解除" : "フォローする")
        .disabled(viewModel.isFollowOperationInFlight)
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            statItem(value: viewModel.user?.postsCount ?? 0, label: "投稿")
            statItem(value: viewModel.user?.followersCount ?? 0, label: "フォロワー")
            statItem(value: viewModel.user?.followingCount ?? 0, label: "フォロー中")
        }
        .padding(.vertical, DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial.opacity(0.4))
        )
    }

    private func statItem(value: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title3.weight(.bold))
                .foregroundColor(.white)
            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Posts Grid

    private var postsGrid: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .padding(.top, 40)
            } else if viewModel.posts.isEmpty {
                Text("投稿がありません")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.top, 40)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 4),
                        GridItem(.flexible(), spacing: 4),
                        GridItem(.flexible(), spacing: 4)
                    ],
                    spacing: 4
                ) {
                    ForEach(viewModel.posts) { post in
                        if let firstImage = post.images.first,
                           let url = URL(string: firstImage.thumbnail ?? firstImage.url) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    Color.gray.opacity(0.3)
                                }
                            }
                            .frame(height: 120)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }
}
