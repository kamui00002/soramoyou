//
//  DailyPickCardView.swift
//  Soramoyou
//
//  ⭐️ 今日のおすすめのそらもよう: ホーム上部に「今日の 1 枚」を出すカード。
//  おすすめが無い（まだ決まっていない・全候補が見せられない）ときは何も描かない。
//  タップすると、ホーム側が投稿の詳細を開く。
//  ※「私のおすすめの空」（publicProfiles.recommendedPostIds）とは別物。
//

import Kingfisher
import SwiftUI

struct DailyPickCardView: View {
    /// ホーム（HomeView）が所有する VM を共有する。
    /// 読み込み（load）は HomeView 側の onAppear / refreshable が担う。
    /// おすすめが無い時にこの View はサイズゼロになり、LazyVStack の中ではサイズゼロの View の
    /// task / onAppear の発火が保証されないため、このカード自身では読み込まない
    /// （OnThisDayCardView と同じ理由）。
    @ObservedObject var viewModel: DailyPickViewModel
    /// カードがタップされたときに呼ぶ（ホームが投稿の詳細を開く）
    let onTap: (Post) -> Void

    var body: some View {
        Group {
            if let item = viewModel.item {
                cardButton(item)
            }
        }
    }

    private func cardButton(_ item: DailyPickItem) -> some View {
        Button {
            onTap(item.post)
        } label: {
            HStack(spacing: DesignTokens.Spacing.md) {
                thumbnail(item.post)

                VStack(alignment: .leading, spacing: 4) {
                    Label("今日のおすすめのそらもよう", systemImage: "sparkles")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(DesignTokens.Colors.textPrimary)

                    if let caption = item.post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.caption)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    // 投稿者名。名前が取れないとき（ゲストはいつもこちら）は "ユーザー"
                    // （HomeView の投稿者欄と同じ扱い）
                    Text(item.authorName ?? "ユーザー")
                        .font(.caption2)
                        .foregroundColor(DesignTokens.Colors.textTertiary)
                        .lineLimit(1)
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
        .accessibilityLabel("今日のおすすめのそらもようを見る")
        .accessibilityIdentifier("DailyPickCard")
    }

    @ViewBuilder
    private func thumbnail(_ post: Post) -> some View {
        let first = post.images.first
        // 1 枚目のサムネイルを表示（公開は URL、公開以外は Storage のパスで読む。判定は PostImageSource）
        if let first, let image = KFImage.post(PostImageSource.resolve(first, prefersThumbnail: true)) {
            image
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
