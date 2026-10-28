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
//  他人のお気に入り ⭐️（`init(ownerId:ownerDisplayName:viewerId:)`）:
//     持ち主が「お気に入りを見せる」を ON にしていると、フォロワーが他人のプロフィールの入口から push で開く。
//     並ぶのは持ち主が 🔖 を付けた**公開の**空だけ。件数の文は一切出さない。
//     🔴 閲覧者の 🔖 といいねはサーバーに問い合わせる（持ち主の 🔖 を閲覧者の 🔖 として塗らない）。
//     閲覧者が 🔖 を外しても、持ち主のお気に入りの一覧からは消さない。
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

    /// 他人用の題に使う持ち主の表示名（本人用では使わない）
    private let ownerDisplayName: String?

    // MARK: - Initializer

    /// 本人のお気に入り（プロフィールから開く・今までどおり）
    init(ownUserId: String?) {
        _viewModel = StateObject(wrappedValue: FavoritesViewModel(ownUserId: ownUserId))
        ownerDisplayName = nil
    }

    /// 他人のお気に入り（他人のプロフィールの入口から push で開く）⭐️
    /// - Parameters:
    ///   - ownerId: 持ち主（他人）の uid
    ///   - ownerDisplayName: 持ち主の表示名（無い・空ならば題は「空が好きなだれかのお気に入りの空」）
    ///   - viewerId: 閲覧者自身の uid（ブロック一覧を読むのに使う）
    init(ownerId: String, ownerDisplayName: String?, viewerId: String) {
        _viewModel = StateObject(wrappedValue: FavoritesViewModel(ownerId: ownerId, viewerId: viewerId))
        self.ownerDisplayName = ownerDisplayName
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
        // String を渡す（LocalizedStringKey として扱わせない）ので、表示名の中の記号もそのまま出る
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .refreshable {
            await viewModel.load()
            await reflectLoadedPosts()
        }
        .sheet(item: $selectedPost) { post in
            // ⚠️ sheet は環境を継承しないため、Manager を明示的に再注入する。
            //    漏らすと実行時に「No ObservableObject of type ... found」でクラッシュする。
            PostDetailView(post: post)
                .environmentObject(likeManager)
                .environmentObject(favoriteManager)
        }
        // 詳細画面での🔖の変化を一覧へ反映する（解除で消し、戻ったら元の位置へ戻す）
        // 🔴 本人用だけ。他人用で反映すると、閲覧者が 🔖 を外しただけで**持ち主の**お気に入りの一覧から消える
        //    （ViewModel の `syncFavorited` も他人用では何もしない＝二重の守り）
        .onChange(of: favoriteManager.favoritedPostIds) { ids in
            guard !viewModel.isViewingOtherUser else { return }
            viewModel.syncFavorited(ids: ids)
        }
        .task {
            // push 画面なので画面ログは自前で送る（.onAppear は複数回発火するため .task）
            // 他人用は別の名前にする（「私のお気に入りの空」の画面の数に他人の分を混ぜない）
            LoggingService.shared.logScreen(viewModel.isViewingOtherUser ? "他人のお気に入りの空" : "私のお気に入りの空")
            await viewModel.load()
            await reflectLoadedPosts()
        }
    }

    /// 画面の題（本人用は今までどおり「私のお気に入りの空」・他人用は「○○さんのお気に入りの空」）
    ///
    /// ⚠️ 表示名が無い・空白だけのときは「空が好きなだれかのお気に入りの空」にする ⭐️ 1.18.0 PR-B
    ///    （2026-10-24 利用者の決定。名前の抜けた「さんの〜」を出さないため）。
    ///    持ち主の呼び方は `ProfileOwnerName` の 1 か所で決める（入口のボタン・空カレンダーの題とそろえる）。
    private var titleText: String {
        guard viewModel.isViewingOtherUser else { return "私のお気に入りの空" }
        return ProfileOwnerName.possessive(ownerDisplayName) + "お気に入りの空"
    }

    // MARK: - Content

    @ViewBuilder
    private var contentSection: some View {
        if viewModel.isLoading || viewModel.isLoadingMore, viewModel.posts.isEmpty {
            LoadingStateView(type: .initial)
        } else if viewModel.isAccessRevoked {
            // 他人用だけ: 見ている間に持ち主が「お気に入りを見せる」を OFF にした・フォローが外れた。
            // ⚠️ 汎用のエラー画面（再試行）にしない。拒否は待っても直らない。
            EmptyStateView(type: .custom(
                icon: "eye.slash",
                title: "見られなくなりました",
                description: "お気に入りの空が表示されない設定になったか、フォローが外れたため、いまは見られません",
                actionTitle: nil
            ))
        } else if let error = viewModel.lastError, viewModel.posts.isEmpty {
            // ⚠️ 一時的な失敗のときに「0件」と嘘をつかないための分岐
            ErrorStateView(
                error: error,
                // ⚠️ ここでも load() の後に登録を反映する。
                //    漏らすと、詳細を1件開いた瞬間に残りが丸ごと一覧から消える（下の注意書き参照）。
                retryAction: {
                    await viewModel.load()
                    await reflectLoadedPosts()
                },
                secondaryAction: nil,
                secondaryActionTitle: nil
            )
        } else if viewModel.posts.isEmpty, viewModel.hasMore {
            // ⚠️ 1件も出せていないが、サーバーにはまだ続きが残っている。
            //    （ページ繰りの予算を使い切った／続きの解決が一時的に失敗した）
            //    ここで「全部消えました」と出すと**嘘の断定**になる。
            //    しかも一覧が0件だと末尾セルが無く `.onAppear` 起点の自動ページ送りが
            //    効かないので、この手動ボタンが唯一の出口になる。
            EmptyStateView(type: .custom(
                icon: "bookmark.slash",
                title: "表示できる空がありません",
                description: emptyWithMoreDescription,
                actionTitle: viewModel.loadMoreError != nil ? "再試行" : "続きを読み込む"
            ), action: {
                Task {
                    await loadMoreAndReflect()
                }
            })
        } else if viewModel.posts.isEmpty, viewModel.showsUnavailableCount, viewModel.unavailableCount > 0 {
            // ⚠️ 続きは無い。お気に入りはあるが、全部が非公開化・削除で出せなかったケース。
            //    脚注（unavailableCount の Text）はグリッド側にあり、ここでは出ない。
            //    「まだありません」と出すと嘘になるので、専用の文言にする。
            // ⚠️ 本人用だけ（`showsUnavailableCount`）。他人用で件数を出すと、フォロワーに
            //    「非公開・フォロワー限定のお気に入りが N 件ある」ことが分かってしまう。
            EmptyStateView(type: .custom(
                icon: "bookmark.slash",
                title: "表示できる空がありません",
                description: "お気に入りにした空 \(viewModel.unavailableCount)件は、非公開になったか削除されています",
                actionTitle: nil
            ))
        } else if viewModel.posts.isEmpty, viewModel.isViewingOtherUser {
            // 他人用の空の表示は**1 つの文だけ**にする。
            // ⚠️ 「出せない空がある」ときと「本当に 0 件」のときで文を変えると、件数を隠しても
            //    「非公開・フォロワー限定のお気に入りが**ある**こと」自体が分かってしまうため。
            //    本人向けの「🔖 を押すと〜あなただけが見られる」も他人用では出さない。
            EmptyStateView(type: .custom(
                icon: "bookmark",
                title: "表示できる空がありません",
                description: "公開されているお気に入りの空は、まだありません",
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

    /// 「1件も出せていないが、続きはある」ときの説明文
    ///
    /// ⚠️ この状態では `gridSection` が描画されない＝**フッターも出ない**。
    ///    続きの読み込みに失敗したことをここで伝えないと、ボタンを押しても
    ///    同じ文言に戻るだけになり、ユーザーには「効いていない」ようにしか見えない。
    private var emptyWithMoreDescription: String {
        if viewModel.loadMoreError != nil {
            return "続きを読み込めませんでした。通信状況を確かめて、もう一度お試しください"
        }
        // ⚠️ 件数を出すのは本人用だけ（他人用で出すと非公開のお気に入りの数が分かる）
        if viewModel.showsUnavailableCount, viewModel.unavailableCount > 0 {
            return "ここまでの \(viewModel.unavailableCount)件は非公開になったか削除されています。まだ続きがあります"
        }
        return "まだ続きがあります"
    }

    /// 続きを手動で読み込むボタン
    ///
    /// 自動のページ送り（`.onAppear`）が効かない状況の出口なので、
    /// 失敗からの再試行と「行き詰まり」からの前進で見た目を揃えている。
    private func loadMoreButton(title: String) -> some View {
        Button {
            Task {
                await loadMoreAndReflect()
            }
        } label: {
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(
                    Capsule().fill(Color.white.opacity(0.2))
                )
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
    ///
    /// 🔴 本人用だけ。他人用で呼ぶと、**持ち主の** 🔖 が**閲覧者の** 🔖 として塗られる
    ///    （閲覧者はその投稿をお気に入りにしていないのに、詳細で 🔖 が付いて見える）。
    ///    呼び出しは `reflectLoadedPosts` の本人用の枝だけにし、ここでも他人用を止める（二重の守り）。
    private func syncRegisteredFavorites() {
        guard !viewModel.isViewingOtherUser else { return }
        favoriteManager.registerFavorited(postIds: viewModel.posts.map(\.id))
    }

    /// 一覧に投稿が増えたあと（読み込み・引っ張って更新・再試行・続きの読み込み）に、🔖 といいねの状態をそろえる ⭐️
    ///
    /// - 本人用: favorites から取れた＝お気に入り済みが確定しているので、そのまま登録する（今までどおり）。
    /// - 他人用: 並んでいるのは**持ち主の**お気に入り。閲覧者自身の 🔖 といいねは、他の一覧画面
    ///   （ホーム・タグ・プロフィール）と同じく `checkFavoriteStatus` / `checkLikeStatus` でサーバーに問い合わせる。
    /// - Parameter newPosts: 問い合わせる投稿（nil なら一覧の全部）。続きの読み込みでは増えた分だけを渡す
    private func reflectLoadedPosts(_ newPosts: [Post]? = nil) async {
        guard viewModel.isViewingOtherUser else {
            syncRegisteredFavorites()
            return
        }
        let targets = newPosts ?? viewModel.posts
        guard !targets.isEmpty else { return }
        await likeManager.checkLikeStatus(for: targets)
        await favoriteManager.checkFavoriteStatus(for: targets)
    }

    /// 続きを読み込み、増えた投稿の 🔖 といいねの状態をそろえる
    ///
    /// ⚠️ 他人用では増えた分だけを問い合わせる（毎回一覧の全部を問い合わせると、ページを読むたびに読み取りが膨らむ）。
    private func loadMoreAndReflect() async {
        let knownIds = Set(viewModel.posts.map(\.id))
        await viewModel.loadMore()
        await reflectLoadedPosts(viewModel.posts.filter { !knownIds.contains($0.id) })
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
                        // 末尾に到達したら次ページを読む。
                        // ⚠️ 直前の追加読み込みが失敗しているときは自動で叩かない。
                        //    `.onAppear` はスクロール位置のゆらぎで何度も発火するので、
                        //    放っておくと同じ失敗を叩き続けることになる。再試行はフッターのボタンから。
                        if post.id == viewModel.posts.last?.id, viewModel.loadMoreError == nil {
                            Task {
                                await loadMoreAndReflect()
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
            } else if viewModel.loadMoreError != nil {
                // 続きの読み込みに失敗した。⚠️ 黙って諦めない
                //    （黙ると「お気に入りしたのに一覧に無い」に見え、原因も伝わらない）。
                VStack(spacing: DesignTokens.Spacing.sm) {
                    Text("続きを読み込めませんでした")
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))

                    loadMoreButton(title: "再試行")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, DesignTokens.Spacing.md)
            } else if viewModel.stalledWithMore {
                // ⚠️ 続きはあるのに、今回の読み込みでは表示できる投稿が1件も増えなかった
                //    （非公開・削除がページ予算いっぱいに続いている）。
                //    末尾セルの id が変わらないので `.onAppear` は再発火せず、
                //    手動の導線が無いとここから先へ進めなくなる。
                loadMoreButton(title: "続きを読み込む")
                    .frame(maxWidth: .infinity)
                    .padding(.top, DesignTokens.Spacing.md)
            }

            // 非公開化・削除で出せなかった投稿があることを正直に伝える
            // ⚠️ 本人用だけ（`showsUnavailableCount`）。他人用で出すと、フォロワーに
            //    「非公開・フォロワー限定のお気に入りが N 件ある」ことが分かってしまう。
            if viewModel.showsUnavailableCount, viewModel.unavailableCount > 0 {
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
