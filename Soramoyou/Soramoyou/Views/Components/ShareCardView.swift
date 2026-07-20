//
//  ShareCardView.swift
//  Soramoyou
//
//  空カード共有パック ⭐️: 投稿写真を外部SNS（Instagram/X）に「そのまま出せる完成品」として
//  書き出すための正方形（1080×1080）共有カード。
//
//  ImageRenderer（iOS16+）でラスタライズする前提の独立した View として切り出し、
//  プレビュー（画面内スケール表示・ShareCardExportView側）と実際の書き出しの双方から
//  同じ見た目を共有する。
//
//  デザイン方針（docs/ui-spec.md 準拠）: 写真が主役・余白を活かす。
//  下部に撮影日・場所を小さく上品に、右下に控えめな「そらもよう」透かし（既定ON・8割白）。
//
//  気分フレーム（frameId）付き投稿は、投稿保存時点で PostViewModel.composeMoodFrameIfNeeded が
//  既に写真へフレームを焼き込んでいるため、このビューは写真をそのまま aspect-fill するだけで
//  フレーム込みの見た目を自然に尊重できる（特別な分岐は不要）。
//

import SwiftUI

struct ShareCardView: View {
    /// カードの一辺（pt）。renderedImage() で scale=1.0 固定して書き出すことで、
    /// デバイスの画面スケールに関わらず出力ピクセルサイズもこの値と一致させる。
    static let cardSize: CGFloat = 1080

    let post: Post
    let image: UIImage
    let showWatermark: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()

    /// 撮影日優先（無ければ投稿日）
    private var dateText: String {
        Self.dateFormatter.string(from: post.capturedAt ?? post.createdAt)
    }

    /// 「都道府県 市区町村」表記（既存の投稿詳細表示と同じ規約）
    private var locationText: String? {
        guard let location = post.location else { return nil }
        if let prefecture = location.prefecture, let city = location.city {
            return "\(prefecture) \(city)"
        }
        return location.city ?? location.prefecture
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.cardSize, height: Self.cardSize)
                .clipShape(Rectangle())

            // 下部を読みやすくするためのグラデーション地
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.cardSize * 0.30)

            bottomInfoRow
                .padding(.horizontal, 48)
                .padding(.bottom, 40)
        }
        .frame(width: Self.cardSize, height: Self.cardSize)
        .clipShape(Rectangle())
    }

    // MARK: - Bottom Info Row

    private var bottomInfoRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(dateText)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                if let locationText {
                    Text(locationText)
                        .font(.system(size: 22, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if showWatermark {
                // 主張しすぎない透かし（8割白・小さめ）
                Text("そらもよう")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }
}

// MARK: - Rendering

extension ShareCardView {
    /// カードを実寸（cardSize × cardSize px）でラスタライズする。
    /// - Note: `ImageRenderer` は @MainActor 前提。`scale = 1.0` に固定することで
    ///   デバイスの画面スケール(2x/3x)に関わらず出力ピクセルサイズを `cardSize` と一致させる。
    @MainActor
    static func renderedImage(post: Post, image: UIImage, showWatermark: Bool) -> UIImage? {
        let view = ShareCardView(post: post, image: image, showWatermark: showWatermark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.0
        return renderer.uiImage
    }
}

#Preview {
    let previewSide: CGFloat = 320
    return ShareCardView(
        post: Post(
            id: "preview",
            userId: "u",
            images: [],
            location: Location(latitude: 35.66, longitude: 139.70, city: "渋谷区", prefecture: "東京都"),
            capturedAt: Date(),
            createdAt: Date()
        ),
        image: UIImage(systemName: "photo.fill") ?? UIImage(),
        showWatermark: true
    )
    .frame(width: ShareCardView.cardSize, height: ShareCardView.cardSize)
    .scaleEffect(previewSide / ShareCardView.cardSize)
    .frame(width: previewSide, height: previewSide)
}
