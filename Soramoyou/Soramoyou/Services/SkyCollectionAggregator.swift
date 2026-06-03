//
//  SkyCollectionAggregator.swift
//  Soramoyou
//
//  空コレクション図鑑（柱2）の集計ロジック（純関数）。
//  Firestore / UI 非依存なので単体テストで網羅できる。
//

import Foundation

/// 投稿メタから図鑑の集計結果（`CollectionState`）を作る純粋ロジック。
enum SkyCollectionAggregator {

    /// 軽量メタの配列から集計する。
    /// - 各軸は nil をスキップ（「不明」は収集対象に数えない）。
    static func aggregate(_ metas: [PostCollectionMeta]) -> CollectionState {
        var state = CollectionState()
        state.totalPosts = metas.count

        for meta in metas {
            if let skyType = meta.skyType {
                state.skyTypes.insert(skyType)
            }
            if let timeOfDay = meta.timeOfDay {
                state.timeOfDays.insert(timeOfDay)
            }
            if let season = meta.season {
                state.seasons.insert(season)
            }
            if let prefecture = meta.prefecture {
                state.prefectures.insert(prefecture)
            }
            // マトリクスセルは空タイプと時間帯が両方ある時だけ
            if let skyType = meta.skyType, let timeOfDay = meta.timeOfDay {
                state.skyTimeCells.insert(SkyTimeCell(skyType: skyType, timeOfDay: timeOfDay))
            }
        }
        return state
    }

    /// Post 配列から集計する（メタへ変換して集計）。
    /// 完遂バッジの正確性のため、呼び出し側は**全投稿**を渡すこと。
    static func aggregate(posts: [Post]) -> CollectionState {
        aggregate(posts.map { PostCollectionMeta(from: $0) })
    }
}
