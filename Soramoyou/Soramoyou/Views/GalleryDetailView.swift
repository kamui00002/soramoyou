//
//  GalleryDetailView.swift ☁️⭐️
//  Soramoyou
//
//  Created on 2025-01-19.
//
//  エラー/ロード状態の統一対応・セキュリティ改善

import SwiftUI
import Kingfisher

struct GalleryDetailView: View {
    let post: Post
    /// 投稿削除時に呼ばれるコールバック（一覧からの除去などに使用）
    var onPostDeleted: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var likeManager: LikeManager
    /// 投稿者情報の取得にはPostDetailViewModelを使用（GalleryDetailViewModelとの二重定義を解消）
    @StateObject private var viewModel = PostDetailViewModel()
    @StateObject private var commentViewModel = CommentViewModel()
    @State private var commentText = ""
    @State private var showingOriginalImage = false
    @State private var showingReportSheet = false
    @State private var showingBlockConfirmation = false
    @State private var showingReportConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var showingSaveOptions = false
    @State private var showingShareSheet = false
    @State private var isSaving = false
    @State private var saveResultMessage: String?
    @State private var showingSaveResult = false
    @State private var shareImages: [UIImage] = []
    /// 再編集（投稿済み画像の上書き）起動ペイロード。non-nil で EditView を全画面提示。
    @State private var editLaunch: ReEditLaunchPayload?
    /// 元画像ダウンロード中フラグ（編集準備中の二重起動防止＋表示用）。
    @State private var isPreparingEdit = false

    private let downloadService: ImageDownloadServiceProtocol = ImageDownloadService.shared

