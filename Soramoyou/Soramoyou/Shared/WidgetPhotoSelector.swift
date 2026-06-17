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
        rotationInterval: TimeInterval,
        slotOffset: Int = 0
    ) -> WidgetIndex.Entry? {
        guard !entries.isEmpty else { return nil }
        let ordered = entries.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.postId < $1.postId
        }
        // 経過したスロット数で索引を進める（負時刻でも安全に正の剰余にする）。
        // slotOffset は「アルバム（offset 0）と同じ在庫でも別の写真を出す」ための位置ずらし（Mode B 用）。
        let interval = max(rotationInterval, 1)
        let slot = Int((date.timeIntervalSince1970 / interval).rounded(.down)) + slotOffset
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

    /// Mode B（今の空）: 現在の時間帯に最も近い在庫の写真から決定的に 1 枚選ぶ。
    /// - まず現在の時間帯（朝/昼/夕/夜）に一致する写真を探す（時刻に寄り添う本来の挙動）。
    /// - 無ければ **いちばん近い時間帯**（巡回距離・例: 昼が無ければ朝か夕）の写真へフォールバック。
    ///   こうすると「今の空」らしさを保ちつつ、全写真を巡回する「アルバム」と被りにくい。
    /// - どの時間帯にも在庫が無い（timeOfDay=nil の写真しか無い等）ときだけ手持ち全体から。
    /// - 写真が 1 枚も無いときだけ nil（呼び出し側で Mode C グラデにフォールバックする）。
    static func skyPick(
        from entries: [WidgetIndex.Entry],
        phase: SkyPhase,
        at date: Date,
        rotationInterval: TimeInterval = defaultRotationInterval
    ) -> WidgetIndex.Entry? {
        guard !entries.isEmpty else { return nil }
        // 現在の時間帯に近い順にバケットを並べ、在庫のあるいちばん近いバケットから選ぶ。
        for bucket in bucketsByNearness(to: phase.timeOfDay) {
            let matches = entries.filter { $0.timeOfDay == bucket.rawValue }
            if !matches.isEmpty {
                return rotatingPick(matches, at: date, rotationInterval: rotationInterval,
                                    slotOffset: albumDecorrelationOffset(for: matches.count))
            }
        }
        // どの時間帯にも該当が無い（全て timeOfDay=nil 等）→ 手持ち全体から（グラデにはしない）。
        return rotatingPick(entries, at: date, rotationInterval: rotationInterval,
                            slotOffset: albumDecorrelationOffset(for: entries.count))
    }

    /// アルバム（offset 0）と同じ在庫を回しても別の写真が出るよう、回転位置をずらす量。
    /// 在庫の約半分ずらして「いちばん離れた」写真を選ぶ（在庫2枚以上なら必ずアルバムと別の写真）。
    /// 在庫1枚のときは 0（ずらしようがない＝同じ1枚しか無い）。
    static func albumDecorrelationOffset(for count: Int) -> Int {
        count >= 2 ? count / 2 : 0
    }

    /// 指定の時間帯から「近い順」に全 `TimeOfDay` を並べる（巡回距離・決定的）。
    /// - 朝→昼→夕→夜→朝… の巡回で考える。
    /// - 距離が同じ場合は **直前の時間帯**（巡回を後ろ向きにたどって近い方）を優先する。
    ///   例: 夜に夜の写真が無ければ、朝より「さっきまでの夕」を選ぶ＝自然で決定的。
    static func bucketsByNearness(to current: TimeOfDay) -> [TimeOfDay] {
        let all = TimeOfDay.allCases
        let n = all.count
        guard let currentIndex = all.firstIndex(of: current) else { return all }
        return all.indices
            .sorted { a, b in
                let da = cyclicDistance(a, currentIndex, n)
                let db = cyclicDistance(b, currentIndex, n)
                if da != db { return da < db }
                // 同距離なら直前の時間帯（後ろ向き距離が小さい方）を優先。
                return backwardDistance(a, currentIndex, n) < backwardDistance(b, currentIndex, n)
            }
            .map { all[$0] }
    }

    /// 長さ `n` の巡回列における 2 索引の最短距離（例: 朝と夜は隣接）。
    private static func cyclicDistance(_ a: Int, _ b: Int, _ n: Int) -> Int {
        let d = abs(a - b)
        return min(d, n - d)
    }

    /// `current` から後ろ向き（巡回を遡る向き）に `i` まで進む距離。直前の時間帯ほど小さい。
    private static func backwardDistance(_ i: Int, _ current: Int, _ n: Int) -> Int {
        ((current - i) % n + n) % n
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
