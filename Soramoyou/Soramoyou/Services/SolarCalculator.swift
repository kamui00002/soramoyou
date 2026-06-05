//
//  SolarCalculator.swift
//  Soramoyou
//
//  ゴールデンアワー通知のための太陽計算（NOAA 系の日没アルゴリズム）。
//  端末内で完結する純関数のみ（気象 API・バックエンド不要）。
//  参考: sunrise equation（精度 ±2〜3 分程度、通知用途には十分）。
//

import Foundation

/// 日没時刻とゴールデンアワー通知の発火時刻を端末内で計算する純関数群。
/// - 経度は東経が正（日本は正）、緯度は北緯が正。
enum SolarCalculator {

    // MARK: - 日没計算

    /// 指定した地点・日付（タイムゾーン基準のローカル日付）の日没時刻を返す。
    /// - Parameters:
    ///   - latitude: 緯度（北緯が正、度）
    ///   - longitude: 経度（東経が正、度）
    ///   - date: ローカル日付を決めるための任意の時刻（その日のどの時刻でもよい）
    ///   - timeZone: ローカル日付の判定に使うタイムゾーン
    /// - Returns: 日没時刻。白夜・極夜（太陽が沈まない/昇らない高緯度）の場合は nil。
    static func sunset(
        latitude: Double,
        longitude: Double,
        date: Date,
        timeZone: TimeZone
    ) -> Date? {
        // ローカルカレンダーで「その日の正午」をアンカーにする（日付のブレ防止）
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfDay = calendar.startOfDay(for: date)
        guard let localNoon = calendar.date(byAdding: .hour, value: 12, to: startOfDay) else {
            return nil
        }

        // ユリウス日（Unix epoch 1970-01-01 00:00 UTC = JD 2440587.5）
        let julianDay = localNoon.timeIntervalSince1970 / 86400.0 + 2440587.5

        // J2000.0 からの整数日番号 n。経度補正付きで「この地点の平均太陽正午」に
        // 最も近い日を選ぶ（+0.0008 はうるう秒/ΔT の小補正）
        let n = (julianDay - 2451545.0 + 0.0008 + longitude / 360.0).rounded()

        // 平均太陽正午（J2000.0 相対）。東経では太陽の南中が早まるため経度分を引く
        let meanSolarNoon = n - longitude / 360.0

        // 太陽の平均近点角 M（度）
        let meanAnomaly = normalizedDegrees(357.5291 + 0.98560028 * meanSolarNoon)

        // 中心差 C（度）: 楕円軌道による補正
        let center = 1.9148 * sinDeg(meanAnomaly)
            + 0.0200 * sinDeg(2 * meanAnomaly)
            + 0.0003 * sinDeg(3 * meanAnomaly)

        // 太陽の黄経 λ（度）
        let eclipticLongitude = normalizedDegrees(meanAnomaly + center + 180.0 + 102.9372)

        // 太陽の南中時刻（J2000.0 相対）: 均時差の補正込み
        let solarTransit = meanSolarNoon
            + 0.0053 * sinDeg(meanAnomaly)
            - 0.0069 * sinDeg(2 * eclipticLongitude)

        // 太陽赤緯 δ
        let sinDeclination = sinDeg(eclipticLongitude) * sinDeg(23.4397)
        let cosDeclination = cos(asin(sinDeclination))

        // 日没の時角 ω0（太陽中心が地平線下 0.833° = 大気差 + 視半径）
        let cosHourAngle = (sinDeg(-0.833) - sinDeg(latitude) * sinDeclination)
            / (cosDeg(latitude) * cosDeclination)

        // 白夜（沈まない）・極夜（昇らない）は日没なし
        guard cosHourAngle >= -1.0, cosHourAngle <= 1.0 else { return nil }

        let hourAngle = acos(cosHourAngle) * 180.0 / .pi

        // 日没 = 南中 + 時角分（日数換算）
        let julianSet = solarTransit + hourAngle / 360.0
        let unixTime = (julianSet + 2451545.0 - 2440587.5) * 86400.0
        return Date(timeIntervalSince1970: unixTime)
    }

    // MARK: - ゴールデンアワー通知の発火時刻

    /// 今後 `days` 日分の「夕方ゴールデンアワー通知」の発火時刻（日没の `notifyBeforeSunsetMinutes` 分前）を返す。
    /// - Note: iOS は過去時刻の通知トリガを黙って捨てるため、`now` より未来のもののみを昇順で返す。
    ///   当日の発火時刻を過ぎている場合などは件数が `days` より少なくなる。
    /// - Parameters:
    ///   - latitude: 緯度（北緯が正、度）
    ///   - longitude: 経度（東経が正、度）
    ///   - now: 基準時刻（これ以前の発火時刻は除外）。テストで固定可能。
    ///   - days: 何日先までスケジュールするか
    ///   - notifyBeforeSunsetMinutes: 日没の何分前に通知するか
    ///   - timeZone: ローカル日付の判定に使うタイムゾーン
    static func goldenHourFireDates(
        latitude: Double,
        longitude: Double,
        from now: Date,
        days: Int,
        notifyBeforeSunsetMinutes: Int,
        timeZone: TimeZone
    ) -> [Date] {
        guard days > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var fireDates: [Date] = []
        for offset in 0..<days {
            // 「今日 + offset 日」のローカル日付の日没を求める
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let sunset = sunset(latitude: latitude, longitude: longitude, date: day, timeZone: timeZone) else {
                // 高緯度の白夜・極夜の日はスキップ（日本では発生しない）
                continue
            }
            let fireDate = sunset.addingTimeInterval(-Double(notifyBeforeSunsetMinutes) * 60.0)
            // 過去の発火時刻は iOS が黙って捨てるため、ここで明示的に除外する
            if fireDate > now {
                fireDates.append(fireDate)
            }
        }
        return fireDates.sorted()
    }

    // MARK: - ヘルパー（度数法の三角関数）

    private static func sinDeg(_ degrees: Double) -> Double {
        sin(degrees * .pi / 180.0)
    }

    private static func cosDeg(_ degrees: Double) -> Double {
        cos(degrees * .pi / 180.0)
    }

    /// 角度を 0 以上 360 未満に正規化する
    private static func normalizedDegrees(_ degrees: Double) -> Double {
        let remainder = degrees.truncatingRemainder(dividingBy: 360.0)
        return remainder < 0 ? remainder + 360.0 : remainder
    }
}
