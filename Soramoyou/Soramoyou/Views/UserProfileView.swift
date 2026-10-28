//
//  UserProfileView.swift
//  Soramoyou
//
//  他ユーザーのプロフィール画面 ⭐️ Issue #2
//
//  投稿カードから著者名/アバターをタップして遷移し、フォロー操作を行える。
//

import Kingfisher
import SwiftUI

struct UserProfileView: View {
    @StateObject private var viewModel: UserProfileViewModel
    /// おすすめの空（この人がプロフィールに飾っている最大3枚）⭐️
    @StateObject private var recommendedSkiesViewModel = RecommendedSkiesViewModel()
    @Environment(\.dismiss) private var dismiss
    /// 端末の「視差効果を減らす」が ON か（ON ならフォローボタンの形の変化を一瞬で切り替える）⭐️ 1.18.0 PR-B
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// ブロックの確認を出しているか ⭐️（C 項目 3）
    @State private var isConfirmingBlock = false

    /// 空カレンダーの入口から開くシートを出しているか ⭐️ 1.18.0 PR-B
    @State private var isShowingSkyCalendar = false

    /// フォロー一覧への遷移に使う（ViewModel 内の同名プロパティは private のため保持）⭐️ PR-5
    private let targetUserId: String
    private let ownUserId: String?

    /// いいね状態の共有ストア（この画面では読まず、開く先へ渡すだけ）⭐️ 1.18.0 PR-B
    ///
    /// ⚠️ @EnvironmentObject ではなく init 引数で受け取る（TagDetailView と同じ理由）。
    ///    この画面はホーム（HomeView）とタグ詳細（TagDetailView）から fullScreenCover の中で開かれ、
    ///    カバー先は環境を自動で引き継がない。環境から読む形だと、注入漏れがあると
    ///    開いた瞬間に fatalError で落ちる（ビルドもテストも緑のまま）。init 引数ならコンパイル時に強制できる。
    /// ⚠️ @ObservedObject にしない。この画面は managers の値で何も描かず、空カレンダー・お気に入りの空・
    ///    フォロー一覧へ渡すだけ。@ObservedObject にすると、どこかでいいねや 🔖 が変わるたびに
    ///    プロフィール全体が描き直される。
    private let likeManager: LikeManager
    /// お気に入り（🔖）状態の共有ストア（likeManager と同じ理由で init 引数・private let）⭐️ 1.18.0 PR-B
    private let favoriteManager: FavoriteManager

