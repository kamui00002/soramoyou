//
//  WidgetPhotoSelector.swift
//  Soramoyou
//
//  ウィジェットがどの写真を出すかを決める純関数群（Mode A アルバム / Mode B 今の空）。
//  - 入力は `WidgetIndex.Entry` の配列と「時刻」だけ。`Date()` への暗黙依存も乱数も無い＝決定的でテスト容易。
//  - タイムライン上で時間とともに写真がローテーションするよう、時刻から決定的に索引を選ぶ。
//
//  ⚠️ widget セーフ: Foundation と同梱の `WidgetIndex` / `SkyPhase` / `TimeOfDay` のみ。
//

import Foundation

/// ウィジェットの写真選択ロジック（純関数）。
enum WidgetPhotoSelector {

    /// 既定のローテーション間隔（1 時間ごとに次の写真へ）。
    static let defaultRotationInterval: TimeInterval = 60 * 60

    /// 時刻から決定的にローテーション索引を選び、配列から 1 件返す。
    /// - 並びは createdAt 降順（同時刻は postId）で安定化してから索引を取る。
    private static func rotatingPick(
        _ entries: [WidgetIndex.Entry],
        at date: Date,
        rotationInterval: TimeInterval
    ) -> WidgetIndex.Entry? {
        guard !entries.isEmpty else { return nil }
        let ordered = entries.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.postId < $1.postId
        }
        // 経過したスロット数で索引を進める（負時刻でも安全に正の剰余にする）。
        let interval = max(rotationInterval, 1)
        let slot = Int((date.timeIntervalSince1970 / interval).rounded(.down))
        let index = ((slot % ordered.count) + ordered.count) % ordered.count
        return ordered[index]
    }

    /// Mode A（アルバム）: 全エントリを時刻で決定的にローテーションして 1 枚選ぶ。空なら nil。
    static func albumPick(
        from entries: [WidgetIndex.Entry],
        at date: Date,
        rotationInterval: TimeInterval = defaultRotationInterval
    ) -> WidgetIndex.Entry? {
        rotatingPick(entries, at: date, rotationInterval: rotationInterval)
    }

    /// Mode B（今の空）: 現在の局面に合う時間帯の写真から決定的に 1 枚選ぶ。
    /// - 一致する写真が無ければ nil（呼び出し側で Mode C グラデにフォールバックする）。
    static func skyPick(
        from entries: [WidgetIndex.Entry],
        phase: SkyPhase,
        at date: Date,
        rotationInterval: TimeInterval = defaultRotationInterval
    ) -> WidgetIndex.Entry? {
        let bucket = phase.timeOfDay.rawValue
        let matches = entries.filter { $0.timeOfDay == bucket }
        return rotatingPick(matches, at: date, rotationInterval: rotationInterval)
    }

    /// Mode A のタイムライン用に、基準時刻から `rotationInterval` 間隔で `count` 枚ぶんの
    /// （表示開始時刻, エントリ）の並びを返す。エントリが空なら空配列。
    static func albumTimeline(
        from entries: [WidgetIndex.Entry],
        startingAt date: Date,
        count: Int,
        rotationInterval: TimeInterval = defaultRotationInterval
    ) -> [(date: Date, entry: WidgetIndex.Entry)] {
        guard !entries.isEmpty, count > 0 else { return [] }
        var result: [(date: Date, entry: WidgetIndex.Entry)] = []
        for i in 0..<count {
            let slotDate = date.addingTimeInterval(Double(i) * rotationInterval)
            if let entry = albumPick(from: entries, at: slotDate, rotationInterval: rotationInterval) {
                result.append((date: slotDate, entry: entry))
            }
        }
        return result
    }
}
