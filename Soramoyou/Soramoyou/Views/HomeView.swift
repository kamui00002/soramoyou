//
//  HomeView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Kingfisher
import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    /// 「あなた向け」セグメント用 VM（フォロー中＋フォロータグのマージフィード）⭐️ PR-7
    @StateObject private var forYouViewModel = ForYouFeedViewModel()
    /// On This Day とストリークチップの共有 VM（1回の投稿取得から両方を導出）⭐️
    @StateObject private var onThisDayViewModel = OnThisDayViewModel()
    /// 今日のおすすめのそらもよう用 VM（読み込みはこの HomeView が担う）⭐️
    @StateObject private var dailyPickViewModel = DailyPickViewModel()
    @EnvironmentObject private var likeManager: LikeManager
    @EnvironmentObject private var favoriteManager: FavoriteManager
    @State private var selectedPost: Post?
    /// 詳細をカードの写真から広げて開く（ズーム遷移・iOS 18 以上）ための名前空間 ⭐️ PR-H
    /// カードの写真（matchedTransitionSource）と詳細（navigationTransition(.zoom)）で同じ名前空間を使い、
    /// 同じ目印どうしを結び付ける。iOS 16・17 では使われない（詳細は今までどおり下から出る）。
    @Namespace private var detailZoomNamespace
    /// 詳細を開くときの出どころの目印（`HomeDetailZoom.sourceID` の値）⭐️ PR-H
    /// カードから開くときは `selectedPost` を入れる前に入れ、今日のおすすめから開くときは nil にする（ズームしない）。
    /// シートを閉じても消さない（次に開くときに必ず入れ直すので、残っていても使われない）。
    @State private var detailZoomSourceID: String?
    /// 他ユーザープロフィール画面表示用 ⭐️ Issue #2
    @State private var selectedAuthorUserId: String?
    /// タップされたハッシュタグ。non-nil でタグ詳細画面を全画面提示する ⭐️
    @State private var selectedTag: String?
    /// ストリークチップから開く空図鑑の表示フラグ
    @State private var showingStreakZukan = false
    @State private var animateCards = false // フィードアニメーション用 ☀️
    /// ホームフィードの表示セグメント（すべて / あなた向け）⭐️ PR-7
    @State private var selectedSegment: HomeFeedSegment = .all
    /// 切り替えが上のタップか左右のめくりかを見分ける印（home_feed_segment_changed の via）⭐️ PR-H
    ///
    /// Picker と TabView は同じ `selectedSegment` を共有するので、onChange だけではどちらで切り替わったか分からない。
    /// Picker の Binding の set（タップのときだけ通る）で印を立て、`onChange(of: selectedSegment)` で読み出して下ろす。
    @State private var segmentChangeTracker = HomeFeedSegmentChangeTracker()
    /// 「あなた向け」の初回の読み込みが終わったか ⭐️ PR-H
    ///
    /// めくって切り替える TabView は、隣の「あなた向け」のページを指の動きに合わせて先に見せる。
    /// まだ一度も読んでいない（遅延読み込みの前の）あいだは VM の初期値が「投稿 0 件・読み込み中でない」なので、
    /// そのまま出すと「あなた向けの投稿はまだありません」がチラッと見えてしまう。
    /// VM には「一度でも読んだか」のフラグが無いため、ここで持ち、false のあいだは読み込み中の表示にする。
    /// true にするのは読み込みが**終わってから**（始める前に立てると、Task が走り出す前の一瞬に空の表示が出うるため）。
    @State private var hasLoadedForYouFeedOnce = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// アプリが前に出たか（今日のおすすめを、日をまたいで開いたままでも今日の分に読み直すため）⭐️
    @Environment(\.scenePhase) private var scenePhase
    /// 端末の「視差効果を減らす」が ON か（フィードのカードの登場の動きを合わせる）⭐️ PR-H
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 現在のセグメントに対応する ViewModel ⭐️ PR-7
    /// ForYouFeedViewModel は HomeViewModel のサブクラスなので、この1本の参照で扱える
    /// （両方 @StateObject なので変更は body に届く）。
    /// ⭐️ PR-H: めくって切り替えにしてからは、フィード表示・状態表示・引っ張って更新は
    /// ページごとに `feedViewModel(for:)` で決める。ここを見るのはエラーのアラートだけ。
    private var activeViewModel: HomeViewModel {
        selectedSegment == .forYou ? forYouViewModel : viewModel
    }

    /// セグメント（ページ）に対応する ViewModel ⭐️ PR-H
    /// 「すべて」→ viewModel、「あなた向け」→ forYouViewModel。
    /// 選択中のセグメントでなく「そのページのセグメント」から引くので、
    /// めくっている途中で隣のページを描くときも、そのページ自身の VM の状態が出る。
    private func feedViewModel(for segment: HomeFeedSegment) -> HomeViewModel {
        segment == .forYou ? forYouViewModel : viewModel
    }

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
                    // フィード切り替え（すべて / あなた向け）⭐️ PR-7
                    // ゲスト（未認証）は publicProfiles を読めず「あなた向け」が成立しないため出さない
                    if viewModel.currentUserId != nil {
                        // ⭐️ PR-H: Picker にだけ、タップの印を立てる Binding を渡す（via の tap / swipe を分けるため）。
                        // 下の TabView は生の `$selectedSegment` のまま（あちらも包むと、めくりまで tap と記録される）。
                        // set では代入より先に印を立てる（代入で onChange が来たときに、印が読めるように）。
                        Picker("フィード", selection: Binding(
                            get: { selectedSegment },
                            set: { newValue in
                                segmentChangeTracker.noteTap(from: selectedSegment, to: newValue)
                                selectedSegment = newValue
                            }
                        )) {
                            ForEach(HomeFeedSegment.allCases) { segment in
                                Text(segment.title).tag(segment)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, DesignTokens.Spacing.screenMargin)
                        .padding(.top, DesignTokens.Spacing.sm)
                    }

                    // フィード本体（すべて⇄あなた向けを左右にめくって切り替える）⭐️ PR-H
                    feedPages
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
                // そらとも（友達グループで空を共有）の入口 ⭐️ tasks 14.1
                // そらともを使える（登録済みでログイン）ときだけボタンが出る（無効・判定前・ゲスト中は何も描かない）
                ToolbarItem(placement: .navigationBarTrailing) {
                    SoratomoEntryButton()
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            // ⭐️ PR-H: 引っ張って更新（.refreshable）は、各ページの ScrollView（feedView）へ移した。
            // ここに置いたままだと、めくって切り替えた 2 ページが同じ更新処理を共有し、
            // 「今どちらのページか」を選択中のセグメントから読むことになるため。
            .onAppear {
                Task {
                    await viewModel.fetchPosts()
                    await likeManager.checkLikeStatus(for: viewModel.posts)
                    await favoriteManager.checkFavoriteStatus(for: viewModel.posts)
                    // フィードアニメーションを開始
                    withAnimation {
                        animateCards = true
                    }
                }
                // On This Day とストリークチップの元データを取得 ⭐️
                // （カード側はメモリー無し時にサイズゼロになり LazyVStack 内で
                //   task の発火が保証されないため、ホーム自身が load を担う）
                Task {
                    if let uid = viewModel.currentUserId {
                        await onThisDayViewModel.load(userId: uid)
                    }
                }
                // 今日のおすすめのそらもよう ⭐️
                // ゲスト（未ログイン）にもカードを出すため、ログイン条件は付けない
                // （利用者の決定 2026-10-24・2026-10-26）
                Task {
                    await dailyPickViewModel.load(viewerId: viewModel.currentUserId)
                }
            }
            .onChange(of: selectedSegment) { newSegment in
                // 切り替わった手ごたえ ⭐️ PR-H
                // 上の Picker のタップも、TabView を左右にめくったのも、どちらもここを通るので 1 か所で鳴らす
                Haptics.play(.selection)
                // どちらで切り替わったか（via）⭐️ PR-H: Picker の set で印が立っていれば tap、無ければめくり（swipe）。
                // 印はここで 1 回読んだら下ろす（次の切り替えに持ち越さない）
                let via = segmentChangeTracker.consume()
                LoggingService.shared.logEvent("home_feed_segment_changed", parameters: [
                    "segment": newSegment.analyticsValue,
                    "via": via.rawValue,
                ])
                // 「あなた向け」は初回選択時に遅延読み込み（未使用時のクエリコストを避ける）⭐️ PR-7
                // ⚠️ PR-H: ページの onAppear で読みに行く形にはしない。TabView の page は隣のページを
                //    先に作ることがあり、「すべて」を見ているだけで「あなた向け」を読んでしまう（遅延読み込みの意味が消える）。
                if newSegment == .forYou, forYouViewModel.posts.isEmpty, !forYouViewModel.isLoading {
                    Task {
                        await forYouViewModel.fetchPosts()
                        // 初回の読み込みが終わった＝ここからは VM の状態どおりに出す ⭐️ PR-H
                        hasLoadedForYouFeedOnce = true
                        await likeManager.checkLikeStatus(for: forYouViewModel.posts)
                        await favoriteManager.checkFavoriteStatus(for: forYouViewModel.posts)
                    }
                }
            }
            // アプリに戻ってきたら今日のおすすめを読み直す（日をまたいで開いたままだと、onAppear が来ず前日のままになるため）⭐️
            // force なしなので、同じ日・同じ人で終わっていればすぐ戻る（読み取りは増えない）。
            // 起動時などに onAppear と重なっても、同じ鍵の読み込みが進行中なら重ねない（DailyPickViewModel.load）
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    Task {
                        await dailyPickViewModel.load(viewerId: viewModel.currentUserId)
                    }
                }
            }
            .alert("エラー", isPresented: Binding(
                get: { activeViewModel.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        activeViewModel.errorMessage = nil
                    }
                }
            )) {
                Button("OK") {
                    activeViewModel.errorMessage = nil
                }
            } message: {
                if let errorMessage = activeViewModel.errorMessage {
                    Text(errorMessage)
                }
            }
            .sheet(item: $selectedPost) { post in
                PostDetailView(post: post)
                    .environmentObject(likeManager)
                    .environmentObject(favoriteManager)
                    // カードの写真から広がって開く（ズーム遷移・iOS 18 以上）⭐️ PR-H
                    // 目印が nil（今日のおすすめから開いた）か iOS 16・17 のときは何も付けない＝今までどおり下から出る。
                    // シートの中身のいちばん外側に付ける（Apple の説明で、VStack などの入れ物の外側に付けることになっているため）。
                    .modifier(DetailZoomTransitionModifier(sourceID: detailZoomSourceID, namespace: detailZoomNamespace))
            }
            // ハッシュタグ → タグ詳細画面 ⭐️
            // HomeView は NavigationView（NavigationStack ではない）ため
            // .navigationDestination は無反応になる。全画面カバーで開く。
            .fullScreenCover(item: Binding<IdentifiableString?>(
                get: { selectedTag.map(IdentifiableString.init) },
                set: { selectedTag = $0?.id }
            )) { wrapper in
                TagDetailView(tag: wrapper.id, source: "home_card", likeManager: likeManager, favoriteManager: favoriteManager)
            }
            // ストリークチップ → 空図鑑（カレンダー詳細）⭐️
            .sheet(isPresented: $showingStreakZukan) {
                if let uid = viewModel.currentUserId {
                    SkyZukanView(userId: uid)
                }
            }
            // 他ユーザープロフィール画面 ⭐️ Issue #2
            .fullScreenCover(item: Binding<IdentifiableString?>(
                get: { selectedAuthorUserId.map(IdentifiableString.init) },
                set: { selectedAuthorUserId = $0?.id }
            )) { wrapper in
                NavigationView {
                    UserProfileView(
                        targetUserId: wrapper.id,
                        ownUserId: viewModel.currentUserId,
                        likeManager: likeManager,
                        favoriteManager: favoriteManager
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

    // MARK: - Feed Pages ⭐️ PR-H

    /// フィードのページ（すべて⇄あなた向けを左右にめくって切り替える）⭐️ PR-H
    ///
    /// - ログイン中: `TabView` の page 形式で 2 ページ。選択は上の Picker と同じ `selectedSegment` を共有するので、
    ///   タップでもめくりでも切り替わる（どちらも `onChange(of: selectedSegment)` を通る）。
    ///   どちらで切り替えたか（計装の via）は Picker にだけ包んだ Binding で見分けるので、ここは生の `$selectedSegment` のまま渡す。
    /// - ゲスト（未ログイン）: 「あなた向け」が成り立たない（publicProfiles を読めない）ので、
    ///   TabView に入れず「すべて」の 1 ページだけを今までどおり出す（めくれない）。
    ///   判定は Picker と同じ `viewModel.currentUserId`（ゲストには Picker も出していない）。
    /// - Note: カードを横に引く操作（DragGesture の自作・List 化）はしない。
    ///   指の動きの検知はスクロールとぶつかる（下の CardButtonStyle の記録）ため、ページ送りは TabView に任せる。
    @ViewBuilder
    private var feedPages: some View {
        if viewModel.currentUserId != nil {
            TabView(selection: $selectedSegment) {
                ForEach(HomeFeedSegment.allCases) { segment in
                    feedPage(for: segment)
                        .tag(segment)
                }
            }
            // ページの印（点）は出さない＝今どちらのページかは上の Picker が示す
            .tabViewStyle(.page(indexDisplayMode: .never))
        } else {
            feedPage(for: .all)
        }
    }

    /// 1 ページ分の中身（読み込み中／エラー／空／一覧）⭐️ PR-H
    ///
    /// 以前は body で `activeViewModel`（選択中のセグメントの VM）1 つを見て出し分けていた。
    /// めくっている途中は 2 ページが同時に見えるので、ページ自身のセグメントの VM で出し分ける。
    /// - Parameter segment: このページのセグメント
    @ViewBuilder
    private func feedPage(for segment: HomeFeedSegment) -> some View {
        let pageViewModel = feedViewModel(for: segment)
        ZStack {
            if segment == .forYou, !hasLoadedForYouFeedOnce {
                // 「あなた向け」をまだ一度も読み終えていない（遅延読み込みの前・最中）⭐️ PR-H
                // めくる途中に隣のページとして見えても「投稿はまだありません」と誤って見せない
                // ⭐️ PR-H 光は「このページが選ばれているときだけ」脈打たせる（下の初回読み込み中も同じ）。
                //    めくり切り替えでは選ばれていないページも生きていて、そこの光が裏で回り続けるのを防ぐ。
                //    選ばれた時点（selectedSegment が変わった時点）で動き始める。
                LoadingStateView(type: .initial, pulses: selectedSegment == segment)
            } else if pageViewModel.isLoading, pageViewModel.posts.isEmpty {
                // 初回読み込み中 ☁️
                // ⭐️ PR-H 上と同じ理由で、選ばれているページだけ光を脈打たせる
                //    （片方だけだと、「すべて」の初回読み込み中にあなた向けへめくった場合に裏で回り続ける）
                LoadingStateView(type: .initial, pulses: selectedSegment == segment)
            } else if let error = pageViewModel.lastError, pageViewModel.posts.isEmpty {
                // エラー発生時（投稿が空の場合）☁️
                ErrorStateView(
                    error: error,
                    retryAction: {
                        await pageViewModel.refresh()
                    },
                    secondaryAction: nil,
                    secondaryActionTitle: nil
                )
            } else if pageViewModel.posts.isEmpty {
                if segment == .forYou {
                    // あなた向けの投稿がない場合（フォロー0・タグ0など）⭐️ PR-7
                    EmptyStateView(type: .custom(
                        icon: "person.2",
                        title: "あなた向けの投稿はまだありません",
                        description: "ユーザーやタグをフォローすると、その新着がここに流れます",
                        actionTitle: nil
                    ))
                } else {
                    // 投稿がない場合 ☁️
                    EmptyStateView(type: .posts) {
                        // 投稿タブに切り替える（TabViewの切り替えはMainTabViewで管理）
                    }
                }
            } else {
                // フィード表示
                feedView(segment: segment, pageViewModel: pageViewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 引っ張って更新（1 ページ分）⭐️ PR-H で外側から各ページの ScrollView へ移した
    ///
    /// 対象の VM とセグメントは、引っ張ったページのものを引数で受ける。
    /// 以前（外側に 1 つ）は「await 中にセグメントが切り替わっても、更新対象といいね照合対象を
    /// 同じ VM に固定する」ため、最初の await の前に定数へ取っていた（activeViewModel は computed のため
    /// 再評価されうる。レビュー D6）。引数で受ければ途中でめくっても対象は変わらないので、その意図は形のうえで保たれる。
    /// - Note: 読み込み中／エラー／空の表示には ScrollView が無いので、引っ張って更新が効くのは一覧のときだけ
    ///   （外側に付けていた以前も同じ）。
    /// - Parameters:
    ///   - segment: 引っ張ったページのセグメント
    ///   - pageViewModel: 引っ張ったページの VM
    private func refreshPage(segment: HomeFeedSegment, pageViewModel: HomeViewModel) async {
        await pageViewModel.refresh()
        await likeManager.checkLikeStatus(for: pageViewModel.posts)
        await favoriteManager.checkFavoriteStatus(for: pageViewModel.posts)
        // 今日のおすすめは「すべて」のページで引っ張ったときだけ読み直す ⭐️
        if segment == .all {
            await dailyPickViewModel.load(viewerId: viewModel.currentUserId, force: true)
        }
    }

    /// 写真を 2 回タップしたときのいいね（付けるだけ）⭐️ PR-H
    ///
    /// Instagram と同じく、付いていても外さない（2 回タップを重ねても「付けた→外れた」にならない）。
    /// - ⚠️ 判定は Task の中（toggleLike を呼ぶ直前）で行う。LikeManager は @MainActor で、
    ///   楽観更新（likedPostIds への追加）は toggleLike の最初の await より前に入るため、
    ///   「確かめてから呼ぶ」の間に別のいいね操作が割り込まない。
    /// - LikeManager は書き込み中の投稿への呼び出しを捨てる（inFlightPostIds）ので、
    ///   通信中に 2 回タップを重ねても 2 回トグルされることはない（ここで別の守りは足さない）。
    /// - ゲスト（未ログイン）には呼び出し側（feedView）で 2 回タップを付けない（onDoubleTapLike を nil にする）ので、
    ///   ここには来ない。
    /// - Parameter post: 2 回タップされた投稿
    private func addLikeFromDoubleTap(_ post: Post) {
        Task {
            guard !likeManager.isLiked(post.id) else { return }
            await likeManager.toggleLike(post: post, source: "home_card", method: .doubleTap)
        }
    }

    // MARK: - Feed View ☀️

    /// 1 ページ分の一覧 ⭐️ PR-H で引数つきに変えた（選択中のセグメントでなく、そのページの VM とセグメントを見る）
    /// - Parameters:
    ///   - segment: このページのセグメント（ストリーク・今日のおすすめ・On This Day を出すか）
    ///   - pageViewModel: このページの VM（一覧・ページ送り・引っ張って更新の対象）
    private func feedView(segment: HomeFeedSegment, pageViewModel: HomeViewModel) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: DesignTokens.Spacing.lg) {
                // ストリークチップ・On This Day は「すべて」セグメントのみ表示 ⭐️ PR-7
                // （あなた向けは「フォロー由来の投稿だけが流れる場所」として純度を保つ）
                if segment == .all {
                    // ストリークチップ（🔥◯日連続）— 継続中のみ表示、タップで図鑑へ ⭐️
                    SkyStreakChipView(streak: onThisDayViewModel.streak) {
                        LoggingService.shared.logEvent("streak_chip_tapped", parameters: [
                            "current_streak": onThisDayViewModel.streak.currentStreak,
                        ])
                        showingStreakZukan = true
                    }

                    // 今日のおすすめのそらもよう — 決まっているときだけ表示する ⭐️
                    // （load は HomeView の onAppear / refreshable。「あなた向け」には出さない）
                    DailyPickCardView(viewModel: dailyPickViewModel) { post in
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        dailyPickViewModel.recordTapped()
                        // ズームせず、今までどおり下から出す ⭐️ PR-H
                        // 今日のおすすめのカードは、ズームの出どころ（PostCard の写真）ではないため。
                        // 目印はシートを閉じても消えないので、直前にカードから開いた目印が残っていると、
                        // そのカードの写真から広がってしまう。`selectedPost` を入れる**前**に消しておく。
                        detailZoomSourceID = nil
                        selectedPost = post
                    }

                    // On This Day（1年前の空）— 同月日の過去投稿がある時だけ表示する ⭐️
                    // VM はチップと共有（1回の投稿取得から両方を導出、load は HomeView の task）
                    OnThisDayCardView(viewModel: onThisDayViewModel)
                }

                ForEach(Array(pageViewModel.posts.enumerated()), id: \.element.id) { index, post in
                    PostCard(
                        post: post,
                        author: pageViewModel.authorsByUserId[post.userId],
                        isLiked: likeManager.isLiked(post.id),
                        likeCount: likeManager.likeCount(for: post),
                        isFavorited: favoriteManager.isFavorited(post.id),
                        onLikeTapped: {
                            Task {
                                await likeManager.toggleLike(post: post, source: "home_card", method: .button)
                            }
                        },
                        onFavoriteTapped: {
                            Task {
                                await favoriteManager.toggleFavorite(post: post, source: "home_card")
                            }
                        },
                        onCardTapped: {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            // 詳細をこのカードの写真から広げて開くための目印 ⭐️ PR-H（iOS 18 以上で効く）
                            // `selectedPost` を入れる**前**に入れる＝シートの中身を作る時点で、どの写真から広がるかが決まっているように。
                            // ページ名も混ぜた値なので、同じ投稿が両方のページに出ていても、今触ったページの写真から広がる。
                            detailZoomSourceID = HomeDetailZoom.sourceID(segment: segment, postID: post.id)
                            selectedPost = post
                        },
                        onAuthorTapped: {
                            // 自分の投稿の場合はプロフィールタブへの遷移を促すか
                            // 既存仕様に任せる。ここでは他ユーザーであれば UserProfileView を開く
                            if let currentUserId = pageViewModel.currentUserId,
                               currentUserId == post.userId
                            {
                                // 自分の投稿: プロフィールタブで見るほうが自然なので何もしない
                                return
                            }
                            selectedAuthorUserId = post.userId
                        },
                        onHashtagTapped: { tag in
                            selectedTag = tag
                        },
                        // 写真を 2 回タップでいいね（付けるだけ）⭐️ PR-H
                        // ゲスト（未ログイン）には付けない（nil）＝写真の 1 回タップも遅れない。
                        // 理由: toggleLike はゲストだと showLoginPrompt を立てて戻るだけで、その旗を読む画面がまだ無い。
                        // 付けるとハートと触覚は出るのにいいねされず、誤解を招く（2026-10-28 利用者の決定）。
                        // 判定は Picker・feedPages と同じ `viewModel.currentUserId`。
                        onDoubleTapLike: viewModel.currentUserId == nil ? nil : { addLikeFromDoubleTap(post) },
                        shareSource: "home_card",
                        // 詳細を開くとき、このカードの写真から広がる（ズーム遷移・iOS 18 以上）⭐️ PR-H
                        // 目印は onCardTapped で detailZoomSourceID に入れる値と同じ式（ページ名＋投稿 ID）にする。
                        // 2 つがずれると、写真と詳細が結び付かず写真から広がらない。
                        zoomTransition: PostCardZoomTransition(
                            sourceID: HomeDetailZoom.sourceID(segment: segment, postID: post.id),
                            namespace: detailZoomNamespace
                        )
                    )
                    // スタガードアニメーション（改善）
                    // ⭐️ PR-H: 「視差効果を減らす」ON のときは下からの移動と拡大をやめ、順にふわっと出るだけにする。
                    // 画面の動きで気分が悪くなる原因（移動・拡大）を含めないため（PostCard の 2 回タップのハートと同じ考え方）。
                    // `Motion.animation` は ON のとき nil（動かさない）を返すので、ON のときの出方は fastEase に差し替える。
                    // 順番の遅れ（stagger）は ON でも残す（薄く出る順番がずれるだけで、移動・拡大は含まないため）。
                    .opacity(animateCards ? 1 : 0)
                    .offset(y: reduceMotion || animateCards ? 0 : 30)
                    .scaleEffect(reduceMotion || animateCards ? 1 : 0.95)
                    .animation(
                        (Motion.animation(DesignTokens.Animation.smoothSpring, reduceMotion: reduceMotion) ?? DesignTokens.Animation.fastEase)
                            .delay(Double(index) * DesignTokens.Animation.staggerDelay),
                        value: animateCards
                    )
                    .onAppear {
                        // ページネーション: 最後の投稿が表示されたら次のページを読み込む ☁️
                        // 重複リクエスト防止: 読み込み中の場合はスキップ
                        if post.id == pageViewModel.posts.last?.id,
                           !pageViewModel.isLoadingMore,
                           pageViewModel.hasMorePosts
                        {
                            Task {
                                // await 中のセグメント切替で件数計算と照合対象の VM が
                                // 食い違わないよう、処理全体を同じ参照で完結させる（レビュー D6）
                                // ⭐️ PR-H: 引数で受けたこのページの VM なので、途中でめくっても参照は変わらない
                                let targetViewModel = pageViewModel
                                let previousCount = targetViewModel.posts.count
                                await targetViewModel.loadMorePosts()
                                // 新しく読み込んだ投稿のいいね状態をチェック
                                let newPosts = Array(targetViewModel.posts.dropFirst(previousCount))
                                await likeManager.checkLikeStatus(for: newPosts)
                                await favoriteManager.checkFavoriteStatus(for: newPosts)
                            }
                        }
                    }
                }

                // 追加読み込み中のインジケーター
                if pageViewModel.isLoadingMore {
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
                if !pageViewModel.hasMorePosts, !pageViewModel.posts.isEmpty {
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
        // 引っ張って更新 — このページの VM とセグメントに固定する ⭐️ PR-H（理由は refreshPage の説明）
        .refreshable {
            await refreshPage(segment: segment, pageViewModel: pageViewModel)
        }
    }
}

// MARK: - Post Card ☀️

struct PostCard: View {
    let post: Post
    /// 投稿者情報（HomeViewModel.authorsByUserId から渡される）⭐️ Issue #2
    /// `users` コレクションは isOwner 制限のため、公開可能な PublicProfile を渡す。
    var author: PublicProfile?
    var isLiked: Bool = false
    var likeCount: Int?
    /// お気に入り（🔖）済みか ⭐️
    var isFavorited: Bool = false
    var onLikeTapped: (() -> Void)?
    /// お気に入りをタップしたときのハンドラ ⭐️
    /// nil のときは 🔖 ボタン自体を描かない（お気に入りを扱わない画面＝SearchView をそのまま使えるようにする）。
    var onFavoriteTapped: (() -> Void)?
    var onCardTapped: (() -> Void)?
    /// 投稿者ヘッダーをタップしたときのハンドラ（他ユーザープロフィールへ遷移）
    var onAuthorTapped: (() -> Void)?
    /// ハッシュタグをタップしたときのハンドラ（タグ詳細へ遷移）⭐️
    /// nil の場合はチップが表示のみになる（タグ詳細画面内の再帰的な遷移を避けるため）。
    var onHashtagTapped: ((String) -> Void)?
    /// 写真を 2 回タップしたときのハンドラ（いいねを付ける）⭐️ PR-H
    /// nil のときは 2 回タップを付けない＝1 回タップが遅れない（SearchView・TagDetailView・ProfileView は今のまま）。
    /// 渡したときだけ、写真の 2 回タップ・ハートの演出・触覚・読み上げの「いいね」操作が付く。
    /// 付けるかどうか（付いていたら何もしない）は渡す側（HomeView）が決める。
    var onDoubleTapLike: (() -> Void)?
    /// シェアのボタンの計装 post_share_sheet_opened の source ⭐️ PR-H
    /// いいねの source と同じ値（"home_card" / "tag_detail" / "profile_list"）。
    /// 検索（SearchView）は渡していない＝source なしの記録が検索のカード。
    /// SearchView は未整形のファイルで今回は触らないため（search_card は別 PR で足す）。
    /// メンバーごとの init の引数は宣言順なので、後ろのほう（zoomTransition の前）に置いて呼び出し側は末尾に足すだけで済むようにしている。
    var shareSource: String?
    /// 詳細をこのカードの写真から広げて開くための材料（ズーム遷移・iOS 18 以上）⭐️ PR-H
    /// 渡すのはホームだけ。渡さない画面（検索・タグ詳細・プロフィール）は nil＝今までどおり詳細は下から出る。
    /// メンバーごとの init の引数は宣言順なので、shareSource の後ろ（一番最後）に置き、
    /// 他の 3 画面の呼び出しは変えずに済むようにしている。
    var zoomTransition: PostCardZoomTransition?

    /// 2 回タップのハートが見えているか ⭐️ PR-H
    @State private var isDoubleTapHeartVisible = false
    /// ハートを消す予約の番号 ⭐️ PR-H
    /// 続けて 2 回タップしたとき、前の「消す」予約が新しく出したハートを早く消さないよう、最後の予約だけを効かせる。
    @State private var doubleTapHeartToken = 0
    /// 「視差効果を減らす」が ON か ⭐️ PR-H（ON のときハートは拡大せず、ふわっと出て消えるだけ）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            // この写真を、詳細へ広がるズーム遷移の出どころにする ⭐️ PR-H（iOS 18 以上・zoomTransition を渡した画面だけ）
            // 写真の ZStack の直後（ハートの overlay やタップより前）に付け、広がり始める枠をカード全体でなく写真の部分にする
            .modifier(PostCardZoomSourceModifier(zoom: zoomTransition))
            .contentShape(Rectangle())
            // 2 回タップで写真の中央に出るハート ⭐️ PR-H（onDoubleTapLike が無い画面では描かない）
            .overlay { doubleTapHeart }
            // 1 回タップ＝詳細へ／2 回タップ＝いいね ⭐️ PR-H
            // 2 回タップは onDoubleTapLike があるときだけ付ける（無い画面は 1 回タップだけ＝今までと同じ動き）
            .modifier(PostCardPhotoTapModifier(
                onSingleTap: { openDetailFromPhoto() },
                onDoubleTap: onDoubleTapLike == nil ? nil : { handleDoubleTapLike() }
            ))

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

                // ハッシュタグ（onHashtagTapped がある場合のみタップでタグ詳細へ）⭐️
                if let hashtags = post.hashtags, !hashtags.isEmpty {
                    HashtagChipRow(
                        hashtags: hashtags,
                        style: .compact,
                        layout: .scroll,
                        onTap: onHashtagTapped
                    )
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
                    // いいねボタン — 共通部品（触覚・弾み・数字の入れ替わりは部品の中）⭐️ PR-H
                    // 検索の画面は onLikeTapped が nil＝押すと軽い触覚だけで何も起きない（今までと同じ）
                    PostLikeButton(
                        isLiked: isLiked,
                        count: likeCount ?? post.likesCount,
                        style: .card,
                        action: onLikeTapped
                    )

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

                    // お気に入り（🔖）ボタン ⭐️
                    // ❤️と違い件数は出さない（自分だけのプライベート保存なので公開する数がない）。
                    // 共通部品（触覚・弾み・読み上げのラベルは部品の中）⭐️ PR-H
                    if let onFavoriteTapped {
                        PostFavoriteButton(
                            isFavorited: isFavorited,
                            style: .card,
                            action: onFavoriteTapped
                        )
                    }

                    Spacer()

                    // シェアボタン — 共通部品（詳細の「共有」と同じ処理: 1 枚目を取ってきて共有シートを出す）⭐️ PR-H
                    // このカードを使う 4 画面（ホーム・検索・タグ詳細・プロフィール）すべてで動く。
                    // 計装の source は shareSource（検索は渡していない＝source なし）
                    PostShareButton(post: post, source: shareSource)
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
                                Color.white.opacity(0.15),
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
        // 読み上げ（VoiceOver）の「いいね」操作 ⭐️ PR-H
        // 読み上げ中は 2 回タップ＝「開く」になり、写真の 2 回タップのいいねが使えないため、
        // onDoubleTapLike があるときだけ操作の一覧に「いいね」を足す（動きは 2 回タップと同じ「付けるだけ」）
        .modifier(PostCardLikeAccessibilityActionModifier(
            onLike: onDoubleTapLike == nil ? nil : { handleDoubleTapLike() }
        ))
    }

    // MARK: - Double Tap Like ⭐️ PR-H

    /// 写真を 1 回タップ → 詳細へ
    /// PR-H で body の `.onTapGesture` から関数へ切り出しただけ（中身は今までと同じ・触覚の直書きも今回は移さない）。
    /// 2 回タップの有無で付けるジェスチャーを分ける（PostCardPhotoTapModifier）ため、両方から同じ処理を呼べる形にした。
    private func openDetailFromPhoto() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        onCardTapped?()
    }

    /// 写真を 2 回タップ（または読み上げの「いいね」操作）→ いいねを付ける
    ///
    /// 見た目（ハート）と触覚はここ（カード）で出し、付けるかどうか（付いていたら何もしない）は
    /// 渡されたハンドラ（HomeView）が決める。ハートと触覚は毎回出す
    /// （付いている投稿でも「受け付けた」ことを返す・Instagram と同じ）。
    private func handleDoubleTapLike() {
        Haptics.play(.likeOn)
        showDoubleTapHeart()
        onDoubleTapLike?()
    }

    /// 写真の中央にハートを出して、少し置いてから消す
    ///
    /// - 「視差効果を減らす」OFF: 小さい所からばねで広がって出る → 縮みながら薄れて消える。
    /// - ON: 大きさは変えず（拡大しない）、薄く出て薄れて消えるだけ。
    ///   `Motion.animation` は ON のとき nil（動かさない）を返すので、ON のときの出方は「ふわっと（fastEase）」に差し替える。
    ///   薄く出る・消えるだけの動きは、画面の動きで気分が悪くなる原因（拡大・移動）を含まないため。
    ///   大きさを変えないのは `doubleTapHeart` の scaleEffect 側（ON のときはいつも等倍）。
    private func showDoubleTapHeart() {
        doubleTapHeartToken += 1
        let token = doubleTapHeartToken
        withAnimation(
            Motion.animation(DesignTokens.Animation.bouncySpring, reduceMotion: reduceMotion)
                ?? DesignTokens.Animation.fastEase
        ) {
            isDoubleTapHeartVisible = true
        }
        // 少し見せてから消す（続けて 2 回タップしたときは、最後の予約だけが消す）
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard token == doubleTapHeartToken else { return }
            withAnimation(DesignTokens.Animation.fadeOut) {
                isDoubleTapHeartVisible = false
            }
        }
    }

    /// 2 回タップで写真の中央に出るハート
    /// onDoubleTapLike が無い画面では描かない。タップは下の写真が受ける（allowsHitTesting(false)）・読み上げには出さない。
    @ViewBuilder
    private var doubleTapHeart: some View {
        if onDoubleTapLike != nil {
            Image(systemName: "heart.fill")
                .font(.system(size: 80, weight: .semibold))
                // 写真の上に出す白（画像数インジケーターと同じ）＋影で、明るい空の写真の上でも見えるようにする
                .foregroundColor(.white)
                .shadow(DesignTokens.Shadow.medium)
                // 「視差効果を減らす」ON のときは拡大しない（いつも等倍で、薄く出て消えるだけ）
                .scaleEffect(reduceMotion || isDoubleTapHeartVisible ? 1 : 0.5)
                .opacity(isDoubleTapHeartVisible ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
        if let url = StorageImageURL.url(from: author?.photoURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
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

// MARK: - Post Card Photo Tap ⭐️ PR-H

/// カードの写真のタップ（1 回＝詳細へ／2 回＝いいね）⭐️ PR-H
///
/// 2 回タップのハンドラが nil の画面（検索・タグ詳細・プロフィール）は、1 回タップだけを付ける＝今までと全く同じ動き。
/// 2 回タップを付けると、1 回タップは「2 回目が来ないこと」を確かめてから確定するので 0.2〜0.3 秒ほど遅れる
/// （Instagram と同じ・利用者は了解済み）。その遅れを nil の画面へ広げないための分岐。
/// - Note: `exclusively(before:)` は先に書いた方（2 回タップ）を優先し、成り立たなかったときだけ 1 回タップにする。
///   指の動き（DragGesture）は使わないので、ScrollView のスクロールやページのめくりとはぶつからない。
private struct PostCardPhotoTapModifier: ViewModifier {
    /// 1 回タップ（詳細へ）
    let onSingleTap: () -> Void
    /// 2 回タップ（いいね）。nil なら付けない
    let onDoubleTap: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onDoubleTap {
            content.gesture(
                TapGesture(count: 2)
                    .onEnded { onDoubleTap() }
                    .exclusively(before: TapGesture().onEnded { onSingleTap() })
            )
        } else {
            content.onTapGesture {
                onSingleTap()
            }
        }
    }
}

/// 読み上げ（VoiceOver）の「いいね」操作 ⭐️ PR-H
///
/// `.accessibilityAction` は条件つきで外せないので、ハンドラがあるときだけ付ける分岐をここにまとめる。
/// ハンドラが nil の画面は何も足さない（今までと同じ読み上げ）。
private struct PostCardLikeAccessibilityActionModifier: ViewModifier {
    /// 「いいね」を選んだときの処理。nil なら操作を足さない
    let onLike: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onLike {
            content.accessibilityAction(named: "いいね") {
                onLike()
            }
        } else {
            content
        }
    }
}

// MARK: - Post Card Zoom Transition ⭐️ PR-H

/// カードの写真から詳細へ広がるズーム遷移（iOS 18 以上）のために、カードへ渡す材料 ⭐️ PR-H
///
/// 目印（sourceID）と名前空間（namespace）は、開く側（HomeView のシート）の `navigationTransition(.zoom)` と
/// 同じ組でないと結び付かない。2 つを 1 つの型にまとめて渡し、片方だけ渡し忘れることが起きないようにしている。
/// `Namespace.ID` 自体は iOS 16 でも使えるので、この型は iOS 18 の分岐の外に置ける（ズームの API だけが iOS 18 から）。
struct PostCardZoomTransition {
    /// ズーム遷移の目印（`HomeDetailZoom.sourceID` の値）
    let sourceID: String
    /// 開く側と共有する名前空間（HomeView の `detailZoomNamespace`）
    let namespace: Namespace.ID
}

/// カードの写真を、詳細へのズーム遷移の出どころにする ⭐️ PR-H
///
/// `matchedTransitionSource` は iOS 18 からなので `#available` で分ける。
/// iOS 16・17 のとき、または zoom が nil の画面（検索・タグ詳細・プロフィール）は何も付けない＝今までと同じ。
private struct PostCardZoomSourceModifier: ViewModifier {
    /// 出どころの目印と名前空間。nil なら何も付けない
    let zoom: PostCardZoomTransition?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let zoom {
            content.matchedTransitionSource(id: zoom.sourceID, in: zoom.namespace)
        } else {
            content
        }
    }
}

/// 詳細（シートの中身）を、目印の写真から広がって開くようにする ⭐️ PR-H
///
/// `navigationTransition(.zoom)` は iOS 18 からなので `#available` で分ける。
/// iOS 16・17 のとき、または目印が nil（今日のおすすめから開いた）ときは何も付けない＝今までどおり下から出る。
private struct DetailZoomTransitionModifier: ViewModifier {
    /// 出どころの目印（カードに渡した `PostCardZoomTransition.sourceID` と同じ値）。nil ならズームしない
    let sourceID: String?
    /// カードと共有する名前空間（HomeView の `detailZoomNamespace`）
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let sourceID {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
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
            160 // ランドスケープiPhone: 画面高さが制限されるため短く
        } else if horizontalSizeClass == .regular {
            360 // iPad縦向き
        } else {
            240 // ポートレートiPhone
        }
    }

    var body: some View {
        // サムネイルを優先的に表示
        // 公開は URL、公開以外は Storage のパスで読む（サムネイルの手がかりが無ければフルサイズ画像。判定は PostImageSource）
        if let image = KFImage.post(PostImageSource.resolve(imageInfo, prefersThumbnail: true)) {
            image
                .placeholder {
                    ProgressView()
                }
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, minHeight: imageHeight, maxHeight: imageHeight)
                .clipped()
        } else {
            // 読めない場合（パスも URL も無い）
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
    /// 表示中の投稿。`let` ではなく `@State` にしているのは、再編集（画像URL・公開範囲の
    /// 上書き更新）後に `.postCreated` 通知を受けて最新の投稿へ差し替えるため（統合レビューで発見）。
    /// 差し替えないと、共有カード/保存/共有が削除済みの旧Storage画像や旧公開範囲を使い続ける。
    @State private var post: Post
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var likeManager: LikeManager
    @EnvironmentObject private var favoriteManager: FavoriteManager
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
    /// タップされたハッシュタグ。non-nil でタグ詳細画面を全画面提示する ⭐️
    @State private var selectedTag: String?
    /// 再編集（投稿済み画像の上書き）起動ペイロード。non-nil で EditView を全画面提示。
    @State private var reEditLaunch: ReEditLaunchPayload?
    /// 空カード共有パック ⭐️: 書き出し元画像のダウンロード完了後にセットして
    /// ShareCardExportView を提示する（item: 方式＝画像が確実に揃ってから構築）。
    @State private var shareCardExportPayload: ShareCardExportPayload?
    /// 空カード共有パック ⭐️: 書き出し元画像のDL中フラグ（表示用）。
    /// cf. isPreparingReEdit（isSaving を流用すると「保存中...」の誤表示になるため専用フラグにする）。
    @State private var isPreparingShareCard = false
    /// 元画像ダウンロード中フラグ（編集準備中の二重起動防止＋表示用）。
    @State private var isPreparingReEdit = false
    /// おすすめの空の追加 / 外すの結果（non-nil でアラートを出す）⭐️
    @State private var recommendationOutcome: RecommendationManager.Outcome?
    /// 全画面のビューアで開いている写真（non-nil で PostPhotoViewer を全画面で出す）⭐️ PR-H 5b
    @State private var photoViewerItem: PostPhotoViewerItem?

    private let downloadService: ImageDownloadServiceProtocol = ImageDownloadService.shared

    // `post` を `@State` にしたことで自動生成の memberwise init が private 化されてしまう
    // （private プロパティを含む struct の既定挙動）ため、他ファイル（SearchView / ProfileView /
    // SkyCalendarDiaryView / HomeView 自身）からの `PostDetailView(post:)` 呼び出しを維持するために
    // 明示的な init を用意する。
    init(post: Post) {
        _post = State(initialValue: post)
    }

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
                    // ⚠️ この詳細は GalleryView など checkLikeStatus を呼ばない画面からも開かれる。
                    //    1 read ずつ足して、♥ と 🔖 の表示が常にサーバー値と一致するようにする（♥ は issue #145）。⭐️
                    Task { await likeManager.checkLikeStatus(for: [post]) }
                    Task { await favoriteManager.checkFavoriteStatus(for: [post]) }
                    // 「…」メニューの「おすすめの空に追加 / から外す」の表示用（読み込み済みなら何もしない）⭐️
                    Task { await RecommendationManager.shared.load() }
                }
                .alert("投稿を削除", isPresented: $showingDeleteConfirmation) {
                    Button("削除", role: .destructive) {
                        Task {
                            let success = await viewModel.deletePost(post)
                            if success { dismiss() }
                        }
                    }
                    Button("キャンセル", role: .cancel) {}
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
                    Button("キャンセル", role: .cancel) {}
                }
                .alert("ユーザーをブロック", isPresented: $showingBlockConfirmation) {
                    Button("キャンセル", role: .cancel) {}
                    Button("ブロック", role: .destructive) {
                        Task { await blockPostAuthor() }
                    }
                } message: {
                    // 本文はプロフィール・ギャラリー・そらともと同じ（C 項目 3・利用者が承認済み 2026-10-19）
                    Text("この人の投稿が、ホーム・ギャラリー・そらともに表示されなくなります。お互いのフォローも外れます。ブロックしたことは相手に知らされません")
                }
                .alert("通報しました", isPresented: $showingReportConfirmation) {
                    Button("OK") {}
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
                // 空カード共有パック ⭐️: 透かし付き共有カードの書き出しシート
                .sheet(item: $shareCardExportPayload) { payload in
                    ShareCardExportView(post: post, sourceImage: payload.image)
                }
                // ハッシュタグ → タグ詳細画面 ⭐️
                // この画面自体がシート上に載るため、全画面カバーで開く。
                .fullScreenCover(item: Binding<IdentifiableString?>(
                    get: { selectedTag.map(IdentifiableString.init) },
                    set: { selectedTag = $0?.id }
                )) { wrapper in
                    TagDetailView(tag: wrapper.id, source: "post_detail", likeManager: likeManager, favoriteManager: favoriteManager)
                }
                // 再編集: 元画像＋レシピをエディタへ。保存時は既存投稿を上書き更新する。
                // item: 方式で「画像が確実に揃ってから」EditView を構築する（stale-state 回避）。
                .fullScreenCover(item: $reEditLaunch) { launch in
                    EditView(
                        images: launch.images,
                        userId: launch.post.userId, // 自分の投稿のみ編集可なので post.userId = 自分
                        initialRecipe: launch.post.attachedRecipe,
                        editingContext: launch.editingContext
                    )
                }
                .overlay { savingOverlay }
                // 再編集の保存完了時にも発火する通知。自分が表示中の投稿を最新状態に取り直す
                // （fullScreenCover の下に隠れていても購読は生き続けるため、再編集→保存→
                //  カバーが閉じて戻ってきた時点で post は最新化済みになる）。
                .onReceive(NotificationCenter.default.publisher(for: .postCreated)) { _ in
                    // .onReceive の perform クロージャは非 isolated なので、await 後に
                    // @State へ書き込むには @MainActor を明示する（CalendarDiaryViewModel の
                    // 通知購読と同じ理由）。
                    Task { @MainActor in
                        if let refreshed = await viewModel.refreshPost(postId: post.id) {
                            post = refreshed
                        }
                    }
                }
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
        if hasOriginalImages, (post.originalImages?.count ?? 0) > 1 {
            Button("すべての画像を保存（オリジナル）") {
                Task { await saveImage(edited: false, all: true) }
            }
        }
        Button("キャンセル", role: .cancel) {}
    }

    /// savingOverlay に表示するメッセージ（状態に応じて出し分け）
    private var overlayMessage: String {
        if isPreparingReEdit { return "編集の準備中..." }
        if isPreparingShareCard { return "共有カードの準備中..." }
        return "保存中..."
    }

    @ViewBuilder
    private var savingOverlay: some View {
        // 保存中だけでなく「再編集の元画像DL中」「共有カードの元画像DL中」もオーバーレイを出す。
        // これらのボタンは Menu 内＝タップで即閉じるためボタン上の「準備中…」表記は見えない。
        // 数秒の DL 中に無反応にならないよう、ここで全画面インジケータを出す（G1 対応）。
        if isSaving || isPreparingReEdit || isPreparingShareCard {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)
                    Text(overlayMessage)
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
                } else {
                    // 取得失敗時（publicProfiles 未作成の旧アカウント・ゲスト閲覧・一過性の
                    // ネットワーク失敗）でも著者ブロックごと消さず、PostCard と同じ
                    // プレースホルダ（灰色アイコン＋「ユーザー」）を表示する。
                    authorSection(user: nil)
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
        // おすすめの空の結果アラート ⭐️
        // ⚠️ body の修飾子チェーンに足すと Xcode 27 の型チェックが重くなる（#123）ため、ここに付ける
        .recommendationOutcomeAlert($recommendationOutcome)
    }

    // MARK: - Multi Image Carousel ⭐️

    // 複数画像投稿で 2 枚目以降が見えなくなっていたバグ対応。
    // TabView + .page スタイルで横スワイプ閲覧を可能にし、
    // 配列内で最も縦長なアスペクト比に TabView 全体の高さを合わせる。
    @ViewBuilder
    private func multiImageCarousel(images: [ImageInfo]) -> some View {
        let aspect = carouselAspectRatio(for: images)
        TabView {
            ForEach(Array(images.enumerated()), id: \.offset) { index, info in
                // 読める写真か（読めない写真は灰色の枠なので、タップしても開かない＝ボタンとして読み上げない）
                let isReadable = PostImageSource.resolve(info, prefersThumbnail: false) != .unavailable
                PostDetailImageView(imageInfo: info)
                    // 写真の枠全体でタップを受ける ⭐️ PR-H 5b
                    .contentShape(Rectangle())
                    // 1 回タップで、この 1 枚を全画面のビューアで開く ⭐️ PR-H 5b
                    .onTapGesture {
                        openPhotoViewer(index: index, imageInfo: info, imageCount: images.count)
                    }
                    // VoiceOver: 読める写真だけ「ボタン」と「全画面で表示します」を足す ⭐️ PR-H 5b
                    .accessibilityAddTraits(isReadable ? .isButton : [])
                    .accessibilityHint(isReadable ? "全画面で表示します" : "")
            }
        }
        .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .aspectRatio(aspect, contentMode: .fit)
        // 全画面の写真ビューア ⭐️ PR-H 5b
        // ⚠️ body の修飾子チェーンに足すと Xcode 27 の型チェックが重くなる（#123）ため、カルーセルに付ける
        .fullScreenCover(item: $photoViewerItem) { item in
            PostPhotoViewer(imageInfo: item.imageInfo)
        }
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

    /// 写真を全画面のビューアで開き、開いたことを計装する ⭐️ PR-H 5b
    ///
    /// 読めない写真（`PostImageSource` が `.unavailable`＝灰色の枠）は、開いても何も見えないので何もしない（計装も送らない）。
    /// 計装 `post_photo_viewer_opened` は、何枚目（0 始まり）と全部で何枚かだけを送る（UID は送らない・利用者の決定 2026-10-28）。
    /// - Parameters:
    ///   - index: カルーセルの何ページ目か（0 始まり）
    ///   - imageInfo: 開く写真
    ///   - imageCount: 投稿の写真の枚数
    private func openPhotoViewer(index: Int, imageInfo: ImageInfo, imageCount: Int) {
        guard PostImageSource.resolve(imageInfo, prefersThumbnail: false) != .unavailable else { return }
        photoViewerItem = PostPhotoViewerItem(id: index, imageInfo: imageInfo)
        LoggingService.shared.logEvent(
            "post_photo_viewer_opened",
            parameters: PostPhotoViewerMath.openedEventParameters(imageIndex: index, imageCount: imageCount)
        )
    }

    private var postInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let caption = post.caption {
                Text(caption)
                    .font(.body)
                    .foregroundColor(.white)
            }
            // ハッシュタグ（タップでタグ詳細画面へ）⭐️
            if let hashtags = post.hashtags, !hashtags.isEmpty {
                HashtagChipRow(hashtags: hashtags, style: .detail, layout: .scroll) { tag in
                    selectedTag = tag
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
                // いいね — 共通部品（触覚・弾み・数字の入れ替わりは部品の中）⭐️ PR-H
                PostLikeButton(
                    isLiked: likeManager.isLiked(post.id),
                    count: likeManager.likeCount(for: post),
                    style: .detail,
                    action: {
                        Task { await likeManager.toggleLike(post: post, source: "post_detail", method: .button) }
                    }
                )

                Label("\(post.commentsCount)", systemImage: "bubble.right.fill")
                    .font(.headline)
                    .foregroundColor(DesignTokens.Colors.textSecondary)

                Spacer()

                // お気に入り（🔖）ボタン ⭐️ 件数は出さない（自分だけのプライベート保存）
                // 共通部品（触覚・弾み・読み上げのラベルは部品の中）⭐️ PR-H
                PostFavoriteButton(
                    isFavorited: favoriteManager.isFavorited(post.id),
                    style: .detail,
                    action: {
                        Task { await favoriteManager.toggleFavorite(post: post, source: "post_detail") }
                    }
                )
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
                Button {
                    Task { await exportShareCard() }
                } label: {
                    Label("共有カードを書き出す", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(isPreparingShareCard || isPreparingReEdit)
                // 私のおすすめの空に追加 / から外す（公開投稿のみ表示）⭐️
                RecommendMenuButton(post: post, source: "post_detail") { outcome in
                    recommendationOutcome = outcome
                }
                Divider()
                if viewModel.isOwnPost(post) {
                    // 再編集: 元画像(originalImages)を持つ投稿のみ。
                    // 旧投稿(元画像なし)は再編集すると焼き込み済み画像を再び焼く＝二重焼きになるため非表示。
                    if hasOriginalImages {
                        // Menu はタップで即閉じるためラベル切替は見えないが、.disabled は
                        // Menu 項目にも反映される。二重起動防止の本体は各関数内の guard（排他）。
                        Button {
                            Task { await prepareReEdit() }
                        } label: {
                            Label("編集", systemImage: "slider.horizontal.3")
                        }
                        .disabled(isPreparingShareCard || isPreparingReEdit)
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
            let infos: [ImageInfo]
            if edited {
                infos = all ? post.images : [post.images.first].compactMap { $0 }
            } else {
                let originals = post.originalImages ?? []
                infos = all ? originals : [originals.first].compactMap { $0 }
            }
            // 公開以外は Storage のパスで読む（URL 側の C-2）。「すべて」は読めない 1 枚があればそこで失敗する（今と同じ）
            let sources = infos.map { PostImageSource.resolve($0, prefersThumbnail: false) }

            let savedCount = try await downloadService.downloadAndSaveImages(from: sources)
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
            guard let imageInfo = post.images.first else {
                saveResultMessage = "共有する画像がありません"
                showingSaveResult = true
                return
            }
            // 公開以外は Storage のパスで読む（URL 側の C-2）
            let image = try await downloadService.downloadImage(from: PostImageSource.resolve(imageInfo, prefersThumbnail: false))
            shareImages = [image]
            showingShareSheet = true
        } catch {
            saveResultMessage = error.userFriendlyMessage
            showingSaveResult = true
        }
    }

    /// 空カード共有パック ⭐️: 投稿の1枚目をDLし、共有カード書き出しシートを提示する。
    /// 再編集の元画像DL（isPreparingReEdit）とも排他にする（統合レビューで発見: 別々の guard だと
    /// DL待ち中に Menu から他方を選べてしまい、二重モーダルが起き得た）。
    @MainActor
    private func exportShareCard() async {
        guard !isPreparingShareCard, !isPreparingReEdit else { return }
        isPreparingShareCard = true
        defer { isPreparingShareCard = false }

        do {
            guard let imageInfo = post.images.first else {
                saveResultMessage = "共有する画像がありません"
                showingSaveResult = true
                return
            }
            // 公開以外は Storage のパスで読む（URL 側の C-2）
            let image = try await downloadService.downloadImage(from: PostImageSource.resolve(imageInfo, prefersThumbnail: false))
            shareCardExportPayload = ShareCardExportPayload(image: image)
        } catch {
            saveResultMessage = error.userFriendlyMessage
            showingSaveResult = true
        }
    }

    /// 再編集: 元画像(originalImages)を order 順に DL し、元投稿の seed を付けてエディタを起動する。
    /// 失敗・元画像なしのときはエラーを表示して起動しない。
    /// 共有カード書き出しの元画像DL（isPreparingShareCard）とも排他にする（統合レビューで発見）。
    @MainActor
    private func prepareReEdit() async {
        guard !isPreparingReEdit, !isPreparingShareCard, hasOriginalImages else { return }
        isPreparingReEdit = true
        defer { isPreparingReEdit = false }

        let infos = (post.originalImages ?? []).sorted { $0.order < $1.order }
        // 公開以外は Storage のパスで読む（URL 側の C-2）。読めない元画像は今までどおり落とす
        let sources = infos.map { PostImageSource.resolve($0, prefersThumbnail: false) }.filter { $0 != .unavailable }
        guard !sources.isEmpty else {
            saveResultMessage = "元画像が見つかりませんでした"
            showingSaveResult = true
            return
        }
        do {
            let images = try await downloadService.downloadImages(from: sources)
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

    /// 投稿者ヘッダー。
    /// 引数は `User` ではなく `PublicProfile`（他人の `users` は権限で読めないため）。
    /// 表示に使うのは displayName / photoURL の 2 つだけなので、公開プロフィールで足りる。
    /// nil の場合（取得失敗・ゲスト閲覧）は灰色アイコン＋「ユーザー」のプレースホルダになる。
    private func authorSection(user: PublicProfile?) -> some View {
        HStack(spacing: 12) {
            // プロフィール画像
            if let url = StorageImageURL.url(from: user?.photoURL) {
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
            // PublicProfile には email 等の機密フィールドが型として存在しないため、
            // 誤って表示するリスクは構造的に発生しない（User を渡していた頃の注記を更新）
            VStack(alignment: .leading, spacing: 4) {
                Text(user?.displayName ?? "ユーザー")
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
        // 公開は URL、公開以外は Storage のパスで読む（判定は PostImageSource）
        if let image = KFImage.post(PostImageSource.resolve(imageInfo, prefersThumbnail: false)) {
            image
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
    /// 見出しのロゴ画像のアセット名（Assets.xcassets の SoramoyouLogo.imageset）
    ///
    /// 最低 iOS 16 なので、アセットから自動で作られる名前付きの参照（生成シンボル `Image(.xxx)`。iOS 17〜）が使えない。
    /// そのため文字列で引く。名前を打ち間違えてもビルドは通ってしまうので、
    /// 打ち間違いは HomeToolbarImageAssetTests で拾う
    static let logoAssetName = "SoramoyouLogo"

    var body: some View {
        VStack(spacing: 2) {
            // ⭐️ PR-H: 文字の題をロゴ画像に替えた（利用者の決定 2026-10-24）。副題は文字のまま
            //    （ロゴの絵の副題は 30pt の高さだと約 6pt になって読めないので、絵からは切り落としてある）
            Image(Self.logoAssetName)
                // ツールバーの中の画像は、何もしないと単色（テンプレート）に塗られることがあるので元の色で描く
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(height: 30)
                // 画像の名前でなく、前の文字の題と同じ「そらもよう」と読み上げる
                .accessibilityLabel("そらもよう")
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
                        Color(red: 0.4, green: 0.6, blue: 0.9), // 明るい空色
                        Color(red: 0.3, green: 0.5, blue: 0.85), // 中間の青
                        Color(red: 0.5, green: 0.3, blue: 0.8), // 夕暮れのパープル
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

// MARK: - ShareCardExportPayload ⭐️ 空カード共有パック

/// 共有カード書き出しシート起動ペイロード。
/// `sheet(item:)` で「画像が確実にDLされてから」ShareCardExportView を構築するための箱
/// （cf. ReEditLaunchPayload / stale-state 回避の既存パターン）。
struct ShareCardExportPayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - Home Feed Segment ⭐️ PR-7

/// ホームのフィード切り替えセグメント
enum HomeFeedSegment: String, CaseIterable, Identifiable {
    /// 全公開投稿（従来のホームフィード）
    case all
    /// フォロー中のユーザー＋フォロータグの投稿（マージフィード）
    case forYou

    var id: String { rawValue }

    /// セグメントの表示名
    var title: String {
        switch self {
        case .all: "すべて"
        case .forYou: "あなた向け"
        }
    }

    /// 計装（home_feed_segment_changed）用の値
    var analyticsValue: String {
        switch self {
        case .all: "all"
        case .forYou: "for_you"
        }
    }
}

// MARK: - Home Feed Segment Change Via ⭐️ PR-H

/// ホームのフィード切り替えが、上の切り替え（Picker）のタップか、左右のめくり（TabView）かの区別 ⭐️ PR-H
///
/// 計装（home_feed_segment_changed）の `via` に rawValue をそのまま送る。
/// PostHog で集計する文字なので、名前を変えると過去の記録と分かれてしまう（テストで文字を固定している）。
enum HomeFeedSegmentChangeVia: String {
    /// 上の切り替え（Picker）をタップした
    case tap
    /// 左右にめくった（TabView のページ送り）
    case swipe
}

/// 「次の切り替えは上のタップから来た」の印を持ち、onChange で 1 回だけ読み出す ⭐️ PR-H
///
/// Picker と TabView は同じ `selectedSegment` を共有しているので、`onChange(of: selectedSegment)` だけでは
/// どちらで切り替わったか分からない。そこで Picker の Binding の set（タップのときだけ通る）で印を立て、
/// onChange で読み出して下ろす。印が無いまま onChange が来たら、めくり（TabView が直接書いた）と見なす。
struct HomeFeedSegmentChangeTracker {
    /// 上のタップから来た切り替えを、まだ onChange で読み出していないか
    private(set) var isTapPending = false

    /// Picker の Binding の set から呼ぶ（タップで選ばれた値を受ける）
    ///
    /// 今と同じ値を選び直しただけのときは印を立てない。値が変わらないと onChange が来ず印が残り、
    /// 次のめくりが tap と記録されてしまうため。
    /// - Parameters:
    ///   - current: 今選ばれているセグメント（代入する前の値）
    ///   - newValue: タップで選ばれたセグメント
    mutating func noteTap(from current: HomeFeedSegment, to newValue: HomeFeedSegment) {
        guard newValue != current else { return }
        isTapPending = true
    }

    /// onChange から呼ぶ。印があれば tap、無ければ swipe を返し、印を下ろす
    /// - Returns: この切り替えがどちらから来たか
    mutating func consume() -> HomeFeedSegmentChangeVia {
        let via: HomeFeedSegmentChangeVia = isTapPending ? .tap : .swipe
        // 印は 1 回の切り替えにつき 1 回だけ使う（次の切り替えに持ち越さない）
        isTapPending = false
        return via
    }
}

// MARK: - Home Detail Zoom ⭐️ PR-H

/// ホームのカードの写真から詳細へ広がるズーム遷移（iOS 18 以上）の目印を作る ⭐️ PR-H
///
/// 画面に依存しない純粋な関数にしておき、目印の文字の形をテスト（HomeDetailZoomTests）で固定している。
enum HomeDetailZoom {
    /// ズーム遷移の目印（matchedTransitionSource と navigationTransition(.zoom) で同じ値を使う）
    ///
    /// 投稿 ID だけでなく、ページ名（`HomeFeedSegment` の rawValue）も混ぜる。
    /// ホームは「すべて」と「あなた向け」の 2 ページを左右にめくる作り（page 形式の TabView）で、
    /// 隣のページも同時に作られて生きているうえ、同じ投稿が両方のページに出うる。
    /// 投稿 ID だけだと 2 枚のカードの写真が同じ目印を持って衝突し、どちらの写真から広がるかが定まらない。
    /// ページ名を混ぜれば、今触ったページのカードの写真だけが出どころになる。
    /// - Parameters:
    ///   - segment: カードが出ているページ
    ///   - postID: 投稿の ID
    /// - Returns: 目印の文字（例 "all-p1"・"forYou-p1"）
    static func sourceID(segment: HomeFeedSegment, postID: String) -> String {
        "\(segment.rawValue)-\(postID)"
    }
}
