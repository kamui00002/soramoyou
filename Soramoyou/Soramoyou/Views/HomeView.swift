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
    @EnvironmentObject private var likeManager: LikeManager
    @State private var selectedPost: Post?
    /// 他ユーザープロフィール画面表示用 ⭐️ Issue #2
    @State private var selectedAuthorUserId: String?
    @State private var animateCards = false  // フィードアニメーション用 ☀️
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                await likeManager.checkLikeStatus(for: viewModel.posts)
            }
            .onAppear {
                Task {
                    await viewModel.fetchPosts()
                    await likeManager.checkLikeStatus(for: viewModel.posts)
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
                    .environmentObject(likeManager)
            }
            // 他ユーザープロフィール画面 ⭐️ Issue #2
            .fullScreenCover(item: Binding<IdentifiableString?>(
                get: { selectedAuthorUserId.map(IdentifiableString.init) },
                set: { selectedAuthorUserId = $0?.id }
            )) { wrapper in
                NavigationView {
                    UserProfileView(
                        targetUserId: wrapper.id,
                        ownUserId: viewModel.currentUserId
                    )
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("閉じる") { selectedAuthorUserId = nil }
                        }
                    }
                }
                .navigationViewStyle(.stack)
            }
        }
        .navigationViewStyle(.stack)
    }
    
    // MARK: - Feed View ☀️

    private var feedView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: DesignTokens.Spacing.lg) {
                // On This Day（1年前の空）— 同月日の過去投稿がある時だけ表示する ⭐️
                OnThisDayCardView(userId: viewModel.currentUserId)

                ForEach(Array(viewModel.posts.enumerated()), id: \.element.id) { index, post in
                    PostCard(
                        post: post,
                        author: viewModel.authorsByUserId[post.userId],
                        isLiked: likeManager.isLiked(post.id),
                        likeCount: likeManager.likeCount(for: post),
                        onLikeTapped: {
                            Task {
                                await likeManager.toggleLike(post: post)
                            }
                        },
                        onCardTapped: {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            selectedPost = post
                        },
                        onAuthorTapped: {
                            // 自分の投稿の場合はプロフィールタブへの遷移を促すか
                            // 既存仕様に任せる。ここでは他ユーザーであれば UserProfileView を開く
                            if let currentUserId = viewModel.currentUserId,
                               currentUserId == post.userId {
                                // 自分の投稿: プロフィールタブで見るほうが自然なので何もしない
                                return
                            }
                            selectedAuthorUserId = post.userId
                        }
                    )
                    // スタガードアニメーション（改善）
                    .opacity(animateCards ? 1 : 0)
                    .offset(y: animateCards ? 0 : 30)
                    .scaleEffect(animateCards ? 1 : 0.95)
                    .animation(
                        DesignTokens.Animation.smoothSpring
                        .delay(Double(index) * DesignTokens.Animation.staggerDelay),
                        value: animateCards
                    )
                    .onAppear {
                            // ページネーション: 最後の投稿が表示されたら次のページを読み込む ☁️
                            // 重複リクエスト防止: 読み込み中の場合はスキップ
                            if post.id == viewModel.posts.last?.id
                                && !viewModel.isLoadingMore
                                && viewModel.hasMorePosts {
                                Task {
                                    let previousCount = viewModel.posts.count
                                    await viewModel.loadMorePosts()
                                    // 新しく読み込んだ投稿のいいね状態をチェック
                                    let newPosts = Array(viewModel.posts.dropFirst(previousCount))
                                    await likeManager.checkLikeStatus(for: newPosts)
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
                            // Dynamic Type 対応: .caption はユーザーの文字サイズ設定に追従
                            .font(.system(.caption, design: .rounded, weight: .medium))
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
                            // Dynamic Type 対応: .caption はユーザーの文字サイズ設定に追従
                            .font(.system(.caption, design: .rounded, weight: .medium))
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
    /// 投稿者情報（HomeViewModel.authorsByUserId から渡される）⭐️ Issue #2
    /// `users` コレクションは isOwner 制限のため、公開可能な PublicProfile を渡す。
    var author: PublicProfile? = nil
    var isLiked: Bool = false
    var likeCount: Int? = nil
    var onLikeTapped: (() -> Void)? = nil
    var onCardTapped: (() -> Void)? = nil
    /// 投稿者ヘッダーをタップしたときのハンドラ（他ユーザープロフィールへ遷移）
    var onAuthorTapped: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 投稿者ヘッダー（タップで UserProfileView へ遷移）⭐️ Issue #2
            authorHeader

            // 画像表示（サムネイル優先、遅延読み込み）— タップでカード遷移
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
            .contentShape(Rectangle())
            .onTapGesture {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                onCardTapped?()
            }

            // 投稿情報
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                // キャプション — タップでカード遷移
                if let caption = post.caption {
                    Text(caption)
                        // Dynamic Type 対応: .body はユーザーの文字サイズ設定に追従
                        .font(.system(.body, design: .rounded, weight: .regular))
                        .foregroundColor(DesignTokens.Colors.textDark)
                        .lineLimit(3)
                        .onTapGesture { onCardTapped?() }
                }

                // ハッシュタグ
                if let hashtags = post.hashtags, !hashtags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            ForEach(hashtags, id: \.self) { hashtag in
                                Text("#\(hashtag)")
                                    // Dynamic Type 対応: .caption はユーザーの文字サイズ設定に追従
                                    .font(.system(.caption, design: .rounded, weight: .medium))
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
                                    // Dynamic Type 対応: .caption2 はユーザーの文字サイズ設定に追従
                                    .font(.system(.caption2, design: .default, weight: .medium))
                            }
                        }
                        .foregroundColor(DesignTokens.Colors.skyBlue)
                    }

                    Spacer()

                    // 空の種類・時間帯
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        if let skyType = post.skyType {
                            Label(skyType.displayName, systemImage: skyType.iconName)
                                // Dynamic Type 対応: .caption2 はユーザーの文字サイズ設定に追従
                                .font(.system(.caption2, design: .default, weight: .medium))
                                .foregroundColor(DesignTokens.Colors.textTertiary)
                        }
                        if let timeOfDay = post.timeOfDay {
                            Label(timeOfDay.displayName, systemImage: timeOfDay.iconName)
                                // Dynamic Type 対応: .caption2 はユーザーの文字サイズ設定に追従
                                .font(.system(.caption2, design: .default, weight: .medium))
                                .foregroundColor(DesignTokens.Colors.textTertiary)
                        }
                    }
                }

                // アクション行（ボタンが独立してタップ可能）
                HStack(spacing: DesignTokens.Spacing.lg) {
                    // いいねボタン
                    Button {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        onLikeTapped?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isLiked ? "heart.fill" : "heart")
                                .font(.system(size: 16, weight: .medium))
                                .animation(.easeInOut(duration: 0.2), value: isLiked)
                            Text("\(likeCount ?? post.likesCount)")
                                // Dynamic Type 対応: .caption はユーザーの文字サイズ設定に追従
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                        }
                        .foregroundColor(isLiked ? DesignTokens.Colors.softPink : DesignTokens.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)

                    // コメントボタン — タップで詳細画面へ遷移
                    Button {
                        onCardTapped?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.right")
                                .font(.system(size: 16, weight: .medium))
                            Text("\(post.commentsCount)")
                                // Dynamic Type 対応: .caption はユーザーの文字サイズ設定に追従
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                        }
                        .foregroundColor(DesignTokens.Colors.skyBlue)
                    }
                    .buttonStyle(.plain)

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
    }

    // MARK: - Author Header ⭐️ Issue #2

    /// 投稿者表示ヘッダー（アバター + 表示名）。タップで UserProfileView へ遷移。
    @ViewBuilder
    private var authorHeader: some View {
        HStack(spacing: 10) {
            authorAvatar
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(author?.displayName ?? "ユーザー")
                    // Dynamic Type 対応: .footnote はユーザーの文字サイズ設定に追従
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundColor(DesignTokens.Colors.textDark)
                    .lineLimit(1)
                if author == nil {
                    // ロード中のスケルトン代わりに薄く表示
                    Text(" ")
                        .font(.system(size: 10))
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DesignTokens.Colors.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DesignTokens.Spacing.cardPadding)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            onAuthorTapped?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("投稿者 \(author?.displayName ?? "ユーザー") のプロフィールを開く")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var authorAvatar: some View {
        if let urlString = author?.photoURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    avatarPlaceholder
                }
            }
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// デバイス向き・サイズに応じて画像高さを決定
    /// - ランドスケープiPhone: verticalSizeClass == .compact
    /// - iPad: horizontalSizeClass == .regular
    private var imageHeight: CGFloat {
        if verticalSizeClass == .compact {
            return 160  // ランドスケープiPhone: 画面高さが制限されるため短く
        } else if horizontalSizeClass == .regular {
            return 360  // iPad縦向き
        } else {
            return 240  // ポートレートiPhone
        }
    }

    var body: some View {
        // サムネイルを優先的に表示
        if let thumbnailURL = imageInfo.thumbnail, let url = URL(string: thumbnailURL) {
            KFImage(url)
                .placeholder {
                    ProgressView()
                }
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, minHeight: imageHeight, maxHeight: imageHeight)
                .clipped()
        } else if let imageURL = URL(string: imageInfo.url) {
            // サムネイルがない場合はフルサイズ画像を表示
            KFImage(imageURL)
                .placeholder {
                    ProgressView()
                }
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, minHeight: imageHeight, maxHeight: imageHeight)
                .clipped()
        } else {
            // URLが無効な場合
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(maxWidth: .infinity, minHeight: imageHeight, maxHeight: imageHeight)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                )
        }
    }
}

