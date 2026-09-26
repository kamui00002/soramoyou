// ⭐️ 長押しロック中の「明るさ調整（☀︎ドラッグ）」の計算（副作用を持たない純関数だけを置く）
import CoreGraphics
import Foundation

/// AE/AF ロック中に、ユーザーが指で露出補正（明るさ）を動かすための計算。
///
/// iPhone 標準カメラと同じく「長押しで固定 → 上下ドラッグで明るさ」を実現する。
/// ここはデバイスにもジェスチャにも触らない**純粋な計算**だけを置く。
/// 副作用を持たないので、テストで陽性対照（わざと壊して fail を確認する）が取れる。
public enum ManualExposure {
    // MARK: - 定数

    /// 手動で動かせる幅の上限（絶対値・EV）。
    /// ⚠️ 端末は ±8 EV 程度まで受け付けるが、そこまで振ると真っ白／真っ黒になるだけで
    ///    空の写真としては使い物にならない。標準カメラと同じ ±2 EV に絞る。
    public static let maxAbsBiasEV: Float = 2.0

    /// 指の移動量（pt）1 あたりの補正量（EV）。
    /// 約 200pt（画面の 1/4 程度）のドラッグで ±2 EV の端まで届く感度にしてある。
    /// これより敏感にすると、指を離す瞬間のわずかなブレで値が動いてしまう。
    public static let evPerPoint: Float = 0.01

    /// ドラッグ中の値を揃える刻み（EV）。表示も 0.1 刻みなので、内部値も揃えておく
    /// （揃えないと「表示は同じなのに露出が微妙に違う」状態が生まれる）。
    public static let dragStepEV: Float = 0.1

    /// VoiceOver の「増やす／減らす」1 回ぶんの幅（EV）。
    /// カメラの露出補正で一般的な 1/3 段に合わせる。
    public static let accessibilityStepEV: Float = 1.0 / 3.0

    // MARK: - 範囲

    /// 手動で動かせる範囲を求める。
    ///
    /// 端末の範囲と ±2 EV の**狭い方**を採る。端末が ±2 より狭い（古い端末・一部のレンズ）
    /// ときに ±2 を押し付けると、書き込めない値を要求することになる。
    /// - Parameters:
    ///   - deviceMin: `AVCaptureDevice.minExposureTargetBias`
    ///   - deviceMax: `AVCaptureDevice.maxExposureTargetBias`
    /// - Returns: 動かせる範囲。端末の値が壊れている（min > max・範囲が 0 を含まない）なら nil
    public static func range(deviceMin: Float, deviceMax: Float) -> ClosedRange<Float>? {
        let lower = max(deviceMin, -maxAbsBiasEV)
        let upper = min(deviceMax, maxAbsBiasEV)
        // ⚠️ `lower...upper` は lower > upper だと実行時トラップする。端末の値を信用せず確かめる。
        //    また 0（素の状態）を含まない範囲では「解除で 0 に戻す」が成り立たないので扱わない。
        guard lower <= upper, lower <= 0, upper >= 0 else { return nil }
        return lower ... upper
    }

    /// 値を範囲に収める。
    public static func clamp(_ bias: Float, to range: ClosedRange<Float>) -> Float {
        min(range.upperBound, max(range.lowerBound, bias))
    }

    /// 0.1 EV 刻みへ丸める（計装の `exposure_bias_ev` と同じ丸め方）。
    public static func roundedToStep(_ bias: Float) -> Float {
        (bias / dragStepEV).rounded() * dragStepEV
    }

    // MARK: - ドラッグ

