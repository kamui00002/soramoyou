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
    /// 投稿者情報の取得にはPostDetailViewModelを使用（GalleryDetailViewModelとの二重定義を解消）
    @StateObject private var viewModel = PostDetailViewModel()
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

                    // 投稿情報
                    postInfoSection

                    // 空の種類・時間帯・色温度
                    skyInfoSection

                    // 統計情報
                    statsSection
                }
                .padding()
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("投稿詳細")
            .navigationBarTitleDisplayMode(.inline)
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

                        // 自分の投稿の場合のみ削除ボタンを表示
                        if viewModel.isOwnPost(post) {
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
                }
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
                                .fill(Color(UIColor.systemBackground).opacity(0.9))
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
            saveResultMessage = error.localizedDescription
            showingSaveResult = true
        }
    }

    /// 現在表示中の画像を共有シートで共有
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
            saveResultMessage = error.localizedDescription
            showingSaveResult = true
        }
    }

    // MARK: - Image Section

    private var imageSection: some View {
        Group {
            if showingOriginalImage, let originalImages = post.originalImages, let firstOriginal = originalImages.first {
                // オリジナル画像を表示
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "photo")
                            .foregroundColor(.orange)
                        Text("編集前")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)
                    }

                    GalleryDetailImageView(imageInfo: firstOriginal)
                }
            } else if let firstImage = post.images.first {
                // 編集後の画像を表示
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

                    GalleryDetailImageView(imageInfo: firstImage)
                }
            }
        }
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

    // MARK: - Edit Settings Section

    private func editSettingsSection(editSettings: EditSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.blue)
                Text("編集設定")
                    .font(.headline)
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
                    .fill(Color(UIColor.secondarySystemBackground))
            )
        }
    }

    private func editSettingRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.secondary)
            Text(label)
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .foregroundColor(.blue)
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
        }
    }

    // MARK: - Sky Info Section

    private var skyInfoSection: some View {
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
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        HStack(spacing: 24) {
            Label("\(post.likesCount)", systemImage: "heart.fill")
                .font(.headline)
            Label("\(post.commentsCount)", systemImage: "bubble.right.fill")
                .font(.headline)
        }
        .foregroundColor(.secondary)
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
            }

            Spacer()
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
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
