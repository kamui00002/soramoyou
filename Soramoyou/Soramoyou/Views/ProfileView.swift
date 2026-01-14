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
                            VStack(spacing: 16) {
                                Image(systemName: "person.circle")
                                    .font(.system(size: 60))
                                    .foregroundColor(.white.opacity(0.6))
                                Text("プロフィール情報を取得できませんでした")
                                    .font(.headline)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                    }
                    
                    // 画面下部に固定表示されるバナー広告
                    BannerAdContainer()
                }
            }
            .navigationTitle("プロフィール")
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
                    .background(.white.opacity(0.3))
                
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
                    .foregroundColor(.white)
            } else {
                Text("ユーザー")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white.opacity(0.8))
            }
            
            // 自己紹介
            if let bio = user.bio {
                Text(bio)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.9))
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
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.4), lineWidth: 2)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 100))
                    .foregroundColor(.white.opacity(0.6))
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
                    .foregroundColor(.white)
                Text("投稿")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            
            // フォロワー数
            VStack(spacing: 4) {
                Text("\(user.followersCount)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text("フォロワー")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            
            // フォロー数
            VStack(spacing: 4) {
                Text("\(user.followingCount)")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                Text("フォロー中")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.vertical)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.white.opacity(0.15))
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(.white.opacity(0.3), lineWidth: 1)
                )
        )
    }
    
    // MARK: - Posts Section
    
    private var postsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // セクションヘッダー
            HStack {
                Text("投稿")
                    .font(.headline)
                    .foregroundColor(.white)
                
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
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.6))
            Text(viewModel.isOwnProfile ? "まだ投稿がありません" : "投稿がありません")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
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


