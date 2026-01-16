//
//  HomeView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import Kingfisher

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var selectedPost: Post?
    
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
                        if viewModel.isLoading && viewModel.posts.isEmpty {
                            // 初回読み込み中
                            VStack {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("読み込み中...")
                                    .foregroundColor(.white)
                            }
                        } else if viewModel.posts.isEmpty {
                            // 投稿がない場合
                            VStack(spacing: 16) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 60))
                                    .foregroundColor(.white.opacity(0.8))
                                Text("投稿がありません")
                                    .font(.headline)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        } else {
                            // フィード表示
                            feedView
                        }
                    }

                    // 画面下部に固定表示されるバナー広告
                    BannerAdContainer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    AppTitleView()
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .refreshable {
                await viewModel.refresh()
            }
            .onAppear {
                Task {
                    await viewModel.fetchPosts()
                }
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
            .sheet(item: $selectedPost) { post in
                PostDetailView(post: post)
            }
        }
    }
    
    // MARK: - Feed View
    
    private var feedView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(viewModel.posts) { post in
                    PostCard(post: post)
                        .onTapGesture {
                            selectedPost = post
                        }
                        .onAppear {
                            // ページネーション: 最後の投稿が表示されたら次のページを読み込む
                            if post.id == viewModel.posts.last?.id {
                                Task {
                                    await viewModel.loadMorePosts()
                                }
                            }
                        }
                }
                
                // 追加読み込み中のインジケーター
                if viewModel.isLoadingMore {
                    ProgressView()
                        .padding()
                }
                
                // これ以上投稿がない場合
                if !viewModel.hasMorePosts && !viewModel.posts.isEmpty {
                    Text("すべての投稿を表示しました")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .padding()
        }
    }
}

// MARK: - Post Card

struct PostCard: View {
    let post: Post
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 画像表示（サムネイル優先、遅延読み込み）
            if let firstImage = post.images.first {
                PostImageView(imageInfo: firstImage)
            }
            
