//
//  SkyCollection.swift
//  Soramoyou
//
//  空コレクション図鑑（柱2）の集計データ構造。
//  集計はクライアント側の純関数（SkyCollectionAggregator）で行う。
//

import Foundation

/// 図鑑マトリクスの 1 セル（空タイプ × 時間帯）。
struct SkyTimeCell: Hashable, Codable {
    let skyType: SkyType
    let timeOfDay: TimeOfDay
}

/// 集計の入力となる投稿の「軽量メタ」。
///
/// 画像・キャプション・位置の生データは含めず、図鑑に必要な軸だけを保持する。
/// 完遂バッジ（47都道府県等）の正確性のため、集計は**全投稿**のこのメタを入力にする。
struct PostCollectionMeta: Equatable {
    let skyType: SkyType?
    let timeOfDay: TimeOfDay?
    let season: Season?
    let prefecture: JapanPrefecture?

    init(
        skyType: SkyType? = nil,
        timeOfDay: TimeOfDay? = nil,
        season: Season? = nil,
        prefecture: JapanPrefecture? = nil
    ) {
        self.skyType = skyType
        self.timeOfDay = timeOfDay
        self.season = season
        self.prefecture = prefecture
    }

    /// Post から図鑑メタを導出する。
    /// - 季節は `capturedAt`（無ければ `createdAt`）から判定。
    /// - 都道府県は `location.prefecture` を 47都道府県と照合（非該当は nil）。
    init(from post: Post) {
        self.skyType = post.skyType
        // 時間帯は保存済みの値を優先し、無ければ撮影日時(EXIF)→投稿日時から導出する。
        // 季節と同じフォールバック方針に揃え、EXIF時刻が無い投稿でも図鑑（空×時間帯）が埋まるようにする。
        self.timeOfDay = post.timeOfDay ?? TimeOfDay.from(date: post.capturedAt ?? post.createdAt)
        self.season = Season.from(date: post.capturedAt ?? post.createdAt)
        self.prefecture = JapanPrefecture.from(name: post.location?.prefecture)
    }
}

/// 集計結果（あなたが集めた空）。
///
/// `Codable`: `UserDefaults` へのローカルキャッシュに使う。
struct CollectionState: Codable, Equatable {
    var skyTypes: Set<SkyType> = []
    var timeOfDays: Set<TimeOfDay> = []
    var seasons: Set<Season> = []
    var prefectures: Set<JapanPrefecture> = []
    /// 空タイプ × 時間帯 の達成セル（マトリクス表示用）
    var skyTimeCells: Set<SkyTimeCell> = []
    /// 集計対象の総投稿数
    var totalPosts: Int = 0

    /// 指定セルが収集済みか（マトリクス表示用）。
    func isCollected(skyType: SkyType, timeOfDay: TimeOfDay) -> Bool {
        skyTimeCells.contains(SkyTimeCell(skyType: skyType, timeOfDay: timeOfDay))
    }
}
