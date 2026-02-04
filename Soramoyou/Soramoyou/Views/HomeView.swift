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
    @State private var animateCards = false  // フィードアニメーション用 ☀️

    var body: some View {
        NavigationView {
            ZStack {
                // 空のグラデーション背景 ☁️
                LinearGradient(
                    colors: DesignTokens.Colors.daySkyGradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    ZStack {
                        if viewModel.isLoading && viewModel.posts.isEmpty {
                            // 初回読み込み中 ☁️
                            LoadingStateView(type: .initial)
                        } else if let error = viewModel.lastError, viewModel.posts.isEmpty {
                            // エラー発生時（投稿が空の場合）☁️
                            ErrorStateView(
                                error: error,
                                retryAction: {
                                    await viewModel.refresh()
                                },
                                secondaryAction: nil,
                                secondaryActionTitle: nil
                            )
                        } else if viewModel.posts.isEmpty {
                            // 投稿がない場合 ☁️
                            EmptyStateView(type: .posts) {
                                // 投稿タブに切り替える（TabViewの切り替えはMainTabViewで管理）
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
                    // フィードアニメーションを開始
                    withAnimation {
                        animateCards = true
                    }
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
    
    // MARK: - Feed View ☀️

    private var feedView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: DesignTokens.Spacing.lg) {
                ForEach(Array(viewModel.posts.enumerated()), id: \.element.id) { index, post in
                    PostCard(post: post)
                        // スタガードアニメーション（改善）
                        .opacity(animateCards ? 1 : 0)
                        .offset(y: animateCards ? 0 : 30)
                        .scaleEffect(animateCards ? 1 : 0.95)
                        .animation(
                            DesignTokens.Animation.smoothSpring
                            .delay(Double(index) * DesignTokens.Animation.staggerDelay),
                            value: animateCards
                        )
                        .onTapGesture {
                            // ハプティックフィードバック
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            selectedPost = post
                        }
                        .onAppear {
                            // ページネーション: 最後の投稿が表示されたら次のページを読み込む ☁️
                            // 重複リクエスト防止: 読み込み中の場合はスキップ
                            if post.id == viewModel.posts.last?.id
                                && !viewModel.isLoadingMore
                                && viewModel.hasMorePosts {
                                Task {
                                    await viewModel.loadMorePosts()
                                }
                            }
                        }
                }

                // 追加読み込み中のインジケーター
                if viewModel.isLoadingMore {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("読み込み中...")
                            .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium, design: .rounded))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                    .padding(.vertical, DesignTokens.Spacing.lg)
                }

                // これ以上投稿がない場合
                if !viewModel.hasMorePosts && !viewModel.posts.isEmpty {
                    VStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 24))
                            .foregroundColor(DesignTokens.Colors.success)
                        Text("すべての投稿を表示しました")
                            .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium, design: .rounded))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                    .padding(.vertical, DesignTokens.Spacing.xl)
                }

                // タブバー分の余白
                Spacer()
                    .frame(height: 100)
            }
            .padding(.horizontal, DesignTokens.Spacing.screenMargin)
            .padding(.top, DesignTokens.Spacing.sm)
        }
    }
}

// MARK: - Post Card ☀️

struct PostCard: View {
    let post: Post
    @State private var isPressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 画像表示（サムネイル優先、遅延読み込み）
            ZStack(alignment: .bottomLeading) {
                if let firstImage = post.images.first {
                    PostImageView(imageInfo: firstImage)
                        .clipShape(
                            RoundedCornerShape(
                                radius: DesignTokens.Radius.xl,
                                corners: [.topLeft, .topRight]
                            )
                        )
                }

                // 画像数インジケーター
                if post.images.count > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(post.images.count)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.5))
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                            )
                    )
                    .padding(DesignTokens.Spacing.sm)
                }
            }

            // 投稿情報
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                // キャプション
                if let caption = post.caption {
                    Text(caption)
                        .font(.system(size: DesignTokens.Typography.bodySize, weight: .regular, design: .rounded))
                        .foregroundColor(DesignTokens.Colors.textDark)
                        .lineLimit(3)
                }

                // ハッシュタグ
                if let hashtags = post.hashtags, !hashtags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            ForEach(hashtags, id: \.self) { hashtag in
                                Text("#\(hashtag)")
                                    .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium, design: .rounded))
                                    .foregroundColor(DesignTokens.Colors.selectionAccent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(DesignTokens.Colors.selectionAccent.opacity(0.12))
                                    )
                            }
                        }
                    }
                }

                // メタ情報行
                HStack(spacing: DesignTokens.Spacing.md) {
                    // 位置情報
                    if let location = post.location {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 11))
                            if let city = location.city, let prefecture = location.prefecture {
                                Text("\(prefecture) \(city)")
                                    .font(.system(size: DesignTokens.Typography.smallCaptionSize, weight: .medium))
                            }
                        }
                        .foregroundColor(DesignTokens.Colors.skyBlue)
                    }

                    Spacer()

                    // 空の種類・時間帯
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        if let skyType = post.skyType {
                            Label(skyType.displayName, systemImage: skyType.iconName)
                                .font(.system(size: DesignTokens.Typography.smallCaptionSize, weight: .medium))
                                .foregroundColor(DesignTokens.Colors.textTertiary)
                        }
                        if let timeOfDay = post.timeOfDay {
                            Label(timeOfDay.displayName, systemImage: timeOfDay.iconName)
                                .font(.system(size: DesignTokens.Typography.smallCaptionSize, weight: .medium))
                                .foregroundColor(DesignTokens.Colors.textTertiary)
                        }
                    }
                }

                // アクション行
                HStack(spacing: DesignTokens.Spacing.lg) {
                    // いいねボタン
                    HStack(spacing: 6) {
                        Image(systemName: "heart")
                            .font(.system(size: 16, weight: .medium))
                        Text("\(post.likesCount)")
                            .font(.system(size: DesignTokens.Typography.captionSize, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(DesignTokens.Colors.softPink)

                    // コメントボタン
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.right")
                            .font(.system(size: 16, weight: .medium))
                        Text("\(post.commentsCount)")
                            .font(.system(size: DesignTokens.Typography.captionSize, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(DesignTokens.Colors.skyBlue)

                    Spacer()

                    // シェアボタン
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(DesignTokens.Colors.textTertiary)
                }
            }
            .padding(DesignTokens.Spacing.cardPadding)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.5),
                                Color.white.opacity(0.15)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
        .shadow(DesignTokens.Shadow.card)
        // タップ時のアニメーション
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(DesignTokens.Animation.quickSpring, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Rounded Corner Shape（特定の角のみ丸くする）

struct RoundedCornerShape: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Post Image View ☁️

struct PostImageView: View {
    let imageInfo: ImageInfo
    // 未使用の変数を削除（コードレビュー対応）

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
            
            // ユーザー情報 ☁️
            // セキュリティ: メールアドレスは表示しない
            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName ?? "ユーザー")
                    .font(.headline)
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
        VStack(spacing: 2) {
            GradientTitleView(title: "そらもよう", fontSize: 28)
            Text("空を撮る、空を集める")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
        }
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


