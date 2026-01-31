//
//  GalleryView.swift
//  Soramoyou
//
//  Created on 2025-01-19.
//

import SwiftUI
import Kingfisher

struct GalleryView: View {
    @StateObject private var viewModel = GalleryViewModel()
    @State private var selectedPost: Post?

    // 3列のグリッドレイアウト
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

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
                    ZStack {
                        if viewModel.isLoading && viewModel.posts.isEmpty {
                            // 初回読み込み中
                            VStack {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("読み込み中...")
                                    .foregroundColor(.white)
                            }
                        } else if viewModel.posts.isEmpty {
                            // 投稿がない場合
                            VStack(spacing: 16) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 60))
                                    .foregroundColor(DesignTokens.Colors.textSecondary)
                                Text("まだ投稿がありません")
                                    .font(.headline)
                                    .foregroundColor(DesignTokens.Colors.textSecondary)
                                Text("みんなの空の写真がここに表示されます")
                                    .font(.caption)
                                    .foregroundColor(DesignTokens.Colors.textTertiary)
                            }
                        } else {
                            // グリッド表示
                            galleryGrid
                        }
                    }

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
                GalleryDetailView(post: post)
            }
        }
    }

    // MARK: - Gallery Grid

    private var galleryGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(viewModel.posts) { post in
                    GalleryGridItem(post: post)
                        .onTapGesture {
                            selectedPost = post
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