    init(
        targetUserId: String,
        ownUserId: String?,
        likeManager: LikeManager,
        favoriteManager: FavoriteManager
    ) {
        self.targetUserId = targetUserId
        self.ownUserId = ownUserId
        self.likeManager = likeManager
        self.favoriteManager = favoriteManager
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
                // おすすめの空（1枚も出せないときは欄ごと出さない）⭐️
                // 持ち主が「見せない」にしていたら欄を出さない（.task で読み込みもしない）⭐️ 1.18.0 PR-B
                if viewModel.showsRecommendedSkies, !recommendedSkiesViewModel.items.isEmpty {
                    PublicRecommendedSkiesSection(viewModel: recommendedSkiesViewModel)
                }
                // 空カレンダー・お気に入りの空の入口（持ち主が ON にしたときだけ）⭐️ 1.18.0 PR-B
                skyCalendarEntry
                favoritesEntry
                postsGrid
            }
            .padding(DesignTokens.Spacing.screenMargin)
        }
        .background(DesignTokens.Colors.detailBackground.ignoresSafeArea())
        .navigationTitle(viewModel.publicProfile?.displayName ?? "プロフィール")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 右上の「…」からブロックする ⭐️（C 項目 3。投稿が 0 件の人には投稿の「…」が無く、ここが唯一の入口）
            ToolbarItem(placement: .navigationBarTrailing) {
                // 自分以外のプロフィールを、ログインして見ているときだけ出す
                if ownUserId != nil, !viewModel.isOwnProfile {
                    Menu {
                        Button(role: .destructive) {
                            isConfirmingBlock = true
                        } label: {
                            Label("このユーザーをブロック", systemImage: "hand.raised")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("その他の操作")
                }
            }
        }
        // ブロックの確認 ⭐️（C 項目 3。本文はホーム・ギャラリー・そらともと同じ・利用者が承認済み 2026-10-19）
        .alert(blockConfirmationTitle, isPresented: $isConfirmingBlock) {
            Button("キャンセル", role: .cancel) {}
            Button("ブロック", role: .destructive) {
                Task {
                    // 保存できたら閉じる。失敗したら下の「エラー」の知らせが出て、画面は残す
                    if await viewModel.blockUser() {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("この人の投稿が、ホーム・ギャラリー・そらともに表示されなくなります。お互いのフォローも外れます。ブロックしたことは相手に知らされません")
        }
        .task {
            await viewModel.load()
            // おすすめの空は公開プロフィール（load で取得済み）の一覧から解決する ⭐️
            // 持ち主が「見せない」にしていたら読み込まない（出さない欄の投稿を取りに行かない）⭐️ 1.18.0 PR-B
            if viewModel.showsRecommendedSkies {
                await recommendedSkiesViewModel.load(
                    postIds: viewModel.publicProfile?.recommendedPostIds ?? [],
                    ownerId: targetUserId,
                    viewerId: ownUserId
                )
            }
        }
        .alert("エラー", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        // 「○○さんの空カレンダー」の入口から開くシート ⭐️ 1.18.0 PR-B
        // ⚠️ シートの中は環境を引き継がないので、手渡しで受け取った managers を入れ直す
        //    （SkyCalendarDiaryView の日ごとの一覧が環境から読む・ProfileView の空カレンダーのシートと同じ形）。
        // NavigationView では包まない（SkyCalendarDiaryView が自前で NavigationView と「閉じる」を持つ。包むとナビバーが二重になる）。
        // ⚠️ シートは入口のボタン（switch の中）でなくここに付ける。入口の状態が変わってボタンが消えても、開いているシートが道連れで閉じないように。
        .sheet(isPresented: $isShowingSkyCalendar) {
            SkyCalendarDiaryView(
                otherUserId: targetUserId,
                displayName: viewModel.publicProfile?.displayName
            )
            .environmentObject(likeManager)
            .environmentObject(favoriteManager)
        }
    }

    /// ブロックの確認の見出し（表示名は画面に出すだけで、ログと計測には渡さない）
    private var blockConfirmationTitle: String {
        if let name = viewModel.publicProfile?.displayName, !name.isEmpty {
            return "\(name)さんをブロックしますか？"
        }
        return "このユーザーをブロックしますか？"
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            avatarView
            Text(viewModel.publicProfile?.displayName ?? "ユーザー")
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
            if let bio = viewModel.publicProfile?.bio, !bio.isEmpty {
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
        if let urlString = viewModel.publicProfile?.photoURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    placeholderAvatar
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1))
            .accessibilityLabel("\(viewModel.publicProfile?.displayName ?? "ユーザー") のプロフィール画像")
        } else {
            placeholderAvatar
                .accessibilityLabel("\(viewModel.publicProfile?.displayName ?? "ユーザー") のプロフィール画像")
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
            // 「フォロー」→「フォロー中」の形（背景の色・アイコン・文言）をなめらかに変える ⭐️ 1.18.0 PR-B
            // ⚠️ フォローの結果は ViewModel が通信の後に書き換えるので、押した所で withAnimation では包めない。
            //    そのため isFollowing の変化に動きを付ける（開いた直後にフォロー中と分かって変わるときも同じ動き）。
            //    「視差効果を減らす」が ON なら Motion.animation が nil を返し、一瞬で切り替わる。
            //    触覚（成功・解除・失敗）は結果が分かる ViewModel の toggleFollow で鳴らす。
            .animation(
                Motion.animation(.easeInOut(duration: 0.25), reduceMotion: reduceMotion),
                value: viewModel.isFollowing
            )
        }
        .accessibilityLabel(viewModel.isFollowing ? "フォロー解除" : "フォローする")
        .disabled(viewModel.isFollowOperationInFlight)
    }

    // MARK: - Section Entries（空カレンダー・お気に入りの空の入口）⭐️ 1.18.0 PR-B

    // 出し方（出さない／「フォローすると〜」の 1 行／入口のボタン）は ViewModel の
    // `skyCalendarEntryState` / `favoritesEntryState` が決める。View はそれを描くだけ。
    //
    // ⚠️ 開く先の SkyCalendarDiaryView（シート）と FavoritesView（push）は likeManager / favoriteManager を
    //    環境（EnvironmentObject）から読む。この画面はホーム（HomeView）とタグ詳細（TagDetailView）から
    //    fullScreenCover の中で開かれ、そこでは環境に managers が入っていない（カバー先は環境を引き継がない）。
    //    そのため managers は init 引数で手渡しで受け取り（上の likeManager のコメント・TagDetailView と同じ理由）、
    //    開く先へは `.environmentObject` で入れ直す。
    //    - シート（空カレンダー）: シートの中も環境を引き継がないので入れ直す（ProfileView の空カレンダーのシートと同じ）
    //    - push（お気に入りの空）: push は「この画面の環境」を引き継ぐが、cover 経由のときはこの画面の環境に
    //      managers が無い。なので push 先にも入れ直す（ProfileView からの push だけなら要らないが、どの道から
    //      開かれても落ちないように、呼び出し元を問わず入れる）。

    /// 「○○さんの空カレンダー」の入口（押すとシートで開く。シート本体は body の `.sheet`）
    @ViewBuilder
    private var skyCalendarEntry: some View {
        switch viewModel.skyCalendarEntryState {
        case .hidden:
            EmptyView()
        case .followToSee:
            followToSeeRow("フォローすると空カレンダーが見られます", systemImage: "calendar")
        case .open:
            // 押したら: 触覚（軽いタップ）→ 計測 → シートを開く ⭐️ 1.18.0 PR-B
            // 計測には UID・表示名を送らない（どの欄を開いたかだけ）
            ProfileSectionEntryButton(
                title: sectionEntryTitle(for: .skyCalendar),
                systemImage: "calendar"
            ) {
                Haptics.play(.tap)
                LoggingService.shared.logEvent(
                    "user_profile_section_opened",
                    parameters: ["section": ProfileSection.skyCalendar.rawValue]
                )
                isShowingSkyCalendar = true
            }
        }
    }

    /// 「○○さんのお気に入りの空」の入口（押すと push で開く）
    @ViewBuilder
    private var favoritesEntry: some View {
        switch viewModel.favoritesEntryState {
        case .hidden:
            EmptyView()
        case .followToSee:
            followToSeeRow("フォローするとお気に入りの空が見られます", systemImage: "bookmark")
        case .open:
            // `.open` は閲覧者がログイン中（ownUserId が nil でない）のときしか来ないが、
            // FavoritesView は閲覧者の uid（ブロック一覧を読むのに使う）を String で受け取るので、型の上でも外す。
            // nil なら何も出さない（暗黙の EmptyView）⭐️ 1.18.0 PR-B
            if let viewerId = ownUserId {
                NavigationLink {
                    FavoritesView(
                        ownerId: targetUserId,
                        ownerDisplayName: viewModel.publicProfile?.displayName,
                        viewerId: viewerId
                    )
                    // 🔴 push 先にも入れ直す（上の注意のとおり、cover 経由のときはこの画面の環境に managers が無い）
                    .environmentObject(likeManager)
                    .environmentObject(favoriteManager)
                } label: {
                    // NavigationLink は押した処理を持てないので、入口の見た目だけを借りる
                    ProfileSectionEntryButton.label(
                        title: sectionEntryTitle(for: .favorites),
                        systemImage: "bookmark"
                    )
                }
                // 押すと少し沈む（空カレンダーの入口と同じ見た目・HomeView.swift の CardButtonStyle）
                .buttonStyle(CardButtonStyle())
                // 押したときの触覚と計測（NavigationLink の遷移はそのまま動かし、同時にタップも拾う）
                // 前例: ShareCardExportView の「共有する」（ShareLink に simultaneousGesture で計測）
                .simultaneousGesture(TapGesture().onEnded {
                    Haptics.play(.tap)
                    LoggingService.shared.logEvent(
                        "user_profile_section_opened",
                        parameters: ["section": ProfileSection.favorites.rawValue]
                    )
                })
            }
        }
    }

    /// 入口のボタンの文言（「○○さんの空カレンダー」「○○さんのお気に入りの空」）⭐️ 1.18.0 PR-B
    ///
    /// 表示名が無い（nil・空・空白だけ）ときは「空が好きなだれかの空カレンダー」「空が好きなだれかのお気に入りの空」にする
    /// （2026-10-24 利用者の決定）⭐️ 1.18.0 PR-B
    /// 持ち主の呼び方は `ProfileOwnerName.possessive(_:)` の 1 か所で決め、開いた先の画面の題
    /// （SkyCalendarDiaryView / FavoritesView）も同じ部品を使うので、入口と題の言い方は必ずそろう。
    /// 呼び方を変えるときは `ProfileOwnerName` だけを直す。
    /// - Parameter section: 入口の欄（空カレンダー・お気に入りの空）
    /// - Returns: 入口のボタンに出す文言
    private func sectionEntryTitle(for section: ProfileSection) -> String {
        let sectionName = switch section {
        case .skyCalendar:
            "空カレンダー"
        case .favorites:
            "お気に入りの空"
        case .recommendedSkies:
            // おすすめの空は入口のボタンを持たない（欄そのものをプロフィールに出す）。switch を網羅するためだけの値
            "おすすめの空"
        }
        return ProfileOwnerName.possessive(viewModel.publicProfile?.displayName) + sectionName
    }

    /// 「フォローすると〜が見られます」の 1 行（フォロワーでない・持ち主が ON のとき。ゲストにも出す）
    ///
    /// 押せる見た目にはしない（押しても開けないため）。フォローすると ViewModel の計算で入口のボタンに変わる。
    /// ゲスト（ログインしていない人）にも出す（2026-10-24 利用者の決定）⭐️ 1.18.0 PR-B。
    /// ゲストが押しても何も起きない 1 行で、ログインのきっかけにする（ログインしてフォローすると入口のボタンに変わる）。
    /// - Parameters:
    ///   - text: 出す文
    ///   - systemImage: 文の左に出す SF Symbols の名前（入口のボタンと同じアイコン）
    private func followToSeeRow(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                // 読み上げ（VoiceOver）では文だけを読ませる
                .accessibilityHidden(true)
            Text(text)
        }
        .font(.footnote)
        .foregroundColor(.white.opacity(0.8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.md)
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            statItem(value: viewModel.publicProfile?.postsCount ?? 0, label: "投稿")

            // フォロワー / フォロー中はタップで一覧へ ⭐️ PR-5
            // （この画面は呼び出し元がいずれも NavigationView 内なので push できる）
            NavigationLink {
                FollowListView(
                    listType: .followers,
                    targetUserId: targetUserId,
                    ownUserId: ownUserId,
                    likeManager: likeManager,
                    favoriteManager: favoriteManager
                )
            } label: {
                statItem(value: viewModel.publicProfile?.followersCount ?? 0, label: "フォロワー")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("フォロワー一覧を開く")

            NavigationLink {
                FollowListView(
                    listType: .following,
                    targetUserId: targetUserId,
                    ownUserId: ownUserId,
                    likeManager: likeManager,
                    favoriteManager: favoriteManager
                )
            } label: {
                statItem(value: viewModel.publicProfile?.followingCount ?? 0, label: "フォロー中")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("フォロー中一覧を開く")
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
                // ⚠️ .userPosts の説明文「空の写真を投稿してみましょう」は閲覧者本人への
                //    促し文言で、他人のプロフィールには噛み合わない。アイコンは .userPosts と
                //    同じ "camera" のまま、文言だけ第三者視点に差し替える。
                //    action / actionTitle を渡さないため「投稿する」ボタンは出ない。
                EmptyStateView(
                    type: .custom(
                        icon: "camera",
                        title: "まだ投稿がありません",
                        description: "このユーザーはまだ空の写真を投稿していません",
                        actionTitle: nil
                    )
                )
                .padding(.top, 24)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 4),
                        GridItem(.flexible(), spacing: 4),
                        GridItem(.flexible(), spacing: 4),
                    ],
                    spacing: 4
                ) {
                    ForEach(viewModel.posts) { post in
                        // 1 枚目のサムネイルを表示（公開は URL、公開以外は Storage のパスで読む。判定は PostImageSource）
                        // 読めない投稿は今までどおりセルごと出さない
                        if let firstImage = post.images.first,
                           let image = KFImage.post(PostImageSource.resolve(firstImage, prefersThumbnail: true))
                        {
                            image
                                // 読み込み中・読めなかったときは灰色（AsyncImage の頃と同じ見た目）
                                .placeholder { Color.gray.opacity(0.3) }
                                .resizable()
                                .scaledToFill()
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
