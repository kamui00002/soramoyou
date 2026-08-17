//
//  TagDetailView.swift
//  Soramoyou
//
//  タグ詳細画面 ⭐️
//  ハッシュタグをタップして開く「そのタグの投稿一覧」＋タグのフォロー導線。
//
//  本体のカードは HomeView の PostCard を再利用する（author / isLiked / likeCount と
//  コールバックを注入する設計なのでそのまま使える）。
//

import SwiftUI

struct TagDetailView: View {
    // MARK: - Properties

    /// 表示するハッシュタグ（"#" を含まない生の単語）
    let tag: String
    /// 計装用の流入元（"home_card" / "post_detail" / "gallery_detail"）。
    /// ビュー内からは導出できないため呼び出し側から渡す。
    let source: String

    /// いいね状態の共有ストア。
    /// ⚠️ @EnvironmentObject ではなく明示的に受け取る。この画面は fullScreenCover で
    ///    開かれ、カバー先は環境を自動で引き継がないため、注入漏れがあると
    ///    実行時に fatalError で落ちる（ビルドもテストも緑のまま）。
    ///    init 引数にしておけばコンパイル時に強制できる。
    @ObservedObject var likeManager: LikeManager

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: TagDetailViewModel

    /// カードタップで開く投稿詳細
    @State private var selectedPost: Post?
    /// 投稿者ヘッダータップで開く他ユーザープロフィール
    @State private var selectedAuthorUserId: String?

    // MARK: - Initializer

    init(tag: String, source: String, likeManager: LikeManager) {
        self.tag = tag
        self.source = source
        self.likeManager = likeManager
        _viewModel = StateObject(wrappedValue: TagDetailViewModel(tag: tag))
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
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
            .navigationTitle("#\(tag)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    followButton
                }
            }
            .refreshable {
                await viewModel.refresh()
                await likeManager.checkLikeStatus(for: viewModel.posts)
            }
            // フォロー操作のエラー（上限超過・未ログインを含む）は必ず見せる
            .alert("お知らせ", isPresented: Binding(errorMessage: $viewModel.followErrorMessage)) {
                Button("OK") { viewModel.followErrorMessage = nil }
            } message: {
                if let message = viewModel.followErrorMessage {
                    Text(message)
                }
            }
            .sheet(item: $selectedPost) { post in
                PostDetailView(post: post)
                    .environmentObject(likeManager)
            }
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
        // ⚠️ 画面計装は .task で行う。.onAppear は復帰のたびに複数回発火するため
        //    （cf. SkyZukanView のコメント）。
        .task {
            LoggingService.shared.logScreen("タグ詳細")
            LoggingService.shared.logEvent("tag_detail_opened", parameters: [
                "tag": tag,
                "source": source,
            ])
            // フォローボタンの活性を一覧ロードの完了に縛らないよう、フォロー状態を先に読む
            await viewModel.loadFollowState()
            await viewModel.fetchPosts()
            await likeManager.checkLikeStatus(for: viewModel.posts)
        }
    }

    // MARK: - Follow Button

    /// フォロー / フォロー中の切り替えボタン
    @ViewBuilder
    private var followButton: some View {
        Button {
            Task { await viewModel.toggleFollowTag() }
        } label: {
            if viewModel.isTogglingFollow {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            } else {
                Text(viewModel.isFollowingTag ? "フォロー中" : "フォロー")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundColor(viewModel.isFollowingTag ? DesignTokens.Colors.textSecondary : DesignTokens.Colors.skyBlue)
            }
        }
        // 状態が読めるまでは押させない（未フォロー表示のまま押されるのを防ぐ）
        .disabled(viewModel.isTogglingFollow || !viewModel.hasLoadedFollowState)
        .accessibilityLabel(viewModel.isFollowingTag ? "タグ \(tag) のフォローを解除" : "タグ \(tag) をフォロー")
    }

    // MARK: - Content

    /// ローディング / エラー / 空 / 一覧 の出し分け
    @ViewBuilder
    private var contentSection: some View {
        if viewModel.isLoading, viewModel.posts.isEmpty {
            LoadingStateView(type: .initial)
        } else if let error = viewModel.lastError, viewModel.posts.isEmpty {
            ErrorStateView(
                error: error,
                // ⚠️ .task と同じく、再取得後は いいね状態も取り直す
                //    （ここで省くと再試行で出た一覧のハートが未取得のままになる）
                retryAction: {
                    await viewModel.refresh()
                    await likeManager.checkLikeStatus(for: viewModel.posts)
                },
                secondaryAction: nil,
                secondaryActionTitle: nil
            )
        } else if viewModel.posts.isEmpty {
            emptyView
        } else {
            postList
        }
    }

    /// このタグの投稿がまだ無いとき
    private var emptyView: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "number")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(DesignTokens.Colors.textTertiary)
            Text("「#\(tag)」の投稿はまだありません")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundColor(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DesignTokens.Spacing.xl)
    }

    /// 投稿一覧（ページング付き）
    private var postList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: DesignTokens.Spacing.lg) {
                ForEach(viewModel.posts) { post in
                    postCard(for: post)
                        .onAppear { loadNextPageIfNeeded(currentPost: post) }
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

    /// 投稿カード 1 枚
    ///
    /// ⚠️ ハッシュタグのタップ導線（onHashtagTapped）はここでは渡さない。
    ///    カード層のチップのみ非タップ化。カードタップ → PostDetailView 経由では
    ///    タグ遷移が有効なため、タグ詳細 → 投稿詳細 → タグ詳細の再帰は成立し得るが、
    ///    各層とも個別に閉じられるため許容する。
    @ViewBuilder
    private func postCard(for post: Post) -> some View {
        PostCard(
            post: post,
            author: viewModel.authorsByUserId[post.userId],
            isLiked: likeManager.isLiked(post.id),
            likeCount: likeManager.likeCount(for: post),
            onLikeTapped: {
                Task { await likeManager.toggleLike(post: post) }
            },
            onCardTapped: {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                selectedPost = post
            },
            onAuthorTapped: {
                // 自分の投稿はプロフィールタブで見るほうが自然なので開かない（HomeView と同じ方針）
                if let currentUserId = viewModel.currentUserId, currentUserId == post.userId {
                    return
                }
                selectedAuthorUserId = post.userId
            }
        )
    }

    // MARK: - Pagination

    /// 一番下のカードが見えたら次ページを読む
    private func loadNextPageIfNeeded(currentPost: Post) {
        guard currentPost.id == viewModel.posts.last?.id,
              !viewModel.isLoadingMore,
              viewModel.hasMorePosts
        else { return }

        Task {
            let previousCount = viewModel.posts.count
            await viewModel.loadMorePosts()
            // 追加読み込み分のいいね状態も取得する
            let newPosts = Array(viewModel.posts.dropFirst(previousCount))
            await likeManager.checkLikeStatus(for: newPosts)
        }
    }
}
