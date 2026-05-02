//
//  GalleryView.swift ☁️⭐️
//  Soramoyou
//
//  Created on 2025-01-19.
//
//  AsyncContentViewを使用してエラー/ロード状態を統一的に表示する

import SwiftUI
import Kingfisher

struct GalleryView: View {
    @StateObject private var viewModel = GalleryViewModel()
    @EnvironmentObject private var likeManager: LikeManager
    @State private var selectedPost: Post?
    @State private var isSaving = false
    @State private var saveResultMessage: String?
    @State private var showingSaveResult = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private let downloadService: ImageDownloadServiceProtocol = ImageDownloadService.shared

    /// デバイス向き・サイズに応じて列数を動的に変更
    private var columns: [GridItem] {
        let count: Int
        if horizontalSizeClass == .regular {
            count = 5          // iPad
        } else if verticalSizeClass == .compact {
            count = 4          // ランドスケープiPhone
        } else {
            count = 3          // ポートレートiPhone
        }
        return Array(repeating: GridItem(.flexible(), spacing: 2), count: count)
    }

    /// ViewModelの状態をLoadableStateとして取得
    /// PaginatedPostsViewModelの共通プロパティを活用
    private var galleryState: LoadableState<[Post]> {
        viewModel.loadableState
    }

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
                    // AsyncContentViewで状態に応じた表示を統一 ⭐️
                    AsyncContentView(
                        state: galleryState,
                        loadingType: .initial,
                        emptyCheck: { $0.isEmpty },
                        emptyStateType: .custom(
                            icon: "photo.on.rectangle.angled",
                            title: "まだ投稿がありません",
                            description: "みんなの空の写真がここに表示されます",
                            actionTitle: nil
                        ),
                        onRetry: {
                            await viewModel.refresh()
                        },
                        content: { _ in
                            // グリッド表示（viewModel.postsを直接使用してページネーション対応）
                            galleryGrid
                        }
                    )

                    // 画面下部に固定表示されるバナー広告
                    BannerAdContainer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    GradientTitleView(title: "ギャラリー", fontSize: 20)
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
                GalleryDetailView(post: post) {
                    // 削除後にローカルの一覧から除去（ViewModel経由でカプセル化）
                    viewModel.removePost(postId: post.id)
                }
                .environmentObject(likeManager)
            }
            // 保存結果アラート
            .alert(saveResultMessage ?? "", isPresented: $showingSaveResult) {
                Button("OK") { saveResultMessage = nil }
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

    // MARK: - Save Method

    private func savePostImage(post: Post) async {
        isSaving = true
        defer { isSaving = false }

        do {
            guard let urlString = post.images.first?.url else {
                saveResultMessage = "保存する画像がありません"
                showingSaveResult = true
                return
            }
            let image = try await downloadService.downloadImage(from: urlString)
            try await downloadService.saveToPhotoLibrary(image)
            saveResultMessage = "画像を保存しました"
            showingSaveResult = true
        } catch {
            saveResultMessage = error.userFriendlyMessage
            showingSaveResult = true
        }
    }

    // MARK: - Gallery Grid

    private var galleryGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(viewModel.posts) { post in
                    Button {
                        selectedPost = post
                    } label: {
                        GalleryGridItem(post: post)
                    }
                    .buttonStyle(CardButtonStyle())
                    .contextMenu {
                        Button {
                            Task { await savePostImage(post: post) }
                        } label: {
                            Label("写真に保存", systemImage: "square.and.arrow.down")
                        }
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
            }

            // 追加読み込み中のインジケーター
            if viewModel.isLoadingMore {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .padding()
            }

            // これ以上投稿がない場合
            if !viewModel.hasMorePosts && !viewModel.posts.isEmpty {
                Text("すべての投稿を表示しました")
                    .font(.caption)
                    .foregroundColor(DesignTokens.Colors.textTertiary)
                    .padding()
            }
        }
    }
}

// MARK: - Gallery Grid Item

struct GalleryGridItem: View {
    let post: Post

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                // サムネイル画像
                if let firstImage = post.images.first {
                    if let thumbnailURL = firstImage.thumbnail, let url = URL(string: thumbnailURL) {
                        KFImage(url)
                            .placeholder {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .overlay(
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    )
                            }
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.width)
                            .clipped()
                    } else if let imageURL = URL(string: firstImage.url) {
                        KFImage(imageURL)
                            .placeholder {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                                    .overlay(
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    )
                            }
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.width)
                            .clipped()
                    }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(.gray)
                        )
                }

                // 複数画像インジケーター
                if post.images.count > 1 {
                    Image(systemName: "square.stack.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .padding(6)
                }

                // 編集設定があることを示すインジケーター
                if post.editSettings != nil {
                    HStack {
                        Spacer()
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                            .padding(6)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.width)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct GalleryView_Previews: PreviewProvider {
    static var previews: some View {
        GalleryView()
    }
}
