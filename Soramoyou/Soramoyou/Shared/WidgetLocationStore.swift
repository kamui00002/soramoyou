//
//  WidgetLocationStore.swift
//  Soramoyou
//
//  本体が書き、ウィジェットが読む「太陽計算用の粗い現在地」(App Group dual-write)。
//  - 本体: ゴールデンアワー通知で取得した粗い座標(小数2桁 ≒ 1km)をここへ書く。
//          新規パーミッションも追加測位もしない＝既存の位置取得に相乗りするだけ。
//  - ウィジェット: これを読んで局面(SkyPhase)計算に使う。無ければ東京フォールバック。
//
//  ⚠️ プライバシー: 保存するのは小数2桁に粗めた座標のみ(街区レベル)。日没計算に高精度は不要。
//  ⚠️ widget セーフ: Foundation と AppGroup のみに依存(Firebase/UIKit/CoreLocation に触れない)。
//    本体・ウィジェット拡張の両ターゲットに Target Membership で所属させる。
//

import Foundation

/// App Group に置く粗い現在地レコード(太陽計算用)。
struct WidgetLocationRecord: Codable, Equatable {
    /// 粗めた緯度(小数2桁)。
    let latitude: Double
    /// 粗めた経度(小数2桁)。
    let longitude: Double
    /// 最終更新時刻(鮮度の目安・将来の失効判定用)。
    let updatedAt: Date
}

/// 太陽計算用の粗い現在地を App Group に読み書きする窓口(純粋・テスト容易)。
enum WidgetLocationStore {

    /// 緯度経度を小数2桁に粗めて App Group へ原子的に書く(best-effort)。
    /// - Parameters:
    ///   - containerURL: 書き込み先コンテナ。テストでは temp ディレクトリを注入する。
    /// - Returns: 書けたら true。entitlement 未付与(containerURL=nil)やエンコード失敗で false。
    @discardableResult
    static func write(
        latitude: Double,
        longitude: Double,
        at date: Date = Date(),
        containerURL: URL? = AppGroup.containerURL
    ) -> Bool {
        guard let url = locationFileURL(containerURL) else { return false }
        // 入力が既に粗めてあっても二重に丸めて安全側(冪等)。
        let coarseLatitude = (latitude * 100).rounded() / 100
        let coarseLongitude = (longitude * 100).rounded() / 100
        let record = WidgetLocationRecord(latitude: coarseLatitude, longitude: coarseLongitude, updatedAt: date)
        guard let data = try? JSONEncoder().encode(record) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// App Group から粗い現在地を読む。無ければ nil(呼び出し側で東京フォールバック)。
    static func read(containerURL: URL? = AppGroup.containerURL) -> WidgetLocationRecord? {
        guard let url = locationFileURL(containerURL),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(WidgetLocationRecord.self, from: data) else {
            return nil
        }
        return record
    }

    /// 注入された(またはデフォルトの)コンテナURLから位置ファイルのURLを求める。
    private static func locationFileURL(_ containerURL: URL?) -> URL? {
        containerURL?.appendingPathComponent(AppGroup.Path.locationFile, isDirectory: false)
    }
}
