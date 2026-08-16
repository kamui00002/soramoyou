//
//  HashtagChipRow.swift
//  Soramoyou
//
//  ハッシュタグチップの共通コンポーネント ⭐️
//
//  これまで「# 付きタグの Text」が 4 箇所（PostCard / PostDetailView /
//  GalleryDetailView / PostInfoView）にコピペで散らばっており、タップ可能にする
//  改修のたびに 4 箇所を触る必要があった。ここに集約する。
//
//  ⚠️ 各箇所は元々「見た目が違う」ことに注意。1 つの見た目に統一すると既存画面の
//     デザインが変わってしまうため、`style` / `layout` で従来の見た目を再現する。
//

import SwiftUI

// MARK: - Chip Style

/// チップの見た目バリエーション。呼び出し元の既存デザインをそのまま再現するための区分。
enum HashtagChipStyle {
    /// フィードカード（PostCard）用。小さめ・アクセント色・カプセル型。
    case compact
    /// 詳細画面（PostDetailView / GalleryDetailView）用。暗い背景に載る前提。
    case detail
    /// 投稿作成プレビュー（PostInfoView）用。白ベースの半透明。
    case editor
}

// MARK: - Chip Layout

/// チップの並べ方。
enum HashtagChipLayout {
    /// 横スクロール（1 行に収める）
    case scroll
    /// 折り返し（FlowLayout。高さが伸びる）
    case flow
}

// MARK: - Hashtag Chip Row

/// ハッシュタグを「# 付きのチップ」として並べる共通ビュー。
///
/// `onTap` を渡すとタップ可能（Button）になり、渡さない場合は純粋な表示のみになる。
/// 投稿作成中のプレビューのように「遷移先が無い / 遷移させたくない」場面では
/// `onTap` を省略して見た目だけ揃える。
struct HashtagChipRow: View {
    /// 表示するハッシュタグ（"#" を含まない生の単語）。
    /// ⚠️ ここで正規化（小文字化・トリム）はしない。保存値と表示値を一致させる。
    let hashtags: [String]
    /// 見た目バリエーション
    var style: HashtagChipStyle = .detail
    /// 並べ方
    var layout: HashtagChipLayout = .scroll
    /// タップ時のハンドラ。nil ならタップ不可（表示のみ）。
    var onTap: ((String) -> Void)?

    var body: some View {
        switch layout {
        case .scroll:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    chips
                }
            }
        case .flow:
            FlowLayout(spacing: spacing) {
                chips
            }
        }
    }

    // MARK: - Chips

    /// チップ本体の並び。タップ可否で Button か素の Text かを切り替える。
    @ViewBuilder
    private var chips: some View {
        ForEach(hashtags, id: \.self) { hashtag in
            if let onTap {
                Button {
                    // 触覚フィードバック（他のタップ導線と体験を揃える）
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    onTap(hashtag)
                } label: {
                    chipLabel(for: hashtag)
                }
                // カード内に置かれるため、既定のボタン装飾を付けない
                .buttonStyle(.plain)
                .accessibilityLabel("ハッシュタグ \(hashtag) の投稿を見る")
                .accessibilityAddTraits(.isButton)
            } else {
                chipLabel(for: hashtag)
            }
        }
    }

    /// チップ 1 個の見た目。`style` ごとに従来のデザインを忠実に再現する。
    @ViewBuilder
    private func chipLabel(for hashtag: String) -> some View {
        switch style {
        case .compact:
            // PostCard 由来: Dynamic Type 対応の .caption + アクセント色のカプセル
            Text("#\(hashtag)")
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundColor(DesignTokens.Colors.selectionAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DesignTokens.Colors.selectionAccent.opacity(0.12))
                )

        case .detail:
            // PostDetailView / GalleryDetailView 由来: 暗い背景に載る白半透明
            Text("#\(hashtag)")
                .font(.body)
                .foregroundColor(DesignTokens.Colors.skyBlue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.1))
                .cornerRadius(12)

        case .editor:
            // PostInfoView 由来: 投稿作成中のプレビュー用
            Text("#\(hashtag)")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.2))
                .foregroundColor(.white)
                .cornerRadius(12)
        }
    }

    /// チップ同士の間隔（従来値を踏襲）
    private var spacing: CGFloat {
        switch style {
        case .compact: DesignTokens.Spacing.sm
        case .detail, .editor: 8
        }
    }
}
