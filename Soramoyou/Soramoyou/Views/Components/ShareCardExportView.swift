//
//  ShareCardExportView.swift
//  Soramoyou
//
//  空カード共有パック ⭐️: 投稿写真を正方形の共有カードとして書き出し、
//  外部SNS（Instagram/X）へ共有するシート。
//
//  導線: カードプレビュー → 透かしトグル（既定ON） → おすすめハッシュタグ → 共有。
//  投稿詳細（PostDetailView）の共有メニューから、画像ダウンロード完了後に提示される。
//

import SwiftUI

struct ShareCardExportView: View {
    let post: Post
    let sourceImage: UIImage

    @Environment(\.dismiss) private var dismiss
    /// ロゴ（透かし）を入れるか。既定ON（毎回リセットされ、永続化はしない仕様）。
    @State private var includeWatermark = true
    /// 位置情報（撮影地）を入れるか。既定値はプライバシー安全側:
    /// 投稿の visibility が public のときだけON、followers/private はOFF。
    @State private var showLocation: Bool
    @State private var renderedImage: UIImage?
    @State private var didCopyHashtags = false

    init(post: Post, sourceImage: UIImage) {
        self.post = post
        self.sourceImage = sourceImage
        _showLocation = State(initialValue: post.visibility == .public)
    }

    private var suggestedHashtags: [String] {
        ShareHashtagSuggester.suggest(skyType: post.skyType, timeOfDay: post.timeOfDay, mood: post.mood)
    }

    private var hashtagCopyText: String {
        suggestedHashtags.map { "#\($0)" }.joined(separator: " ")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    cardPreview
                    watermarkToggle
                    if post.location != nil {
                        locationToggle
                    }
                    hashtagSection
                    shareButton
                }
                .padding()
            }
            .background(DesignTokens.Colors.detailBackground)
            .navigationTitle("共有カードを書き出す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignTokens.Colors.detailBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { updateRenderedImage() }
        .onChange(of: includeWatermark) { _ in updateRenderedImage() }
        .onChange(of: showLocation) { _ in updateRenderedImage() }
    }

    // MARK: - Preview

    private var cardPreview: some View {
        let side: CGFloat = 300
        return ShareCardView(post: post, image: sourceImage, showWatermark: includeWatermark, showLocation: showLocation)
            .frame(width: ShareCardView.cardSize, height: ShareCardView.cardSize)
            .scaleEffect(side / ShareCardView.cardSize)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
    }

    // MARK: - Watermark Toggle

    private var watermarkToggle: some View {
        Toggle(isOn: $includeWatermark) {
            Label("ロゴを入れる", systemImage: "seal")
                .foregroundColor(.white)
        }
        .tint(DesignTokens.Colors.skyBlue)
        .padding()
        .background(DesignTokens.Colors.detailCardBackground)
        .cornerRadius(12)
    }

    // MARK: - Location Toggle

    private var locationToggle: some View {
        Toggle(isOn: $showLocation) {
            Label("場所を表示", systemImage: "mappin.and.ellipse")
                .foregroundColor(.white)
        }
        .tint(DesignTokens.Colors.skyBlue)
        .padding()
        .background(DesignTokens.Colors.detailCardBackground)
        .cornerRadius(12)
    }

    // MARK: - Hashtags

    private var hashtagSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("おすすめハッシュタグ")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestedHashtags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.subheadline)
                            .foregroundColor(DesignTokens.Colors.skyBlue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(12)
                    }
                }
            }

            Button {
                copyHashtags()
            } label: {
                Label(
                    didCopyHashtags ? "コピーしました" : "タグをコピー",
                    systemImage: didCopyHashtags ? "checkmark" : "doc.on.doc"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.1))
                .cornerRadius(10)
            }
        }
        .padding()
        .background(DesignTokens.Colors.detailCardBackground)
        .cornerRadius(12)
    }

    private func copyHashtags() {
        UIPasteboard.general.string = hashtagCopyText
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        didCopyHashtags = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            didCopyHashtags = false
        }
    }

    // MARK: - Share

    @ViewBuilder
    private var shareButton: some View {
        if let renderedImage {
            ShareLink(
                item: Image(uiImage: renderedImage),
                preview: SharePreview("そらもよう - 空の写真", image: Image(uiImage: renderedImage))
            ) {
                Label("共有する", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: DesignTokens.Colors.accentGradient,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    )
            }
            // ShareLink自体には完了ハンドラがないため、タップ時点（実際の共有アクション発火と同時）で
            // 計装する。cf. UseRecipeButton の "recipe_share_tapped"（同様にタップ時点で記録する規約）。
            .simultaneousGesture(TapGesture().onEnded {
                LoggingService.shared.logEvent(
                    "share_card_exported",
                    parameters: ["watermark_on": includeWatermark]
                )
            })
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    // MARK: - Helpers

    @MainActor
    private func updateRenderedImage() {
        renderedImage = ShareCardView.renderedImage(
            post: post, image: sourceImage, showWatermark: includeWatermark, showLocation: showLocation
        )
    }
}
