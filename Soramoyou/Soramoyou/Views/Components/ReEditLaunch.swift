// ⭐️ ReEditLaunch.swift
// 投稿の「再編集」エディタ起動ペイロード（共通）
//
//  Created on 2026-06-09.
//
//  再編集は元画像(originalImages)を order 順に DL し終えてから EditView を全画面提示する。
//  fullScreenCover(item:) で「画像が確実に揃ってから」View を構築するための Identifiable な箱。
//  ギャラリー詳細(GalleryDetailView)と、ホーム/プロフィール/検索が共有する投稿詳細(PostDetailView)
//  の双方から使う（同じ起動ロジックを 1 つの型で揃え、二重定義を避ける）。
//

import SwiftUI

/// 再編集エディタ起動ペイロード。元画像のダウンロード完了後にセットして提示する。
struct ReEditLaunchPayload: Identifiable {
    let id = UUID()
    /// 上書き更新対象の元投稿（userId / attachedRecipe / 編集 seed の供給元）
    let post: Post
    /// 元画像（originalImages を order 順に DL したもの）
    let images: [UIImage]

    /// この投稿から再編集 seed（PostEditingContext）を生成する。
    var editingContext: PostEditingContext { PostEditingContext(post: post) }
}
