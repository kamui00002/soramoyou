//
//  CommentSection.swift ☁️⭐️
//  Soramoyou
//
//  コメント一覧と入力欄を表示するコンポーネント
//  モダンなグラスモーフィズムデザインでアプリ全体のトーンに統一
//

import SwiftUI

/// コメントセクション（一覧 + 入力欄）
struct CommentSection: View {
    let postId: String
    let postUserId: String
    @ObservedObject var commentViewModel: CommentViewModel
    @Binding var commentText: String
    @State private var sendScale: CGFloat = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            // セクションヘッダー
            sectionHeader

            // コメント入力欄
            commentInputView

            // コメント一覧
            if commentViewModel.isLoading {
                loadingView
            } else if commentViewModel.comments.isEmpty {
                emptyStateView
            } else {
                commentListView
            }
        }
    }

    // MARK: - Section Header

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [DesignTokens.Colors.skyBlue, DesignTokens.Colors.selectionAccent],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            Text("コメント")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textPrimary)

            if !commentViewModel.comments.isEmpty {
                Text("\(commentViewModel.comments.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(DesignTokens.Colors.skyBlue.opacity(0.8))
                    )
            }

            Spacer()
        }
    }

    // MARK: - Comment Input

    private var commentInputView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                // テキスト入力
                TextField("空の感想を書こう...", text: $commentText, axis: .vertical)
                    .font(.system(size: 15, design: .rounded))
                    .lineLimit(1...4)
                    .disabled(commentViewModel.isSending)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [
                                                DesignTokens.Colors.skyBlue.opacity(commentText.isEmpty ? 0.2 : 0.5),
                                                DesignTokens.Colors.selectionAccent.opacity(commentText.isEmpty ? 0.1 : 0.3)
                                            ],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ),
                                        lineWidth: 1.5
                                    )
                            )
                    )

                // 送信ボタン
                Button {
                    sendComment()
                } label: {
                    Group {
                        if commentViewModel.isSending {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .rotationEffect(.degrees(-45))
                        }
                    }
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(
                                commentText.isEmpty
                                ? LinearGradient(colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                : LinearGradient(colors: [DesignTokens.Colors.skyBlue, DesignTokens.Colors.selectionAccent], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                    )
                    .scaleEffect(sendScale)
                    .shadow(color: commentText.isEmpty ? .clear : DesignTokens.Colors.skyBlue.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .disabled(commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || commentViewModel.isSending)
            }

            // 文字数プログレスバー
            if !commentText.isEmpty {
                characterCountBar
            }
        }
    }

    // MARK: - Character Count Bar

    private var characterCountBar: some View {
        HStack(spacing: 6) {
            // プログレスバー
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.15))
                        .frame(height: 3)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(characterCountColor)
                        .frame(width: min(geometry.size.width * CGFloat(commentText.count) / 500.0, geometry.size.width), height: 3)
                        .animation(.easeInOut(duration: 0.2), value: commentText.count)
                }
            }
            .frame(height: 3)

            Text("\(commentText.count)/500")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(characterCountColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
    }

    private var characterCountColor: Color {
        if commentText.count > 500 {
            return .red
        } else if commentText.count > 400 {
            return .orange
        }
        return DesignTokens.Colors.textTertiary
    }

    // MARK: - Loading View

    private var loadingView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                ProgressView()
                    .tint(DesignTokens.Colors.skyBlue)
                Text("コメントを読み込み中...")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(DesignTokens.Colors.textTertiary)
            }
            Spacer()
        }
        .padding(.vertical, 16)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(
                    LinearGradient(
                        colors: [DesignTokens.Colors.skyBlue.opacity(0.5), DesignTokens.Colors.selectionAccent.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("まだコメントはありません")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textTertiary)

            Text("最初のコメントを投稿しよう")
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textTertiary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Comment List

    private var commentListView: some View {
        VStack(spacing: 0) {
            ForEach(Array(commentViewModel.comments.enumerated()), id: \.element.id) { index, comment in
                CommentRow(
                    comment: comment,
                    canDelete: commentViewModel.isOwnComment(comment)
                        || commentViewModel.isPostOwner(postUserId: postUserId),
                    onDelete: {
                        Task {
                            await commentViewModel.deleteComment(comment)
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))

                if index < commentViewModel.comments.count - 1 {
                    // グラデーション区切り線
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignTokens.Colors.skyBlue.opacity(0.1),
                                    DesignTokens.Colors.selectionAccent.opacity(0.15),
                                    DesignTokens.Colors.skyBlue.opacity(0.1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                }
            }

            // さらに読み込む
            if commentViewModel.hasMoreComments {
                loadMoreButton
            }

            // エラー表示
            if let error = commentViewModel.errorMessage {
                errorView(message: error)
            }
        }
    }

    // MARK: - Load More Button

    private var loadMoreButton: some View {
        Button {
            Task { await commentViewModel.loadMoreComments(postId: postId) }
        } label: {
            HStack(spacing: 6) {
                if commentViewModel.isLoadingMore {
                    ProgressView()
                        .tint(DesignTokens.Colors.skyBlue)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 14, weight: .medium))
                    Text("さらに読み込む")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                }
            }
            .foregroundColor(DesignTokens.Colors.skyBlue)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(DesignTokens.Colors.skyBlue.opacity(0.08))
            )
        }
        .disabled(commentViewModel.isLoadingMore)
        .padding(.top, 8)
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12, design: .rounded))
        }
        .foregroundColor(.red.opacity(0.8))
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func sendComment() {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // 送信アニメーション
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
            sendScale = 0.8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                sendScale = 1.0
            }
        }

        Task {
            let success = await commentViewModel.addComment(postId: postId, content: text)
            if success {
                withAnimation(DesignTokens.Animation.smoothSpring) {
                    commentText = ""
                }
            }
        }
    }
}

// MARK: - Comment Row

/// 個別コメント表示 — 吹き出し風デザイン
struct CommentRow: View {
    let comment: Comment
    let canDelete: Bool
    let onDelete: () -> Void
    @State private var showDeleteConfirm = false

    /// ユーザーIDからパステルカラーを生成
    private var avatarColor: Color {
        let hash = comment.userId.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.3, brightness: 0.9)
    }

    /// ユーザーIDから表示名の頭文字を生成
    private var avatarInitial: String {
        String(comment.userId.prefix(2)).uppercased()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // アバター
            Circle()
                .fill(avatarColor)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(avatarInitial)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                )

            // コメント本文（吹き出し風）
            VStack(alignment: .leading, spacing: 4) {
                Text(comment.content)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(UIColor.systemGray6))
                    )

                // 日時
                Text(comment.createdAt, style: .relative)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(DesignTokens.Colors.textTertiary)
                    .padding(.leading, 12)
            }

            Spacer(minLength: 0)

            // 削除ボタン
            if canDelete {
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundColor(DesignTokens.Colors.textTertiary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .confirmationDialog("コメントを削除しますか？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("削除", role: .destructive) {
                        onDelete()
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}