// MARK: - Card Button Style ☀️
// ScrollView内で安全に動作するタップアニメーション
// DragGesture/LongPressGestureの代わりにButtonStyleを使用し、スクロール競合を回避

struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Post Detail View

struct PostDetailView: View {
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var likeManager: LikeManager
    @StateObject private var viewModel = PostDetailViewModel()
    @StateObject private var commentViewModel = CommentViewModel()
    @State private var showingReportSheet = false
    @State private var showingBlockConfirmation = false
    @State private var showingReportConfirmation = false
    @State private var selectedReportReason: ReportReason?
    @State private var showingDeleteConfirmation = false
    @State private var showingSaveOptions = false
    @State private var showingShareSheet = false
    @State private var isSaving = false
    @State private var saveResultMessage: String?
    @State private var showingSaveResult = false
    @State private var shareImages: [UIImage] = []
    @State private var commentText = ""
    /// 再編集（投稿済み画像の上書き）起動ペイロード。non-nil で EditView を全画面提示。
    @State private var reEditLaunch: ReEditLaunchPayload?
    /// 元画像ダウンロード中フラグ（編集準備中の二重起動防止＋表示用）。
    @State private var isPreparingReEdit = false

    private let downloadService: ImageDownloadServiceProtocol = ImageDownloadService.shared