    // オリジナル画像が利用可能かどうか
    private var hasOriginalImages: Bool {
        post.originalImages != nil && !(post.originalImages?.isEmpty ?? true)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 投稿者情報 ☁️
                    // InlineLoadingViewを使用して統一されたローディング表示
                    if let user = viewModel.author {
                        authorSection(user: user)
                    } else if viewModel.isLoadingAuthor {
                        InlineLoadingView(message: "投稿者情報を読み込み中...")
                            .padding()
                    }

                    // 画像表示（編集前後切り替え対応）
                    imageSection

                    // 編集前後切り替えボタン
                    if hasOriginalImages {
                        toggleButton
                    }

                    // 編集設定表示
                    if let editSettings = post.editSettings {
                        editSettingsSection(editSettings: editSettings)
                    }

                    // このレシピで編集（レシピ共有）⭐️
                    // attachedRecipe 付き投稿（v1.7.0 以降）でのみ表示。
                    // 中立レシピ・未ログイン時の非表示ゲートはコンポーネント内部で行う。
                    if let recipe = post.attachedRecipe {
                        UseRecipeButton(recipe: recipe, postId: post.id)
                    }

                    // 外部アプリ（写真App等）の編集情報・撮影特性表示 ⭐️ Issue #4
                    if hasAnyExternalEditInfo {
                        externalEditInfoSection
                    }

                    // 投稿情報
                    postInfoSection

                    // 空の種類・時間帯・色温度
                    skyInfoSection

                    // 統計情報
                    statsSection

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
            .background(DesignTokens.Colors.detailBackground)
            .navigationTitle("投稿詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignTokens.Colors.detailBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        // 写真に保存
                        Button {
                            showingSaveOptions = true
                        } label: {
                            Label("写真に保存", systemImage: "square.and.arrow.down")
                        }

                        // 共有
                        Button {
                            Task { await shareCurrentImage() }
                        } label: {
                            Label("共有", systemImage: "square.and.arrow.up")
                        }

                        Divider()

                        // 自分の投稿の場合のみ編集・削除を表示
                        if viewModel.isOwnPost(post) {
                            // 再編集: 元画像(originalImages)を持つ投稿のみ。
                            // 旧投稿(元画像なし)は再編集すると焼き込み済み画像を再び焼く＝二重焼きになるため非表示。
                            if hasOriginalImages {
                                Button {
                                    Task { await prepareReEdit() }
                                } label: {
                                    Label(isPreparingEdit ? "準備中…" : "編集", systemImage: "slider.horizontal.3")
                                }
                                .disabled(isPreparingEdit)
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
            .onAppear {
                Task {
                    await viewModel.loadAuthor(userId: post.userId)
                    await commentViewModel.fetchComments(postId: post.id)
                }
            }
            // 再編集: 元画像＋レシピをエディタへ。保存時は既存投稿を上書き更新する。
            // item: 方式で「画像が確実に揃ってから」EditView を構築する（stale-state 回避）。
            .fullScreenCover(item: $editLaunch) { launch in
                EditView(
                    images: launch.images,
                    userId: launch.post.userId,          // 自分の投稿のみ編集可なので post.userId = 自分
                    initialRecipe: launch.post.attachedRecipe,
                    editingContext: launch.editingContext
                )
            }
            // 投稿削除確認アラート
            .alert("投稿を削除", isPresented: $showingDeleteConfirmation) {
                Button("削除", role: .destructive) {
                    Task {
                        let success = await viewModel.deletePost(post)
                        if success {
                            onPostDeleted?()
                            dismiss()
                        }
                        // 失敗時は viewModel.deleteError がセットされ、下の alert で表示
                    }
                }
                Button("キャンセル", role: .cancel) { }
            } message: {
                Text("この投稿を削除しますか？この操作は取り消せません。")
            }
            // 削除失敗アラート
            .alert("削除に失敗しました", isPresented: Binding(
                get: { viewModel.deleteError != nil },
                set: { if !$0 { viewModel.deleteError = nil } }
            )) {
                Button("OK") { viewModel.deleteError = nil }
            } message: {
                Text(viewModel.deleteError ?? "")
            }
            // 通報理由選択シート
            .confirmationDialog("通報理由を選択", isPresented: $showingReportSheet) {
                ForEach(ReportReason.allCases, id: \.self) { reason in
                    Button(reason.displayName) {
                        Task {
                            await viewModel.submitReport(post: post, reason: reason)
                            if viewModel.reportError == nil {
                                showingReportConfirmation = true
                            }
                        }
                    }
                }
                Button("キャンセル", role: .cancel) { }
            }
            // ブロック確認アラート
            .alert("ユーザーをブロック", isPresented: $showingBlockConfirmation) {
                Button("キャンセル", role: .cancel) { }
                Button("ブロック", role: .destructive) {
                    Task {
                        await viewModel.blockPostAuthor(post: post)
                        if viewModel.reportError == nil {
                            dismiss()
                        }
                    }
                }
            } message: {
                Text("このユーザーをブロックすると、このユーザーの投稿がフィードに表示されなくなります。")
            }
            // 通報完了アラート
            .alert("通報しました", isPresented: $showingReportConfirmation) {
                Button("OK") { }
            } message: {
                Text("ご報告ありがとうございます。内容を確認いたします。")
            }
            // 保存オプション選択
            .confirmationDialog("保存オプション", isPresented: $showingSaveOptions) {
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
            // 保存結果アラート
            .alert(saveResultMessage ?? "", isPresented: $showingSaveResult) {
                Button("OK") { saveResultMessage = nil }
            }
            // 共有シート
            .sheet(isPresented: $showingShareSheet) {
                ImageShareSheet(images: shareImages)
            }
            // 保存中オーバーレイ
            .overlay {
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
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Save / Share Methods

    /// 画像を写真ライブラリに保存
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

    /// 現在表示中の画像を共有シートで共有
    /// 再編集: 元画像(originalImages)を order 順に DL し、元投稿の seed を付けてエディタを起動する。
    /// 失敗・元画像なしのときはエラーを表示して起動しない。
    @MainActor
    private func prepareReEdit() async {
        guard !isPreparingEdit, hasOriginalImages else { return }
        isPreparingEdit = true
        defer { isPreparingEdit = false }

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
            editLaunch = ReEditLaunchPayload(post: post, images: images)
        } catch {
            saveResultMessage = "元画像の読み込みに失敗しました"
            showingSaveResult = true
        }
    }

    private func shareCurrentImage() async {
        isSaving = true
        defer { isSaving = false }

        do {
            let urlString: String
            if showingOriginalImage, let original = post.originalImages?.first {
                urlString = original.url
            } else if let first = post.images.first {
                urlString = first.url
            } else {
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

    // MARK: - Image Section

    private var imageSection: some View {
        Group {
            if showingOriginalImage, let originalImages = post.originalImages, !originalImages.isEmpty {
                // オリジナル画像を表示（複数枚はスワイプで切り替え）
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "photo")
                            .foregroundColor(.orange)
                        Text("編集前")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)
                    }

                    multiImageCarousel(images: originalImages)
                }
            } else if !post.images.isEmpty {
                // 編集後の画像を表示（複数枚はスワイプで切り替え）
                VStack(alignment: .leading, spacing: 8) {
                    if hasOriginalImages {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundColor(.blue)
                            Text("編集後")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                        }
                    }

                    multiImageCarousel(images: post.images)
                }
            }
        }
    }

    // MARK: - Multi Image Carousel ⭐️
    // 複数画像投稿を横スワイプで閲覧可能にするカルーセル。
    // 縦長・横長が混在しても画像が切れないよう、配列内で最も縦長な
    // アスペクト比に TabView 全体の高さを合わせる。
    @ViewBuilder
    private func multiImageCarousel(images: [ImageInfo]) -> some View {
        let aspect = carouselAspectRatio(for: images)
        TabView {
            ForEach(Array(images.enumerated()), id: \.offset) { _, info in
                GalleryDetailImageView(imageInfo: info)
            }
        }
        // 1枚のときはドット非表示、複数のときだけインジケーターを出す
        .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .aspectRatio(aspect, contentMode: .fit)
    }

    /// 画像配列の中で最も縦長なアスペクト比（width / height）を返す。
    /// SwiftUI の `.aspectRatio(_:contentMode:)` は width:height の比率を取るため、
    /// 最も小さい width/height（=最も縦長）を採用すれば、どの画像も切れずに収まる。
    private func carouselAspectRatio(for images: [ImageInfo]) -> CGFloat {
        let ratios = images.compactMap { info -> CGFloat? in
            guard info.width > 0, info.height > 0 else { return nil }
            return CGFloat(info.width) / CGFloat(info.height)
        }
        return ratios.min() ?? 1.0
    }

    // MARK: - Toggle Button

    private var toggleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.3)) {
                showingOriginalImage.toggle()
            }
        }) {
            HStack {
                Image(systemName: showingOriginalImage ? "slider.horizontal.3" : "photo")
                Text(showingOriginalImage ? "編集後を表示" : "編集前を表示")
            }
            .font(.body)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: showingOriginalImage ? [Color.blue, Color.blue.opacity(0.8)] : [Color.orange, Color.orange.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
        }
    }

    // MARK: - External Edit Info Section ⭐️ Issue #4

    /// 投稿の画像群に1つでも外部編集情報があるか
    private var hasAnyExternalEditInfo: Bool {
        post.images.contains { $0.externalEditInfo != nil }
    }

    /// 写真Appや他社アプリ由来の編集情報・HDR/Live/Pano フラグ等を表示
    private var externalEditInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "photo.badge.checkmark")
                    .foregroundColor(DesignTokens.Colors.skyBlue)
                Text("撮影・外部編集情報")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(post.images.enumerated()), id: \.offset) { index, info in
                    if let ext = info.externalEditInfo {
                        externalEditInfoRow(index: index, info: ext)
                    }
                }

                // Apple 純正写真App編集の場合は、数値が取得不可な旨を注記
                if post.images.contains(where: {
                    $0.externalEditInfo?.formatIdentifier == "com.apple.photo"
                }) {
                    Text("※ iPhone「写真」アプリの調整値（露出 / コントラスト等）は Apple の API で公開されていないため、本アプリでは数値を取得できません。")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.55))
                        .padding(.top, 4)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignTokens.Colors.detailCardBackground)
            )
        }
    }

    private func externalEditInfoRow(index: Int, info: ExternalEditInfo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // 複数枚の場合は何枚目かを示す
            if post.images.count > 1 {
                Text("画像\(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .frame(width: 50, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let badge = info.badgeLabel {
                    Label(badge, systemImage: "wand.and.stars")
                        .font(.caption.weight(.medium))
                        .foregroundColor(DesignTokens.Colors.selectionAccent)
                }
                if !info.subtypeBadges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(info.subtypeBadges, id: \.self) { sub in
                            Text(sub)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(DesignTokens.Colors.skyBlue.opacity(0.25))
                                )
                                .foregroundColor(.white)
                        }
                    }
                }
                if let date = info.creationDate {
                    Text("撮影: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            Spacer()
        }
    }

    // MARK: - Edit Settings Section

    private func editSettingsSection(editSettings: EditSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(DesignTokens.Colors.skyBlue)
                Text("編集設定")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 8) {
                // 適用フィルター
                if let filter = editSettings.appliedFilter {
                    editSettingRow(icon: "camera.filters", label: "フィルター", value: filter.displayName)
                }

                // 各編集パラメータ
                if let brightness = editSettings.brightness, brightness != 0 {
                    editSettingRow(icon: "sun.max", label: "明るさ", value: formatValue(brightness))
                }

                if let contrast = editSettings.contrast, contrast != 0 {
                    editSettingRow(icon: "circle.lefthalf.filled", label: "コントラスト", value: formatValue(contrast))
                }

                if let saturation = editSettings.saturation, saturation != 0 {
                    editSettingRow(icon: "drop.fill", label: "彩度", value: formatValue(saturation))
                }

                if let exposure = editSettings.exposure, exposure != 0 {
                    editSettingRow(icon: "plusminus.circle", label: "露出", value: formatValue(exposure))
                }

                if let highlight = editSettings.highlight, highlight != 0 {
                    editSettingRow(icon: "sun.max.fill", label: "ハイライト", value: formatValue(highlight))
                }

                if let shadow = editSettings.shadow, shadow != 0 {
                    editSettingRow(icon: "shadow", label: "シャドウ", value: formatValue(shadow))
                }

                if let warmth = editSettings.warmth, warmth != 0 {
                    editSettingRow(icon: "thermometer", label: "暖かみ", value: formatValue(warmth))
                }

                if let sharpness = editSettings.sharpness, sharpness != 0 {
                    editSettingRow(icon: "triangle", label: "シャープネス", value: formatValue(sharpness))
                }

                if let vignette = editSettings.vignette, vignette != 0 {
                    editSettingRow(icon: "viewfinder", label: "ビネット", value: formatValue(vignette))
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignTokens.Colors.detailCardBackground)
            )
        }
    }

    private func editSettingRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(DesignTokens.Colors.textSecondary)
            Text(label)
                .foregroundColor(.white)
            Spacer()
            Text(value)
                .foregroundColor(DesignTokens.Colors.skyBlue)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }

    private func formatValue(_ value: Float) -> String {
        let percentage = Int(value * 100)
        return percentage >= 0 ? "+\(percentage)%" : "\(percentage)%"
    }

    // MARK: - Post Info Section

    private var postInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // キャプション
            if let caption = post.caption {
                Text(caption)
                    .font(.body)
                    .foregroundColor(.white)
            }

            // ハッシュタグ
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

            // 位置情報
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
        }
    }

    // MARK: - Sky Info Section

    private var skyInfoSection: some View {
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
    }

    // MARK: - Stats Section

    private var statsSection: some View {
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
            // セキュリティ: メールアドレスは表示しない（HomeViewのauthorSectionと統一）
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

// MARK: - Gallery Detail Image View

struct GalleryDetailImageView: View {
    let imageInfo: ImageInfo

    var body: some View {
        // フルサイズ画像を表示
        if let imageURL = URL(string: imageInfo.url) {
            KFImage(imageURL)
                .placeholder {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            ProgressView()
                        )
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .cornerRadius(12)
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 300)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                )
                .cornerRadius(12)
        }
    }
}

struct GalleryDetailView_Previews: PreviewProvider {
    static var previews: some View {
        GalleryDetailView(post: Post(
            id: "preview",
            userId: "user1",
            images: [ImageInfo(url: "https://example.com/image.jpg", width: 100, height: 100, order: 0)],
            editSettings: EditSettings(brightness: 0.2, contrast: 0.1, saturation: -0.1, appliedFilter: .warm)
        ))
    }
}