    /// ドラッグ量から補正値を求める。
    ///
    /// - Parameters:
    ///   - startBias: ドラッグを始めた時点で**実際にかかっていた**補正値。
    ///     空優先 AE がロック前に -1.0 を掛けていれば -1.0 から始まる（0 から始めると跳ぶ）。
    ///   - translationY: ドラッグ開始点からの縦の移動量（pt）。UIKit の座標なので**上が負**。
    ///   - range: `range(deviceMin:deviceMax:)` で求めた範囲
    /// - Returns: 端末へ書き込む補正値（0.1 EV 刻み・範囲内）
    public static func bias(startBias: Float,
                            translationY: CGFloat,
                            range: ClosedRange<Float>) -> Float
    {
        // 上へ動かす（translationY が負）＝明るく、なので符号を反転する。
        let delta = -Float(translationY) * evPerPoint
        // ⚠️ 半刻みに届かないうちは開始値のまま返す。開始値が刻みに乗っていない
        //    （空優先 AE の -0.75 など）とき、触れた瞬間に丸めで値が跳ぶのを防ぐ。
        guard abs(delta) >= dragStepEV / 2 else {
            return clamp(startBias, to: range)
        }
        // 丸めてから範囲に収める（逆順だと、端末の端が刻みに乗っていないときに
        // 丸めで範囲の外へはみ出しうる）。
        return clamp(roundedToStep(startBias + delta), to: range)
    }

    /// VoiceOver の「増やす／減らす」1 回ぶん動かした補正値を求める。
    ///
    /// 1/3 段の格子へ吸着させてから 1 段動かす。単純に ±1/3 を足すと、
    /// 開始値が格子に乗っていない（ドラッグ後の 0.1 刻みなど）ときに端数が残り続ける。
    /// - Parameters:
    ///   - currentBias: いまかかっている補正値
    ///   - direction: 増やすなら +1、減らすなら -1
    ///   - range: 動かせる範囲
    public static func steppedBias(currentBias: Float,
                                   direction: Int,
                                   range: ClosedRange<Float>) -> Float
    {
        let currentStep = (currentBias / accessibilityStepEV).rounded()
        let next = (currentStep + Float(direction.signum())) * accessibilityStepEV
        return clamp(next, to: range)
    }

    // MARK: - 表示

    /// 補正値の表示文字列（例 "+0.7" / "0.0" / "-1.3"）。
    ///
    /// ⚠️ `%+.1f` だけだと 0 付近が "+0.0" や "-0.0" になる。
    ///    標準カメラと同じく、素の状態は符号なしの "0.0" に揃える。
    public static func displayText(_ bias: Float) -> String {
        guard abs(bias) >= dragStepEV / 2 else { return "0.0" }
        return String(format: "%+.1f", Double(bias))
    }

    /// VoiceOver で読み上げる値（例「プラス0.7」「マイナス1.3」「0」）。
    /// 記号の "+" "-" はそのままだと読み飛ばされたり「ハイフン」と読まれるので言葉にする。
    public static func accessibilityValue(_ bias: Float) -> String {
        guard abs(bias) >= dragStepEV / 2 else { return "0" }
        let magnitude = String(format: "%.1f", Double(abs(bias)))
        return bias > 0 ? "プラス\(magnitude)" : "マイナス\(magnitude)"
    }

    /// 太陽マークをトラック線の中心からどれだけずらすか（pt。上が負）。
    ///
    /// ±2 EV をトラックの両端に固定で対応させる。端末の範囲で割ると、
    /// 端末ごとに同じ補正値でも位置が変わってしまい、見た目から値を読めなくなる。
    /// - Parameters:
    ///   - bias: いまかかっている補正値
    ///   - trackHalfLength: トラック線の長さの半分（pt）
    public static func indicatorOffset(bias: Float, trackHalfLength: CGFloat) -> CGFloat {
        let normalized = max(-1, min(1, bias / maxAbsBiasEV))
        return -CGFloat(normalized) * trackHalfLength
    }

    // MARK: - 所有権

    /// ロック解除時に補正値を 0 へ戻すべきか。
    ///
    /// ⭐️ **そのロック中に手動で動かしたときだけ**戻す。
    ///    動かしていないのに戻すと、ロック前に空優先 AE が掛けていた補正まで消してしまい、
    ///    既存の空優先 AE の挙動が変わる（解除後の測光で改めて決め直されるまで一瞬明るくなる）。
    ///    逆に動かしたのに戻さないと、手動の値が解除後も残り、空優先 AE の出発点を汚す。
    public static func shouldResetOnUnlock(hasManualAdjustment: Bool) -> Bool {
        hasManualAdjustment
    }
}