    private var hasOriginalImages: Bool {
        post.originalImages != nil && !(post.originalImages?.isEmpty ?? true)
    }

    var body: some View {
        NavigationView {
            postDetailContent
                .background(DesignTokens.Colors.detailBackground)
                .navigationTitle("投稿詳細")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(DesignTokens.Colors.detailBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar { postDetailToolbar }
                .onAppear {
                    Task {
                        await viewModel.loadAuthor(userId: post.userId)
                        await commentViewModel.fetchComments(postId: post.id)
                    }
                }
                .alert("投稿を削除", isPresented: $showingDeleteConfirmation) {
                    Button("削除", role: .destructive) {
                        Task {
                            let success = await viewModel.deletePost(post)
                            if success { dismiss() }
                        }
                    }
                    Button("キャンセル", role: .cancel) { }
                } message: {
                    Text("この投稿を削除しますか？この操作は取り消せません。")
                }
                .alert("削除に失敗しました", isPresented: Binding(
                    get: { viewModel.deleteError != nil },
                    set: { if !$0 { viewModel.deleteError = nil } }
                )) {
                    Button("OK") { viewModel.deleteError = nil }
                } message: {
                    Text(viewModel.deleteError ?? "")
                }
                .confirmationDialog("通報理由を選択", isPresented: $showingReportSheet) {
                    ForEach(ReportReason.allCases, id: \.self) { reason in
                        Button(reason.displayName) {
                            selectedReportReason = reason
                            Task { await submitReport(reason: reason) }
                        }
                    }
                    Button("キャンセル", role: .cancel) { }
                }
                .alert("ユーザーをブロック", isPresented: $showingBlockConfirmation) {
                    Button("キャンセル", role: .cancel) { }
                    Button("ブロック", role: .destructive) {
                        Task { await blockPostAuthor() }
                    }
                } message: {
                    Text("このユーザーをブロックすると、このユーザーの投稿がフィードに表示されなくなります。")
                }
                .alert("通報しました", isPresented: $showingReportConfirmation) {
                    Button("OK") { }
                } message: {
                    Text("ご報告ありがとうございます。内容を確認いたします。")
                }
                .confirmationDialog("保存オプション", isPresented: $showingSaveOptions) {
                    saveOptionButtons
                }
                .alert(saveResultMessage ?? "", isPresented: $showingSaveResult) {
                    Button("OK") { saveResultMessage = nil }
                }
                .sheet(isPresented: $showingShareSheet) {
                    ImageShareSheet(images: shareImages)
                }
                // 再編集: 元画像＋レシピをエディタへ。保存時は既存投稿を上書き更新する。
                // item: 方式で「画像が確実に揃ってから」EditView を構築する（stale-state 回避）。
                .fullScreenCover(item: $reEditLaunch) { launch in
                    EditView(
                        images: launch.images,
                        userId: launch.post.userId,          // 自分の投稿のみ編集可なので post.userId = 自分
                        initialRecipe: launch.post.attachedRecipe,
                        editingContext: launch.editingContext
                    )
                }
                .overlay { savingOverlay }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var saveOptionButtons: some View {
        Button("この画像を保存（編集済み）") {
            Task { await saveImage(edited: true, all: false) }
        }
        if hasOriginalImages {
            Button("この画像を保存（オリジナル）") {
                Task { await saveImage(edited: false, all: false) }
            }
        }
        if post.images.count > 1 {
            Button("すべての画像を保存（編集済み）") {
                Task { await saveImage(edited: true, all: true) }
            }
        }
        if hasOriginalImages && (post.originalImages?.count ?? 0) > 1 {
            Button("すべての画像を保存（オリジナル）") {
                Task { await saveImage(edited: false, all: true) }
            }
        }
        Button("キャンセル", role: .cancel) { }
    }

    @ViewBuilder
    private var savingOverlay: some View {
        if isSaving {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)
                    Text("保存中...")
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(DesignTokens.Colors.detailBackground.opacity(0.9))
                )
            }
        }
    }

