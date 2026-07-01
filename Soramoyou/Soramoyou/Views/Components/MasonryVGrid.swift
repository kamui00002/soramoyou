//
//  MasonryVGrid.swift ⭐️
//  Soramoyou
//
//  写真の縦横比をそのまま活かす「モザイク（Pinterest 風）」レイアウト。
//  SwiftUI 標準に masonry が無いため、各アイテムの相対高さを見て
//  「一番低いカラムへ順に積む」貪欲法で列を割り振る。
//
//  用途はギャラリーのサムネイル一覧（1ページ 30 件程度）。件数が大きくない前提で、
//  分配計算は body で都度行うシンプルな実装にしている。
//

import SwiftUI

/// 写真の縦横比を保つモザイク（masonry）グリッド。
///
/// - `aspectRatio` は「幅 ÷ 高さ」を返す。値が小さいほど縦長＝背が高いセルになる。
/// - `onItemAppear` は各セルの表示時に呼ばれる（ページネーションのトリガに使う）。
struct MasonryVGrid<Item: Identifiable, Content: View>: View {
    /// 表示アイテム（表示順）
    let items: [Item]
    /// カラム数
    let columns: Int
    /// セル間の余白
    let spacing: CGFloat
    /// 幅÷高さ（縦横比）を返すクロージャ
    let aspectRatio: (Item) -> CGFloat
    /// セルの中身
    let content: (Item) -> Content
    /// セル表示時のコールバック（任意）
    var onItemAppear: ((Item) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(distributedColumns.enumerated()), id: \.offset) { _, columnItems in
                LazyVStack(spacing: spacing) {
                    ForEach(columnItems) { item in
                        content(item)
                            .onAppear { onItemAppear?(item) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    /// アイテムを各カラムへ分配する（一番低いカラムへ順に積む貪欲法）。
    private var distributedColumns: [[Item]] {
        let columnCount = max(1, columns)
        var buckets: [[Item]] = Array(repeating: [], count: columnCount)
        // 各カラムの相対的な積み上げ高さ（1/縦横比 の合計）
        var heights = Array(repeating: CGFloat(0), count: columnCount)

        for item in items {
            // 一番低いカラムを選ぶ
            var target = 0
            for index in 1..<columnCount where heights[index] < heights[target] {
                target = index
            }
            buckets[target].append(item)
            // 縦横比から相対高さを加算（幅を1とみなすと高さ = 1/(w/h)）
            let ratio = aspectRatio(item)
            let relativeHeight = ratio > 0 ? 1 / ratio : 1
            heights[target] += relativeHeight + 0.05 // 余白ぶんの微小加算で偏りを緩和
        }

        return buckets
    }
}
