// ⭐️ レンズ切替（超広角・標準・望遠）の倍率計算（副作用を持たない純関数だけを置く）
import CoreGraphics
import Foundation

/// 端末のレンズ構成と、表示倍率（0.5x / 1x / 3x …）の換算。
///
/// ⚠️ **2 つの「倍率」を混同しないこと。**
/// - `videoZoomFactor`: AVFoundation が使う内部値。**いちばん広いレンズが常に 1.0**。
/// - 表示倍率: ユーザーに見せる値。iPhone の流儀では**標準レンズが 1x**。
///
/// 3 眼端末では内部の 1.0 が超広角なので、表示は 0.5x になる。
/// つまり表示倍率 = `videoZoomFactor ÷ baseFactor`（baseFactor = 標準レンズが始まる内部値）。
/// ここを取り違えると、ボタンの表示・スライダーの位置・実際の画角が全部ずれる。
public struct LensConfiguration: Equatable, Sendable {

    /// 表示倍率 1x に相当する `videoZoomFactor`。
    /// 超広角つき端末では 2.0 前後、超広角の無い端末では 1.0。
    public let baseFactor: CGFloat

    /// `videoZoomFactor` の下限（＝いちばん広いレンズ）。
    public let minFactor: CGFloat

    /// `videoZoomFactor` の上限。端末が許す最大値をそのまま使うと
    /// スライダーの大半がデジタルズーム（画質が落ちる領域）になって操作しづらいので、
    /// 表示 10x 相当で頭打ちにしている。
    public let maxFactor: CGFloat

    /// レンズが切り替わる `videoZoomFactor`（`virtualDeviceSwitchOverVideoZoomFactors`）。
    public let switchOverFactors: [CGFloat]

    /// 超広角レンズを持っているか。
    public let hasUltraWide: Bool

    /// 表示 10x を実用上の上限とする（デジタルズーム領域を切り詰めるため）。
    public static let maxDisplayedZoom: CGFloat = 10

    /// - Parameters:
    ///   - hasUltraWide: いちばん広いレンズが超広角か（3眼・広角2眼なら true）
    ///   - switchOverFactors: 端末が報告するレンズ切替点
    ///   - minFactor: `device.minAvailableVideoZoomFactor`
    ///   - deviceMaxFactor: `device.maxAvailableVideoZoomFactor`
    public init(hasUltraWide: Bool,
                switchOverFactors: [CGFloat],
                minFactor: CGFloat,
                deviceMaxFactor: CGFloat) {
        self.hasUltraWide = hasUltraWide
        let sorted = switchOverFactors.sorted()
        self.switchOverFactors = sorted
        // 超広角つきなら「最初の切替点＝標準レンズの始まり」が 1x。
        // 超広角が無ければ、いちばん広いレンズがそのまま 1x。
        let base = (hasUltraWide ? sorted.first : nil) ?? 1.0
        self.baseFactor = max(base, 0.0001)   // 0 除算よけ（端末が 0 を返す事故に備える）
        self.minFactor = max(minFactor, 0.0001)
        self.maxFactor = max(min(deviceMaxFactor, self.baseFactor * Self.maxDisplayedZoom),
                             self.minFactor)
    }

    // MARK: - 換算

    /// 内部値 → 表示倍率。
    public func displayedZoom(forVideoZoomFactor factor: CGFloat) -> CGFloat {
        factor / baseFactor
    }

    /// 表示倍率 → 内部値（端末が受け付ける範囲へ収める）。
    public func videoZoomFactor(forDisplayedZoom zoom: CGFloat) -> CGFloat {
        clamped(zoom * baseFactor)
    }

    /// 内部値を端末が受け付ける範囲へ収める。
    public func clamped(_ factor: CGFloat) -> CGFloat {
        min(maxFactor, max(minFactor, factor))
    }

    /// 望遠レンズが始まる表示倍率。望遠を持たない端末では nil。
    ///
    /// 「この倍率より望遠側は、単眼の広角デバイスでは光学的に届かない」という境界。
    /// 48MP のためにデバイスを付け替えるかどうかの判断に使う。
    public var teleSwitchOverDisplayedZoom: CGFloat? {
        guard let factor = switchOverFactors.first(where: { $0 > baseFactor }) else { return nil }
        return displayedZoom(forVideoZoomFactor: factor)
    }

    // MARK: - プリセット

    /// iPhone 標準カメラが並べる倍々の停留点。
    private static let doublingStops: [CGFloat] = [2, 4, 8]

    /// ボタンを並べる上限。これ以上増やすと 1 つが小さくなって押し間違える。
    private static let maxPresetCount = 5