            // 投稿情報
            VStack(alignment: .leading, spacing: 8) {
                // キャプション
                if let caption = post.caption {
                    Text(caption)
                        .font(.body)
                        .lineLimit(3)
                }
                
                // ハッシュタグ
                if let hashtags = post.hashtags, !hashtags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(hashtags, id: \.self) { hashtag in
                                Text("#\(hashtag)")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                
                // 位置情報
                if let location = post.location {
                    HStack {
                        Image(systemName: "location")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if let city = location.city, let prefecture = location.prefecture {
                            Text("\(prefecture) \(city)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // 空の種類・時間帯
                HStack(spacing: 12) {
                    if let skyType = post.skyType {
                        Label(skyType.displayName, systemImage: "cloud")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let timeOfDay = post.timeOfDay {
                        Label(timeOfDay.displayName, systemImage: "clock")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // 統計情報
                HStack(spacing: 16) {
                    Label("\(post.likesCount)", systemImage: "heart")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Label("\(post.commentsCount)", systemImage: "bubble.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
        )
        .cornerRadius(16)
    }
}

// MARK: - Post Image View

struct PostImageView: View {
    let imageInfo: ImageInfo
    @State private var isLoading = true
    
    var body: some View {
        // サムネイルを優先的に表示
        if let thumbnailURL = imageInfo.thumbnail, let url = URL(string: thumbnailURL) {
            KFImage(url)
                .placeholder {
                    ProgressView()
                }
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 300)
                .clipped()
        } else if let imageURL = URL(string: imageInfo.url) {
            // サムネイルがない場合はフルサイズ画像を表示
            KFImage(imageURL)
                .placeholder {
                    ProgressView()
                }
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 300)
                .clipped()
        } else {
            // URLが無効な場合
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 300)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                )
        }
    }
}

// MARK: - Post Detail View

struct PostDetailView: View {
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = PostDetailViewModel()
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 投稿者情報
                    if let user = viewModel.author {
                        authorSection(user: user)
                    } else if viewModel.isLoadingAuthor {
                        HStack {
                            ProgressView()
                            Text("投稿者情報を読み込み中...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    }
                    
                    // フルサイズ画像
                    if let firstImage = post.images.first {
                        PostDetailImageView(imageInfo: firstImage)
                    }
                    
                    // 投稿情報
                    VStack(alignment: .leading, spacing: 12) {
                        // キャプション
                        if let caption = post.caption {
                            Text(caption)
                                .font(.body)
                        }
                        
                        // ハッシュタグ
                        if let hashtags = post.hashtags, !hashtags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(hashtags, id: \.self) { hashtag in
                                        Text("#\(hashtag)")
                                            .font(.body)
                                            .foregroundColor(.blue)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.blue.opacity(0.1))
                                            .cornerRadius(12)
                                    }
                                }
                            }
                        }
                        
                        // 位置情報
                        if let location = post.location {
                            HStack {
                                Image(systemName: "location.fill")
                                    .foregroundColor(.blue)
                                if let city = location.city, let prefecture = location.prefecture {
                                    Text("\(prefecture) \(city)")
                                        .font(.body)
                                }
                                if let landmark = location.landmark {
                                    Text("（\(landmark)）")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        // 空の種類・時間帯・色温度
                        VStack(alignment: .leading, spacing: 8) {
                            if let skyType = post.skyType {
                                Label(skyType.displayName, systemImage: "cloud.fill")
                                    .font(.body)
                            }
                            if let timeOfDay = post.timeOfDay {
                                Label(timeOfDay.displayName, systemImage: "clock.fill")
                                    .font(.body)
                            }
                            if let colorTemperature = post.colorTemperature {
                                Label("\(colorTemperature)K", systemImage: "thermometer")
                                    .font(.body)
                            }
                        }
                        
                        // 統計情報
                        HStack(spacing: 24) {
                            Label("\(post.likesCount)", systemImage: "heart.fill")
                                .font(.headline)
                            Label("\(post.commentsCount)", systemImage: "bubble.right.fill")
                                .font(.headline)
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
            .navigationTitle("投稿詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                Task {
                    await viewModel.loadAuthor(userId: post.userId)
                }
            }
        }
    }
    
    // MARK: - Author Section
    
    private func authorSection(user: User) -> some View {
        HStack(spacing: 12) {
            // プロフィール画像
            if let photoURL = user.photoURL, let url = URL(string: photoURL) {
                KFImage(url)
                    .placeholder {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(
                                Image(systemName: "person.fill")
                                    .foregroundColor(.gray)
                            )
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 50, height: 50)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundColor(.gray)
                    )
            }
            
            // ユーザー情報
            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName ?? "ユーザー")
                    .font(.headline)
                
                if let email = user.email {
                    Text(email)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Post Detail ViewModel

@MainActor
class PostDetailViewModel: ObservableObject {
    @Published var author: User?
    @Published var isLoadingAuthor = false
    @Published var errorMessage: String?
    
    private let firestoreService: FirestoreServiceProtocol
    
    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }
    
    func loadAuthor(userId: String) async {
        isLoadingAuthor = true
        errorMessage = nil
        
        do {
            author = try await firestoreService.fetchUser(userId: userId)
        } catch {
            errorMessage = "投稿者情報の取得に失敗しました: \(error.localizedDescription)"
        }
        
        isLoadingAuthor = false
    }
}

// MARK: - Post Detail Image View

struct PostDetailImageView: View {
    let imageInfo: ImageInfo
    
    var body: some View {
        // フルサイズ画像を表示
        if let imageURL = URL(string: imageInfo.url) {
            KFImage(imageURL)
                .placeholder {
                    ProgressView()
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 300)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                )
        }
    }
}

// MARK: - App Title View

struct AppTitleView: View {
    var body: some View {
        GradientTitleView(title: "そらもよう", fontSize: 32)
    }
}

// MARK: - Gradient Title View (共通コンポーネント)

struct GradientTitleView: View {
    let title: String
    var fontSize: CGFloat = 20

    var body: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        Color(red: 0.4, green: 0.6, blue: 0.9),   // 明るい空色
                        Color(red: 0.3, green: 0.5, blue: 0.85),  // 中間の青
                        Color(red: 0.5, green: 0.3, blue: 0.8)    // 夕暮れのパープル
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .shadow(color: Color(red: 0.4, green: 0.6, blue: 0.9).opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
    }
}


