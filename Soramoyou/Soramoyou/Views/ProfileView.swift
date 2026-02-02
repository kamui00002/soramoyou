//
//  ProfileView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import Kingfisher

struct ProfileView: View {
    let userId: String?
    
    @StateObject private var viewModel: ProfileViewModel
    @State private var selectedPost: Post?
    @State private var showingEditProfile = false
    @State private var showingEditTools = false
    @State private var displayMode: DisplayMode = .grid
    
    enum DisplayMode {
        case grid
        case list
    }
    
    init(userId: String? = nil) {
        self.userId = userId
        _viewModel = StateObject(wrappedValue: ProfileViewModel(userId: userId))
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // 空のグラデーション背景
                LinearGradient(
                    colors: [
                        Color(red: 0.68, green: 0.85, blue: 0.90),
                        Color(red: 0.53, green: 0.81, blue: 0.98),
                        Color(red: 0.39, green: 0.58, blue: 0.93)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    ZStack {
                        if viewModel.isLoading && viewModel.user == nil {
                            // 初回読み込み中
                            VStack {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("読み込み中...")
                                    .foregroundColor(.white)
                            }
                        } else if let user = viewModel.user {
                            // プロフィール表示
                            profileContent(user: user)
                        } else {
                            // ユーザー情報が取得できない場合
                            VStack(spacing: DesignTokens.Spacing.md) {
                                Image(systemName: "person.circle")
                                    .font(.system(size: 60))
                                    .foregroundColor(DesignTokens.Colors.textTertiary)
                                Text("プロフィール情報を取得できませんでした")
                                    .font(.headline)
                                    .foregroundColor(DesignTokens.Colors.textSecondary)
                            }
                        }
                    }
                    
                    // 画面下部に固定表示されるバナー広告
                    BannerAdContainer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    GradientTitleView(title: "プロフィール", fontSize: 20)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.isOwnProfile {
                        Menu {
                            Button(action: {
                                showingEditProfile = true
                            }) {
                                Label("プロフィール編集", systemImage: "pencil")
                            }
                            
                            Button(action: {
                                showingEditTools = true
                            }) {
                                Label("おすすめ編集設定", systemImage: "slider.horizontal.3")
                            }
                            
                            Divider()
                            
                            Button(action: {
                                // 表示モード切り替え
                                displayMode = displayMode == .grid ? .list : .grid
                            }) {
                                Label(
                                    displayMode == .grid ? "リスト表示" : "グリッド表示",
                                    systemImage: displayMode == .grid ? "list.bullet" : "square.grid.2x2"
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundColor(.white)
                        }
                    } else {
                        // 他ユーザーのプロフィールの場合、表示モード切り替えのみ
                        Menu {
                            Button(action: {
                                displayMode = displayMode == .grid ? .list : .grid
                            }) {
                                Label(
                                    displayMode == .grid ? "リスト表示" : "グリッド表示",
                                    systemImage: displayMode == .grid ? "list.bullet" : "square.grid.2x2"
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundColor(.white)
                        }
                    }
                }
            }
            .onAppear {
                Task {
                    await viewModel.loadProfile()
                    await viewModel.loadUserPosts()
                }
            }
            .refreshable {
                await viewModel.loadProfile()
                await viewModel.loadUserPosts()
            }
            .alert("エラー", isPresented: Binding(errorMessage: $viewModel.errorMessage)) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                }
            }
            .sheet(isPresented: $showingEditProfile) {
                if viewModel.isOwnProfile {
                    ProfileEditView(viewModel: viewModel)
                }
            }
            .sheet(isPresented: $showingEditTools) {
                if viewModel.isOwnProfile {
                    EditToolsSettingsView(viewModel: viewModel)
                }
            }
            .sheet(item: $selectedPost) { post in
                PostDetailView(post: post)
            }
        }
    }
    
    // MARK: - Profile Content
    
    private func profileContent(user: User) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // プロフィール情報セクション
                profileInfoSection(user: user)
                
                Divider()
                    .background(.white.opacity(0.3))
                
                // 投稿一覧セクション
                postsSection
            }
            .padding()
        }
    }
    
    // MARK: - Profile Info Section ☁️

    private func profileInfoSection(user: User) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            // プロフィール画像
            profileImageView(photoURL: user.photoURL)

            // 表示名
            if let displayName = user.displayName {
                Text(displayName)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                    .shadow(DesignTokens.Shadow.text)
            } else {
                Text("ユーザー")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }

            // 自己紹介
            if let bio = user.bio {
                Text(bio)
                    .font(.body)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // 統計情報
            statsSection(user: user)
        }
    }

    // MARK: - Profile Image View ☁️

    private func profileImageView(photoURL: String?) -> some View {
        Group {
            if let photoURL = photoURL, let url = URL(string: photoURL) {
                KFImage(url)
                    .placeholder {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 100))
                            .foregroundColor(DesignTokens.Colors.textTertiary)
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 2)
                    )
                    .shadow(DesignTokens.Shadow.medium)
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 100))
                    .foregroundColor(DesignTokens.Colors.textTertiary)
            }
        }
    }

    // MARK: - Stats Section ☁️

    private func statsSection(user: User) -> some View {
        HStack(spacing: 0) {
            // 投稿数
            statItem(value: user.postsCount, label: "投稿", icon: "photo.on.rectangle")

            // 区切り線
            Rectangle()
                .fill(DesignTokens.Colors.glassBorderSecondary)
                .frame(width: 1, height: 40)

            // フォロワー数
            statItem(value: user.followersCount, label: "フォロワー", icon: "person.2")

            // 区切り線
            Rectangle()
                .fill(DesignTokens.Colors.glassBorderSecondary)
                .frame(width: 1, height: 40)

            // フォロー数
            statItem(value: user.followingCount, label: "フォロー中", icon: "heart")
        }
        .padding(.vertical, DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .stroke(
                        LinearGradient(
                            colors: [
                                DesignTokens.Colors.glassBorderAccentStart,
                                DesignTokens.Colors.glassBorderAccentEnd
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        .shadow(DesignTokens.Shadow.card)
    }

    private func statItem(value: Int, label: String, icon: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textPrimary)

            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: DesignTokens.Typography.smallCaptionSize, weight: .medium, design: .rounded))
            }
            .foregroundColor(DesignTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Posts Section ☁️

    private var postsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            // セクションヘッダー
            HStack {
                Text("投稿")
                    .font(.headline)
                    .foregroundColor(DesignTokens.Colors.textPrimary)

                Spacer()

                if viewModel.isLoadingPosts {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                }
            }

            // 投稿一覧
            if viewModel.userPosts.isEmpty {
                emptyPostsView
            } else {
                postsContentView
            }
        }
    }

    private var emptyPostsView: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 60))
                .foregroundColor(DesignTokens.Colors.textTertiary)
            Text(viewModel.isOwnProfile ? "まだ投稿がありません" : "投稿がありません")
                .font(.headline)
                .foregroundColor(DesignTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private var postsContentView: some View {
        Group {
            if displayMode == .grid {
                // グリッド表示
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(viewModel.userPosts) { post in
                        PostGridItem(post: post)
                            .onTapGesture {
                                selectedPost = post
                            }
                    }
                }
            } else {
                // リスト表示
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.userPosts) { post in
                        PostCard(post: post)
                            .onTapGesture {
                                selectedPost = post
                            }
                    }
                }
            }
        }
    }
}

// MARK: - Post Grid Item

struct PostGridItem: View {
    let post: Post
    @State private var isPressed = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let firstImage = post.images.first, let url = URL(string: firstImage.url) {
                    KFImage(url)
                        .placeholder {
                            Rectangle()
                                .fill(DesignTokens.Colors.glassTertiary)
                                .overlay(
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                )
                                .shimmer()
                        }
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 120)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(DesignTokens.Colors.glassTertiary)
                        .frame(height: 120)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 24))
                                .foregroundColor(DesignTokens.Colors.textTertiary)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                    .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 0.5)
            )

            // 複数画像インジケーター
            if post.images.count > 1 {
                Image(systemName: "square.on.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.5))
                    )
                    .padding(6)
            }
        }
        .shadow(DesignTokens.Shadow.soft)
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .animation(DesignTokens.Animation.quickSpring, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

struct ProfileView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileView()
    }
}


