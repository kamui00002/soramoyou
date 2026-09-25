//
//  RankingBadge.swift ⭐️
//  Soramoyou
//
//  ギャラリーの週間 / 月間ランキングで、写真の上に重ねる順位バッジ。
//  - 左上: 順位（1〜3 位は金・銀・銅）
//  - 右下: 期間中に付いたいいね数（全期間の累計 likesCount ではない）
//

import SwiftUI

struct RankingBadge: View {
    let entry: RankedPost

    var body: some View {
        ZStack {
            // 左上: 順位
            rankLabel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(4)

            // 右下: 期間中のいいね数
            likeCountLabel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(4)
        }
        // 写真のタップ（詳細を開く）を邪魔しない
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.rank)位 期間中のいいね\(entry.likeCount)件")
    }

    // MARK: - Subviews

    /// 順位の丸バッジ
    private var rankLabel: some View {
        Text("\(entry.rank)")
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .frame(minWidth: 24, minHeight: 24)
            .padding(.horizontal, entry.rank >= 10 ? 4 : 0)
            .background(
                Capsule()
                    .fill(rankColor)
                    .overlay(Capsule().stroke(Color.white.opacity(0.8), lineWidth: 1.5))
            )
            .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
    }

    /// 期間中のいいね数
    private var likeCountLabel: some View {
        HStack(spacing: 2) {
            Image(systemName: "heart.fill")
                .font(.system(size: 9, weight: .bold))
            Text("\(entry.likeCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    /// 1〜3 位は金・銀・銅、それ以外は半透明の黒
    private var rankColor: Color {
        switch entry.rank {
        case 1: return Color(red: 0.95, green: 0.75, blue: 0.20)
        case 2: return Color(red: 0.66, green: 0.70, blue: 0.76)
        case 3: return Color(red: 0.80, green: 0.52, blue: 0.30)
        default: return Color.black.opacity(0.5)
        }
    }
}
