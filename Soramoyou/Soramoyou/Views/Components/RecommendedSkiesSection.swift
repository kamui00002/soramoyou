//
//  RecommendedSkiesSection.swift ⭐️
//  Soramoyou
//
//  プロフィールに飾る「私のおすすめの空」（最大 3 枚）の欄。
//  - OwnRecommendedSkiesSection: 自分のプロフィール用（外す・並べ替え・表示できない空の整理）
//  - PublicRecommendedSkiesSection: 他の人のプロフィール用（見るだけ）
//
//  ⚠️ 自分用の欄は、読み込み（.task）と一覧の変化への追従（.onChange）を**この部品の中**に持つ。
//     ProfileView の body は修飾子チェーンが長く、Xcode 27 で型チェックが終わらなくなった前例
//     （#123 / GalleryDetailView）があるため、呼び出し側のチェーンを伸ばさない。
//

import Kingfisher
import SwiftUI

// MARK: - 自分のプロフィール用

struct OwnRecommendedSkiesSection: View {
    /// プロフィールの持ち主（＝自分）
    let ownerId: String
    /// 引っ張って更新のたびに変わる値。変わったらキャッシュを捨てて取り直す
    let refreshToken: Int
    /// タイルをタップしたとき（投稿詳細を開く）
    let onSelect: (Post) -> Void

    @ObservedObject private var manager = RecommendationManager.shared
    @StateObject private var viewModel = RecommendedSkiesViewModel()
    /// 外す・並べ替えの編集中か
    @State private var isEditing = false
    /// 保存失敗のアラート表示
    @State private var showingSaveError = false
    /// 最後に取り直しを済ませた refreshToken（値が変わったときだけキャッシュを捨てる）
    ///
    /// ⚠️ `force: refreshToken > 0` にすると、1 回でも引っ張って更新した後は
    ///    プロフィールを開くたびに全件を取り直してしまう（.task は表示のたびに走る）。
    @State private var handledRefreshToken = 0

    init(ownerId: String, refreshToken: Int, onSelect: @escaping (Post) -> Void) {
        self.ownerId = ownerId
        self.refreshToken = refreshToken
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header

            if manager.recommendedPostIds.isEmpty {
                emptyHint
            } else if viewModel.isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                RecommendedSkiesGrid(items: viewModel.items) { item in
                    tile(for: item)
                }
            }

            if !viewModel.unavailablePostIds.isEmpty {
                cleanupNotice
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                .fill(.ultraThinMaterial)
        )
        .task(id: refreshToken) {
            // プロフィールを開いた／引っ張って更新したときは、別端末での変更も拾うため一覧は読み直す
            await manager.load(force: true)
            // 投稿の中身まで取り直すのは、引っ張って更新したときだけ
            let isRefresh = refreshToken != handledRefreshToken
            handledRefreshToken = refreshToken
            await viewModel.load(postIds: manager.recommendedPostIds, ownerId: ownerId, force: isRefresh)
        }
        .onChange(of: manager.recommendedPostIds) { postIds in
            // 投稿詳細から追加した・ここで外した／並べ替えたときに追従する（解決済みの投稿は取り直さない）
            Task { await viewModel.load(postIds: postIds, ownerId: ownerId) }
            if postIds.isEmpty {
                isEditing = false
            }
        }
        .alert("保存できませんでした", isPresented: $showingSaveError) {
            Button("OK") {}
        } message: {
            Text("通信環境を確認して、もう一度お試しください。")
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Label("私のおすすめの空", systemImage: "star.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DesignTokens.Colors.textPrimary)

            Text("\(manager.recommendedPostIds.count)/\(RecommendedSkies.maxCount)")
                .font(.caption)
                .foregroundColor(DesignTokens.Colors.textTertiary)

            Spacer()

            if !manager.recommendedPostIds.isEmpty {
                Button(isEditing ? "完了" : "編集") {
                    isEditing.toggle()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DesignTokens.Colors.textPrimary)
                .disabled(manager.isUpdating)
            }
        }
    }

