//
//  OnThisDayCardView.swift
//  Soramoyou
//
//  On This Day（1年前の空）: ホーム上部に「N年前の今日の空」を表示するカード。
//  メモリーが無い時は何も表示しない（EmptyView）。タップで自己完結の簡易詳細を開く。
//

import SwiftUI
import Kingfisher

struct OnThisDayCardView: View {
    let userId: String?

    @StateObject private var viewModel = OnThisDayViewModel()
    @State private var selectedMemory: OnThisDayMemory?

    var body: some View {
        Group {
            if let memory = viewModel.memories.first {
                cardButton(memory)
            }
        }
        .task(id: userId) {
            guard let userId else { return }
            await viewModel.load(userId: userId)
        }
        .sheet(item: $selectedMemory) { memory in
            OnThisDayMemoryDetailView(memory: memory)
        }
    }

    private func cardButton(_ memory: OnThisDayMemory) -> some View {
        Button {
            selectedMemory = memory
        } label: {
            HStack(spacing: DesignTokens.Spacing.md) {
                thumbnail(memory.post)

                VStack(alignment: .leading, spacing: 4) {
                    Label("\(memory.yearsAgo)年前の今日の空", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(DesignTokens.Colors.textPrimary)

                    if let caption = memory.post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.caption)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    if viewModel.memories.count > 1 {
                        Text("ほか \(viewModel.memories.count - 1) 件のメモリー")
                            .font(.caption2)
                            .foregroundColor(DesignTokens.Colors.textTertiary)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(DesignTokens.Colors.textTertiary)
            }
            .padding(DesignTokens.Spacing.md)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(memory.yearsAgo)年前の今日の空を見る")
    }

    @ViewBuilder
    private func thumbnail(_ post: Post) -> some View {
        let first = post.images.first
        if let urlString = first?.thumbnail ?? first?.url, let url = URL(string: urlString) {
            KFImage(url)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
        } else {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                .fill(Color.white.opacity(0.12))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "photo").foregroundColor(DesignTokens.Colors.textTertiary))
        }
    }
}

// MARK: - 簡易メモリー詳細（自己完結・LikeManager 非依存）

struct OnThisDayMemoryDetailView: View {
    let memory: OnThisDayMemory
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.md) {
                    ForEach(Array(memory.post.images.enumerated()), id: \.offset) { _, info in
                        if let url = URL(string: info.url) {
                            KFImage(url)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
                        }
                    }

                    if let caption = memory.post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(DesignTokens.Spacing.screenMargin)
            }
            .navigationTitle("\(memory.yearsAgo)年前の今日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