    private var postDetailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let user = viewModel.author {
                    authorSection(user: user)
                } else if viewModel.isLoadingAuthor {
                    HStack {
                        ProgressView()
                            .tint(.white)
                        Text("投稿者情報を読み込み中...")
                            .font(.caption)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                    .padding()
                }
                // 複数画像投稿はスワイプで切り替え可能なカルーセルで表示 ⭐️
                if !post.images.isEmpty {
                    multiImageCarousel(images: post.images)
                }

                // このレシピで編集（レシピ共有）⭐️
                // attachedRecipe 付き投稿（v1.7.0 以降）でのみ表示。
                // 中立レシピ・未ログイン時の非表示ゲートはコンポーネント内部で行う。
                if let recipe = post.attachedRecipe {
                    UseRecipeButton(recipe: recipe, postId: post.id)
                        .padding(.horizontal)
                }

                postInfoSection
            }
        }
    }

    // MARK: - Multi Image Carousel ⭐️
    // 複数画像投稿で 2 枚目以降が見えなくなっていたバグ対応。
    // TabView + .page スタイルで横スワイプ閲覧を可能にし、
    // 配列内で最も縦長なアスペクト比に TabView 全体の高さを合わせる。
    @ViewBuilder
    private func multiImageCarousel(images: [ImageInfo]) -> some View {
        let aspect = carouselAspectRatio(for: images)
        TabView {
            ForEach(Array(images.enumerated()), id: \.offset) { _, info in
                PostDetailImageView(imageInfo: info)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .aspectRatio(aspect, contentMode: .fit)
    }

    /// 画像配列の中で最も縦長なアスペクト比（width / height）を返す。
    /// `.aspectRatio` は width:height の比率を取るため、最も小さい比率を採用すると
    /// 縦長/横長混在の投稿でもすべての画像が切れずに収まる。
    private func carouselAspectRatio(for images: [ImageInfo]) -> CGFloat {
        let ratios = images.compactMap { info -> CGFloat? in
            guard info.width > 0, info.height > 0 else { return nil }
            return CGFloat(info.width) / CGFloat(info.height)
        }
        return ratios.min() ?? 1.0
    }

    private var postInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let caption = post.caption {
                Text(caption)
                    .font(.body)
                    .foregroundColor(.white)
            }
            if let hashtags = post.hashtags, !hashtags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(hashtags, id: \.self) { hashtag in
                            Text("#\(hashtag)")
                                .font(.body)
                                .foregroundColor(DesignTokens.Colors.skyBlue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(12)
                        }
                    }
                }
            }
            if let location = post.location {
                HStack {
                    Image(systemName: "location.fill")
                        .foregroundColor(DesignTokens.Colors.skyBlue)
                    if let city = location.city, let prefecture = location.prefecture {
                        Text("\(prefecture) \(city)")
                            .font(.body)
                            .foregroundColor(.white)
                    }
                    if let landmark = location.landmark {
                        Text("（\(landmark)）")
                            .font(.caption)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if let skyType = post.skyType {
                    Label(skyType.displayName, systemImage: "cloud.fill")
                        .font(.body)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
                if let timeOfDay = post.timeOfDay {
                    Label(timeOfDay.displayName, systemImage: "clock.fill")
                        .font(.body)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
                if let colorTemperature = post.colorTemperature {
                    Label("\(colorTemperature)K", systemImage: "thermometer")
                        .font(.body)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
            }
            // いいね・コメント数
            HStack(spacing: 24) {
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    Task { await likeManager.toggleLike(post: post) }
                } label: {
                    Label(
                        "\(likeManager.likeCount(for: post))",
                        systemImage: likeManager.isLiked(post.id) ? "heart.fill" : "heart"
                    )
                    .font(.headline)
                    .foregroundColor(likeManager.isLiked(post.id) ? DesignTokens.Colors.softPink : DesignTokens.Colors.textSecondary)
                    .animation(.easeInOut(duration: 0.2), value: likeManager.isLiked(post.id))
                }
                .buttonStyle(.plain)

                Label("\(post.commentsCount)", systemImage: "bubble.right.fill")
                    .font(.headline)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }

            // コメントセクション
            CommentSection(
                postId: post.id,
                postUserId: post.userId,
                commentViewModel: commentViewModel,
                commentText: $commentText
            )
        }
        .padding()
    }

    @ToolbarContentBuilder
    private var postDetailToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("閉じる") {
                dismiss()
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    showingSaveOptions = true
                } label: {
                    Label("写真に保存", systemImage: "square.and.arrow.down")
                }
                Button {
                    Task { await shareCurrentImage() }
                } label: {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
                Divider()
                if viewModel.isOwnPost(post) {
                    // 再編集: 元画像(originalImages)を持つ投稿のみ。
                    // 旧投稿(元画像なし)は再編集すると焼き込み済み画像を再び焼く＝二重焼きになるため非表示。
                    if hasOriginalImages {
                        Button {
                            Task { await prepareReEdit() }
                        } label: {
                            Label(isPreparingReEdit ? "準備中…" : "編集", systemImage: "slider.horizontal.3")
                        }
                        .disabled(isPreparingReEdit)
                    }
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("投稿を削除", systemImage: "trash")
                    }
                    Divider()
                }
                Button(role: .destructive) {
                    showingReportSheet = true
                } label: {
                    Label("この投稿を通報", systemImage: "flag")
                }
                Button(role: .destructive) {
                    showingBlockConfirmation = true
                } label: {
                    Label("このユーザーをブロック", systemImage: "hand.raised")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Save / Share Methods

    private func saveImage(edited: Bool, all: Bool) async {
        isSaving = true
        defer { isSaving = false }

        do {
            let urlStrings: [String]
            if edited {
                urlStrings = all ? post.images.map(\.url) : [post.images.first?.url].compactMap { $0 }
            } else {
                let originals = post.originalImages ?? []
                urlStrings = all ? originals.map(\.url) : [originals.first?.url].compactMap { $0 }
            }

            let savedCount = try await downloadService.downloadAndSaveImages(from: urlStrings)
            saveResultMessage = savedCount == 1 ? "画像を保存しました" : "\(savedCount)枚の画像を保存しました"
            showingSaveResult = true
        } catch {
            saveResultMessage = error.userFriendlyMessage
            showingSaveResult = true
        }
    }

    private func shareCurrentImage() async {
        isSaving = true
        defer { isSaving = false }

        do {
            guard let urlString = post.images.first?.url else {
                saveResultMessage = "共有する画像がありません"
                showingSaveResult = true
                return
            }
            let image = try await downloadService.downloadImage(from: urlString)
            shareImages = [image]
            showingShareSheet = true
        } catch {
            saveResultMessage = error.userFriendlyMessage
            showingSaveResult = true
        }
    }

    /// 再編集: 元画像(originalImages)を order 順に DL し、元投稿の seed を付けてエディタを起動する。
    /// 失敗・元画像なしのときはエラーを表示して起動しない。
    @MainActor
    private func prepareReEdit() async {
        guard !isPreparingReEdit, hasOriginalImages else { return }
        isPreparingReEdit = true
        defer { isPreparingReEdit = false }

        let infos = (post.originalImages ?? []).sorted { $0.order < $1.order }
        let urls = infos.map { $0.url }.filter { !$0.isEmpty }
        guard !urls.isEmpty else {
            saveResultMessage = "元画像が見つかりませんでした"
            showingSaveResult = true
            return
        }
        do {
            let images = try await downloadService.downloadImages(from: urls)
            guard !images.isEmpty else {
                saveResultMessage = "元画像の読み込みに失敗しました"
                showingSaveResult = true
                return
            }
            reEditLaunch = ReEditLaunchPayload(post: post, images: images)
        } catch {
            saveResultMessage = "元画像の読み込みに失敗しました"
            showingSaveResult = true
        }
    }

    /// 通報を送信（ViewModelに委譲）
    private func submitReport(reason: ReportReason) async {
        await viewModel.submitReport(post: post, reason: reason)
        if viewModel.reportError == nil {
            showingReportConfirmation = true
        }
    }

    /// 投稿者をブロック（ViewModelに委譲）
    private func blockPostAuthor() async {
        await viewModel.blockPostAuthor(post: post)
        if viewModel.reportError == nil {
            dismiss()
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
                    .foregroundColor(.white)
            }

            Spacer()
        }
        .padding()
        .background(DesignTokens.Colors.detailCardBackground)
        .cornerRadius(12)
    }
}

// MARK: - Post Detail Image View

struct PostDetailImageView: View {
    let imageInfo: ImageInfo
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
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
                .frame(height: horizontalSizeClass == .regular ? 450 : 300)
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

// MARK: - IdentifiableString ⭐️ Issue #2

/// `fullScreenCover(item:)` は `Identifiable` を要求するため、`String` 単体を
/// 渡すための薄いラッパー。
struct IdentifiableString: Identifiable {
    let id: String
}