    /// ボタンに並べる表示倍率（例: 0.5x / 1x / 2x / 4x / 8x）。
    ///
    /// 光学的な切替点（レンズが変わる位置）を優先し、そのうえで iPhone 標準カメラと
    /// 同じ倍々の停留点を足す。近い値が並ぶと押し分けられないので、
    /// **15% 以内に寄っているものは先に入れた方（＝光学側）を残す**。
    public var presetDisplayedZooms: [CGFloat] {
        // 優先順に候補を積む。あとで近いもの同士をまとめるとき、先に入れた方が残る。
        var candidates: [CGFloat] = []
        if hasUltraWide {
            // いちばん広いレンズの表示倍率（3眼なら 0.5 前後）。
            candidates.append(displayedZoom(forVideoZoomFactor: minFactor))
        }
        candidates.append(1)
        // 標準より望遠側の切替点（＝望遠レンズが始まる点）。
        for factor in switchOverFactors where factor > baseFactor {
            candidates.append(displayedZoom(forVideoZoomFactor: factor))
        }
        // ⚠️ 倍々の停留点はレンズが複数ある端末にだけ出す。
        //    単眼端末（iPhone SE など）に並べると全部デジタルズーム＝画質が落ちるだけの
        //    ボタンになる。iPhone 標準カメラも単眼機では 1x しか出さない。
        let hasMultipleLenses = hasUltraWide || !switchOverFactors.isEmpty
        if hasMultipleLenses {
            candidates.append(contentsOf: Self.doublingStops)
        }

        let maxDisplayed = displayedZoom(forVideoZoomFactor: maxFactor)
        var kept: [CGFloat] = []
        for zoom in candidates where zoom <= maxDisplayed + 0.0001 {
            // 相対差で見る。0.5 と 0.6 は近いが、4 と 4.1 も近い、を同じ物差しで扱うため。
            let isTooClose = kept.contains { abs($0 - zoom) / max($0, 0.0001) < 0.15 }
            if isTooClose { continue }
            kept.append(zoom)
            if kept.count == Self.maxPresetCount { break }
        }
        return kept.sorted()
    }

    // MARK: - 表示

    /// 表示倍率をボタンの文字にする（iPhone と同じ流儀）。
    /// 1 未満は小数1桁（0.5）、整数はそのまま（1 / 3）、それ以外は小数1桁（1.5）。
    public static func label(forDisplayedZoom zoom: CGFloat) -> String {
        let rounded = (zoom * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05, rounded >= 1 {
            return "\(Int(rounded.rounded()))x"
        }
        return String(format: "%.1fx", Double(rounded))
    }

    /// 押されたプリセットの「次」を返す（ボタンを1つにまとめて巡回させる場合に使う）。
    public func nextPreset(after zoom: CGFloat) -> CGFloat {
        let presets = presetDisplayedZooms
        guard !presets.isEmpty else { return 1 }
        // いまの倍率より大きい最初のプリセット。無ければ先頭へ戻る。
        return presets.first { $0 > zoom + 0.0001 } ?? presets[0]
    }
}

// MARK: - デバイス要件

/// いま掴むべき背面カメラの種類。
public enum SkyCameraLensRequirement: Equatable, Sendable {

    /// 超広角・望遠を含む仮想デバイス（レンズ切替が使える／最大 24MP 程度）。
    case virtual

    /// 単眼の広角デバイス（48MP が撮れる／超広角・望遠は無い）。
    case singleWide
}

/// 「いまの倍率と希望解像度なら、どちらのデバイスを掴むべきか」を決める純関数。
///
/// ⭐️ **なぜ純関数に切り出すか**: デバイスの付け替えは実機でしか起きないので、
///    判断とセッション操作が混ざっていると境界値（0.999x・ちょうど 1x・望遠の切替点）を
///    テストできない。判断だけを取り出せば、端末無しで全部の分岐を固定できる。
///
/// ⭐️ **判断の中身**: iPhone 標準カメラと同じ流儀。48MP は**メインカメラの範囲にいる間だけ**
///    有効で、超広角や望遠へ移ったらレンズを優先して解像度が下がる。
///    ユーザーから見ると「レンズはいつでも選べる」が成り立つ。
public enum SkyCameraLensSwitching {

    /// 倍率の比較に使う許容誤差。ドラッグで 0.9999 のような値が入っても
    /// 「1x ちょうど」として扱うために要る。
    public static let zoomEpsilon: CGFloat = 0.001

    /// 境界の不感帯。**いま掴んでいるデバイス側に倍率の幅を足す**。
    ///
    /// ⚠️ これが無いと、1x のすぐ近くで指が震えただけで境界を何度もまたぎ、
    ///    そのたびにデバイスが付け替わる（＝プレビューが黒く落ちる）。
    ///    付け替えはセッションの作り直しなので、ズームと違って取り返しが重い。
    ///    空優先 AE で不感帯を入れたのと同じ理由。
    public static let switchHysteresis: CGFloat = 0.05

    /// - Parameters:
    ///   - displayedZoom: これから合わせたい表示倍率
    ///   - preferredRequiresSingleLens: ユーザーが選んだ解像度が単眼デバイスを要求するか（＝48MP か）
    ///   - teleSwitchOverDisplayedZoom: 望遠レンズが始まる表示倍率（無ければ nil）
    ///   - current: いま掴んでいるデバイス（不感帯をどちら側に付けるかの判断に使う）
    public static func requiredDevice(displayedZoom: CGFloat,
                                      preferredRequiresSingleLens: Bool,
                                      teleSwitchOverDisplayedZoom: CGFloat?,
                                      current: SkyCameraLensRequirement) -> SkyCameraLensRequirement {
        // 48MP を求めていないなら、常にレンズ切替が使える仮想デバイスでよい。
        guard preferredRequiresSingleLens else { return .virtual }
        // いま単眼にいるなら、離れるのに余分に動かす必要がある（＝居座りやすくする）。
        let margin = (current == .singleWide) ? switchHysteresis : 0
        // 1x より広い＝超広角が要る。単眼の広角では光学的に届かない。
        if displayedZoom < 1 - zoomEpsilon - margin { return .virtual }
        // 望遠の切替点より望遠側＝望遠レンズが要る。
        if let tele = teleSwitchOverDisplayedZoom,
           displayedZoom >= tele + margin - zoomEpsilon {
            return .virtual
        }
        // 1x 〜 望遠手前はメインカメラの担当。ここだけ 48MP が活きる。
        return .singleWide
    }
}
