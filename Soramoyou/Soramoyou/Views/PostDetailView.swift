//
//  PostDetailView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct PostDetailView: View {
    @StateObject private var viewModel: PostDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showNewCollectionAlert = false
    @State private var newCollectionName = ""

    init(post: Post, userId: String?) {
        _viewModel = StateObject(wrappedValue: PostDetailViewModel(post: post, userId: userId))
    }

    var body: some View {
        ZStack {
            // グラデーション背景（柔らかい青系）
            LinearGradient(
                colors: [
                    Color(red: 0.68, green: 0.85, blue: 0.90),
                    Color(red: 0.53, green: 0.81, blue: 0.98),
                    Color(red: 0.39, green: 0.58, blue: 0.93),
                    Color(red: 0.18, green: 0.25, blue: 0.45)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    // 画像
                    imageSection

                    // アクションバー
                    actionBar

                    // 投稿情報
                    postInfoSection

                    // コメントセクション
                    commentsSection
                }
                .padding(.bottom, 80)
            }

            // コメント入力バー
            VStack {
                Spacer()
                commentInputBar
            }
        }
        .navigationTitle("投稿詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: {
                        viewModel.showAddToCollectionSheet = true
                    }) {
                        Label("コレクションに追加", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.white)
                }
            }
        }
        .task {
            await viewModel.loadInitialData()
        }
        .sheet(isPresented: $viewModel.showAddToCollectionSheet) {
            addToCollectionSheet
        }
        .alert("新しいコレクション", isPresented: $showNewCollectionAlert) {
            TextField("コレクション名", text: $newCollectionName)
            Button("キャンセル", role: .cancel) {
                newCollectionName = ""
            }
            Button("作成") {
                Task {
                    await viewModel.createCollectionAndAdd(name: newCollectionName)
                    newCollectionName = ""
                }
            }
        } message: {
            Text("新しいコレクションの名前を入力してください")
        }
        .alert("エラー", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") {
                viewModel.errorMessage = nil
            }
        } message: {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Image Section

    private var imageSection: some View {
        TabView {
            ForEach(viewModel.post.images, id: \.originalURL) { imageInfo in
                AsyncImage(url: URL(string: imageInfo.originalURL)) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .frame(height: 300)
        .background(Color.black.opacity(0.3))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 24) {
            // いいねボタン
            Button(action: {
                Task {
                    await viewModel.toggleLike()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.isLiked ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundColor(viewModel.isLiked ? .red : .white)

                    Text("\(viewModel.post.likesCount)")
                        .font(.subheadline)
                        .foregroundColor(.white)
                }
            }

            // コメントボタン
            HStack(spacing: 4) {
                Image(systemName: "bubble.right")
                    .font(.title2)
                    .foregroundColor(.white)

                Text("\(viewModel.post.commentsCount)")
                    .font(.subheadline)
                    .foregroundColor(.white)
            }

            Spacer()

            // コレクション追加ボタン
            Button(action: {
                viewModel.showAddToCollectionSheet = true
            }) {
                Image(systemName: "bookmark")
                    .font(.title2)
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Post Info Section

    private var postInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // キャプション
            if let caption = viewModel.post.caption, !caption.isEmpty {
                Text(caption)
                    .font(.body)
                    .foregroundColor(.white)
            }

            // ハッシュタグ
            if let hashtags = viewModel.post.hashtags, !hashtags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(hashtags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(8)
                    }
                }
            }

            // 撮影日時
            if let capturedAt = viewModel.post.capturedAt {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(.gray)
                    Text(capturedAt, style: .date)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            // 空のタイプ
            if let skyType = viewModel.post.skyType {
                HStack {
                    Image(systemName: "cloud")
                        .foregroundColor(.gray)
                    Text(skyType.displayName)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Comments Section

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("コメント")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal)

            if viewModel.isLoadingComments {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if viewModel.comments.isEmpty {
                Text("まだコメントはありません")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.comments) { comment in
                        CommentRow(comment: comment) {
                            Task {
                                await viewModel.deleteComment(comment)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Comment Input Bar

    private var commentInputBar: some View {
        HStack(spacing: 12) {
            TextField("コメントを入力...", text: $viewModel.newCommentText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.2))
                .cornerRadius(20)

            Button(action: {
                Task {
                    await viewModel.submitComment()
                }
            }) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.white)
                    .padding(10)
                    .background(viewModel.newCommentText.isEmpty ? Color.gray : Color.blue)
                    .clipShape(Circle())
            }
            .disabled(viewModel.newCommentText.isEmpty)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Add to Collection Sheet

    private var addToCollectionSheet: some View {
        NavigationView {
            List {
                Section {
                    Button(action: {
                        showNewCollectionAlert = true
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.blue)
                            Text("新しいコレクションを作成")
                                .foregroundColor(.blue)
                        }
                    }
                }

                Section("既存のコレクション") {
                    if viewModel.userCollections.isEmpty {
                        Text("コレクションがありません")
                            .foregroundColor(.gray)
                    } else {
                        ForEach(viewModel.userCollections) { collection in
                            Button(action: {
                                Task {
                                    await viewModel.addToCollection(collection)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading) {
                                        Text(collection.name)
                                            .foregroundColor(.primary)
                                        Text("\(collection.postCount)件の投稿")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("コレクションに追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        viewModel.showAddToCollectionSheet = false
                    }
                }
            }
        }
    }
}

// MARK: - Comment Row

struct CommentRow: View {
    let comment: Comment
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // ユーザーアイコン
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "person.fill")
                        .foregroundColor(.gray)
                )

            VStack(alignment: .leading, spacing: 4) {
                // ユーザー名と日時
                HStack {
                    Text(comment.userName ?? "ユーザー")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)

                    Spacer()

                    Text(comment.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                // コメント内容
                Text(comment.content)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.9))
            }

            Spacer()
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("削除", systemImage: "trash")
            }
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)

        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                       y: bounds.minY + result.positions[index].y),
                          proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let viewSize = subview.sizeThatFits(.unspecified)

                if currentX + viewSize.width > maxWidth, currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }

                positions.append(CGPoint(x: currentX, y: currentY))

                currentX += viewSize.width + spacing
                lineHeight = max(lineHeight, viewSize.height)
            }

            size = CGSize(width: maxWidth, height: currentY + lineHeight)
        }
    }
}

// MARK: - SkyType Extension

extension SkyType {
    var displayName: String {
        switch self {
        case .clear:
            return "晴れ"
        case .cloudy:
            return "曇り"
        case .rainy:
            return "雨"
        case .sunset:
            return "夕焼け"
        case .sunrise:
            return "朝焼け"
        case .night:
            return "夜空"
        case .starry:
            return "星空"
        case .rainbow:
            return "虹"
        case .storm:
            return "嵐"
        case .snow:
            return "雪"
        }
    }
}

struct PostDetailView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            PostDetailView(
                post: Post(
                    id: "preview",
                    userId: "user1",
                    images: [],
                    caption: "美しい空の写真",
                    hashtags: ["空", "夕焼け", "自然"],
                    skyType: .sunset
                ),
                userId: "user1"
            )
        }
    }
}