    /// まだ 1 枚も選んでいないときの案内
    private var emptyHint: some View {
        Text("気に入った空を\(RecommendedSkies.maxCount)枚まで飾れます。投稿を開いて「…」メニューの「おすすめの空に追加」から選んでください。自分や他の人の公開投稿から選べて、あなたのプロフィールを見た人にも表示されます。")
            .font(.caption)
            .foregroundColor(DesignTokens.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 表示できなくなった空の整理を促す
    private var cleanupNotice: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("表示できない空が\(viewModel.unavailablePostIds.count)枚あります（削除・非公開になった投稿）")
                .font(.caption)
                .foregroundColor(DesignTokens.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("整理する") {
                Task {
                    let outcome = await manager.remove(
                        postIds: Set(viewModel.unavailablePostIds),
                        source: "profile_cleanup"
                    )
                    showingSaveError = outcome == .failed
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(DesignTokens.Colors.textPrimary)
            .disabled(manager.isUpdating)
        }
    }

    /// 1 枚ぶんのタイル（編集中は外す・前後へ動かすボタンを重ねる）
    private func tile(for item: RecommendedSkiesViewModel.Item) -> some View {
        Button {
            if !isEditing {
                onSelect(item.post)
            }
        } label: {
            RecommendedSkyTile(item: item)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if isEditing {
                Button {
                    Task {
                        let outcome = await manager.remove(postIds: [item.id], source: "profile")
                        showingSaveError = outcome == .failed
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.6))
                }
                .padding(4)
                .accessibilityLabel("おすすめの空から外す")
            }
        }
        .overlay(alignment: .bottom) {
            if isEditing {
                moveButtons(for: item.id)
            }
        }
    }

    /// 前へ / 後ろへ動かすボタン
    private func moveButtons(for postId: String) -> some View {
        let index = manager.recommendedPostIds.firstIndex(of: postId)
        let isFirst = index == 0
        let isLast = index == manager.recommendedPostIds.count - 1
        return HStack {
            Button {
                Task { await manager.move(postId: postId, by: -1) }
            } label: {
                Image(systemName: "chevron.left.circle.fill")
            }
            .disabled(isFirst || manager.isUpdating)
            .opacity(isFirst ? 0 : 1)
            .accessibilityLabel("前へ移動")

            Spacer()

            Button {
                Task { await manager.move(postId: postId, by: 1) }
            } label: {
                Image(systemName: "chevron.right.circle.fill")
            }
            .disabled(isLast || manager.isUpdating)
            .opacity(isLast ? 0 : 1)
            .accessibilityLabel("後ろへ移動")
        }
        .font(.system(size: 22))
        .symbolRenderingMode(.palette)
        .foregroundStyle(.white, Color.black.opacity(0.6))
        .padding(4)
    }
}

// MARK: - 他の人のプロフィール用

/// 他の人のプロフィールに出す「おすすめの空」（見るだけ）
///
/// 読み込みは呼び出し側（UserProfileView の .task）で `viewModel.load` を呼ぶ。
/// 1 枚も出せないときは欄ごと出さない（呼び出し側で `items.isEmpty` を見て出し分ける）。
struct PublicRecommendedSkiesSection: View {
    @ObservedObject var viewModel: RecommendedSkiesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Label("おすすめの空", systemImage: "star.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)

            RecommendedSkiesGrid(items: viewModel.items) { item in
                RecommendedSkyTile(item: item)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial.opacity(0.4))
        )
    }
}

// MARK: - 共通部品

/// 3 列固定のグリッド（1〜2 枚でもタイルが横に伸びないよう列数を固定する）
private struct RecommendedSkiesGrid<Tile: View>: View {
    let items: [RecommendedSkiesViewModel.Item]
    @ViewBuilder let tile: (RecommendedSkiesViewModel.Item) -> Tile

    /// ⚠️ 計算プロパティにしている。初期値つきの private な stored property があると
    ///    自動のメンバーワイズ init が private 扱いになり、同じファイルの別の型から呼べなくなるため。
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.sm),
            count: RecommendedSkies.maxCount
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.sm) {
            ForEach(items) { item in
                tile(item)
            }
        }
    }
}

/// おすすめの空の 1 枚（正方形のサムネイル＋他の人の投稿なら投稿者名）
struct RecommendedSkyTile: View {
    let item: RecommendedSkiesViewModel.Item

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let firstImage = item.post.images.first,
                   let url = URL(string: firstImage.thumbnail ?? firstImage.url) {
                    KFImage(url)
                        .placeholder {
                            Rectangle().fill(Color.gray.opacity(0.3))
                        }
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(Image(systemName: "photo").foregroundColor(.gray))
                }
            }
            .overlay(alignment: .bottomLeading) {
                // 他の人の投稿には投稿者名を添える（おすすめした空のクレジット表示）
                if let authorName = item.authorName {
                    Text(authorName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.authorName.map { "\($0)さんの空" } ?? "おすすめの空")
    }
}
