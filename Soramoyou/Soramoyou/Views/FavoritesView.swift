//
//  FavoritesView.swift
//  Soramoyou
//
//  「私のお気に入りの空」一覧画面 ⭐️
//
//  プロフィールから push 遷移して開く。3列グリッドで、お気に入りにした新しい順に並ぶ。
//  タップで投稿詳細（sheet）へ。
//
//  ⚠️ この画面は必ず NavigationView の中で push される前提（ProfileView から開く）。
//  ⚠️ お気に入りは ❤️いいねとは別物のプライベート保存。通知しない・件数を公開しない。
//     ここに並ぶのは「自分だけが見られる自分のアルバム」。
//

import SwiftUI

struct FavoritesView: View {
    // MARK: - Properties

    @EnvironmentObject private var likeManager: LikeManager
    @EnvironmentObject private var favoriteManager: FavoriteManager

    @StateObject private var viewModel: FavoritesViewModel
    @State private var selectedPost: Post?

    /// グリッドの列定義（プロフィールのグリッド表示と同じ見た目に揃える）
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    // MARK: - Initializer

    init(ownUserId: String?) {
        _viewModel = StateObject(wrappedValue: FavoritesViewModel(ownUserId: ownUserId))
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
        .navigationTitle("私のお気に入りの空")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .refreshable {
            await viewModel.load()
            syncRegisteredFavorites()
        }
        .sheet(item: $selectedPost) { post in
            // ⚠️ sheet は環境を継承しないため、Manager を明示的に再注入する。
            //    漏らすと実行時に「No ObservableObject of type ... found」でクラッシュする。
            PostDetailView(post: post)
                .environmentObject(likeManager)
                .environmentObject(favoriteManager)
        }
        // 詳細画面での🔖の変化を一覧へ反映する（解除で消し、戻ったら元の位置へ戻す）
        .onChange(of: favoriteManager.favoritedPostIds) { ids in
            viewModel.syncFavorited(ids: ids)
        }
        .task {
            // push 画面なので画面ログは自前で送る（.onAppear は複数回発火するため .task）
            LoggingService.shared.logScreen("私のお気に入りの空")
            await viewModel.load()
            syncRegisteredFavorites()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentSection: some View {
        if viewModel.isLoading, viewModel.posts.isEmpty {
            LoadingStateView(type: .initial)
        } else if let error = viewModel.lastError, viewModel.posts.isEmpty {
            // ⚠️ 一時的な失敗のときに「0件」と嘘をつかないための分岐
            ErrorStateView(
                error: error,
                // ⚠️ ここでも load() の後に登録を反映する。
                //    漏らすと、詳細を1件開いた瞬間に残りが丸ごと一覧から消える（下の注意書き参照）。
                retryAction: {
                    await viewModel.load()
                    syncRegisteredFavorites()
                },
                secondaryAction: nil,
                secondaryActionTitle: nil
            )
        } else if viewModel.posts.isEmpty, viewModel.unavailableCount > 0 {
            // ⚠️ お気に入りはあるが、全部が非公開化・削除で出せなかったケース。
            //    脚注（unavailableCount の Text）はグリッド側にあり、ここでは出ない。
            //    「まだありません」と出すと嘘になるので、専用の文言にする。
            EmptyStateView(type: .custom(
                icon: "bookmark.slash",
                title: "表示できる空がありません",
                description: "お気に入りにした空 \(viewModel.unavailableCount)件は、非公開になったか削除されています",
                actionTitle: nil
            ))
        } else if viewModel.posts.isEmpty {
            EmptyStateView(type: .custom(
                icon: "bookmark",
                title: "まだお気に入りはありません",
                description: "気になった空の 🔖 を押すと、ここに集まります\nあなただけが見られる、あなたの空のアルバムです",
                actionTitle: nil
            ))
        } else {
            gridSection
        }
    }

    /// 一覧に出ている投稿を「お気に入り済み」として Manager に反映する。
    ///
    /// favorites コレクションから取れた投稿は、お気に入り済みであることが確定している
    /// （サーバーへ再照会しない）。
    ///
    /// ⚠️ `posts` が増える経路は **4つ**（初回 load / refresh / エラーからの再試行 / loadMore）。
    ///    どれか1つでも登録を漏らすと、その分は `favoritedPostIds` に入らないまま
    ///    `.onChange(of: favoritedPostIds)` → `syncFavorited` で**一覧から消える**。
    ///    （🔖を1つ解除しただけで2ページ目が丸ごと消える、という形で出る）
    ///    `formUnion` なので冪等・何度呼んでもよい。
    private func syncRegisteredFavorites() {
        favoriteManager.registerFavorited(postIds: viewModel.posts.map(\.id))
    }

    private var gridSection: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(viewModel.posts) { post in
                    Button {
                        selectedPost = post
                    } label: {
                        PostGridItem(post: post)
                    }
                    .buttonStyle(CardButtonStyle())
                    .onAppear {
                        // 末尾に到達したら次ページを読む
                        if post.id == viewModel.posts.last?.id {
                            Task {
                                await viewModel.loadMore()
                                syncRegisteredFavorites()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.screenMargin)
            .padding(.top, DesignTokens.Spacing.sm)

            if viewModel.isLoadingMore {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .padding(.top, DesignTokens.Spacing.md)
            }

            // 非公開化・削除で出せなかった投稿があることを正直に伝える
            if viewModel.unavailableCount > 0 {
                Text("非公開・削除された空 \(viewModel.unavailableCount)件は表示していません")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DesignTokens.Spacing.screenMargin)
                    .padding(.top, DesignTokens.Spacing.md)
            }

            // タブバー分の余白
            Spacer().frame(height: 80)
        }
    }
}
