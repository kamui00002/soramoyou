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
            VStack(spacing: 0) {
                ZStack {
                    if viewModel.isLoading && viewModel.user == nil {
                        // 初回読み込み中
                        ProgressView("読み込み中...")
                    } else if let user = viewModel.user {
                        // プロフィール表示
                        profileContent(user: user)
                    } else {
                        // ユーザー情報が取得できない場合
                        VStack(spacing: 16) {
                            Image(systemName: "person.circle")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("プロフィール情報を取得できませんでした")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // 画面下部に固定表示されるバナー広告
                BannerAdContainer()
            }
            .navigationTitle("プロフィール")
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
                                Label("編集装備設定", systemImage: "wrench.and.screwdriver")
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
            .alert("エラー", isPresented: .constant(viewModel.errorMessage != nil)) {
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
                
                // 投稿一覧セクション
                postsSection
            }
            .padding()
        }
    }
    
    // MARK: - Profile Info Section
    
    private func profileInfoSection(user: User) -> some View {
        VStack(spacing: 16) {
            // プロフィール画像
            profileImageView(photoURL: user.photoURL)
            
            // 表示名
            if let displayName = user.displayName {
                Text(displayName)
                    .font(.title2)
                    .fontWeight(.bold)
            } else {
                Text("ユーザー")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
            }
            
            // 自己紹介
            if let bio = user.bio {
                Text(bio)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            // 統計情報
            statsSection(user: user)
        }
    }
    
    // MARK: - Profile Image View
    
    private func profileImageView(photoURL: String?) -> some View {
        Group {
            if let photoURL = photoURL, let url = URL(string: photoURL) {
                KFImage(url)
                    .placeholder {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 100))
                            .foregroundColor(.gray)
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                    )
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 100))
                    .foregroundColor(.gray)
            }
        }
    }
    
    // MARK: - Stats Section
    
    private func statsSection(user: User) -> some View {
        HStack(spacing: 32) {
            // 投稿数
            VStack(spacing: 4) {
                Text("\(user.postsCount)")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("投稿")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // フォロワー数
            VStack(spacing: 4) {
                Text("\(user.followersCount)")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("フォロワー")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // フォロー数
            VStack(spacing: 4) {
                Text("\(user.followingCount)")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("フォロー中")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical)
    }
    
    // MARK: - Posts Section
    
    private var postsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // セクションヘッダー
            HStack {
                Text("投稿")
                    .font(.headline)
                
                Spacer()
                
                if viewModel.isLoadingPosts {
                    ProgressView()
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
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text(viewModel.isOwnProfile ? "まだ投稿がありません" : "投稿がありません")
                .font(.headline)
                .foregroundColor(.secondary)
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
    
    var body: some View {
        Group {
            if let firstImage = post.images.first, let url = URL(string: firstImage.url) {
                KFImage(url)
                    .placeholder {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay(
                                ProgressView()
                            )
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 120)
                    .clipped()
                    .cornerRadius(8)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 120)
                    .cornerRadius(8)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                    )
            }
        }
    }
}

struct ProfileView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileView()
    }
}


