// ⭐️ 空優先AE（白飛び防止）の判定ロジック（副作用を持たない純関数だけを置く）
import Foundation
import ImageIO

/// 空優先 AE（白飛び防止）の判定ロジック。
///
/// 空を撮ると「明るい空 ＋ 暗い地面」になりやすく、カメラは画面全体の平均で測光するため
/// 暗い地面に引っ張られて明るく写す。その結果、空だけが 255 に張り付く（＝白飛びする）。
/// 白飛びした画素には情報が残らないので、後から編集で暗くしても灰色になるだけで復元できない。
/// だから「撮る瞬間に露出を下げて守る」必要がある。
///
/// ここはデバイスにもフレームバッファにも触らない**純粋な判定**だけを置く。
/// 副作用を持たないのでテストで陽性対照（わざと壊して fail を確認する）が取れる。
public enum SkyPriorityExposure {

    // MARK: - Tuning

    /// 判定のふるまいを決める値。既定値は実機較正前の初期値。
    public struct Tuning: Sendable, Equatable {
        /// この輝度（Y: 0〜255）以上を「白飛びしている」とみなす。
        /// 250 は「ほぼ完全に飛んでいる」ライン。245 付近はまだ階調が残っている。
        public var clipThreshold: UInt8
        /// ここまでの白飛びは許す割合（0〜1）。
        /// ⚠️ 0 にしてはいけない。曇り空・太陽そのものは「本当に白い」ので、
        ///    完全にゼロを目指すと露出を下げすぎて写真全体がドブ色になる。
        public var allowedClippedFraction: Double
        /// 許容を超えたとき、超過量に掛ける比例ゲイン（EV / 割合）。
        /// 10 なら「許容より 10% 多く飛んでいる」→ 1.0 EV 下げる計算になる。
        public var attackGain: Double
        /// 1 回の判定で下げられる最小／最大の幅（EV）。急変でも暴れないよう挟む。
        public var minAttackStep: Float
        public var maxAttackStep: Float
        /// 白飛びが収まったときに 0 EV へ戻す 1 回あたりの幅（EV）。
        /// 下げる側より小さくして「下げるのは速く・戻すのは遅く」する（AE の定石）。
        public var recoveryStep: Float
        /// 戻し始める判定に使う余裕。`allowedClippedFraction * recoveryRatio` を下回ったら戻す。
        /// 攻める閾値と戻す閾値をずらす＝ヒステリシス。境界で上げ下げを繰り返す
        /// 「ハンチング（＝明るさがチカチカ揺れる現象）」を防ぐ。
        public var recoveryRatio: Double
        /// 下げてよい下限（EV）。これ以上は暗くしない安全弁。
        public var minBiasEV: Float

        public init(
            clipThreshold: UInt8 = 250,
            allowedClippedFraction: Double = 0.02,
            attackGain: Double = 10,
            minAttackStep: Float = 0.1,
            maxAttackStep: Float = 1.0,
            recoveryStep: Float = 0.15,
            recoveryRatio: Double = 0.5,
            minBiasEV: Float = -2.0
        ) {
            self.clipThreshold = clipThreshold
            self.allowedClippedFraction = allowedClippedFraction
            self.attackGain = attackGain
            self.minAttackStep = minAttackStep
            self.maxAttackStep = maxAttackStep
            self.recoveryStep = recoveryStep
            self.recoveryRatio = recoveryRatio
            self.minBiasEV = minBiasEV
        }

        public static let `default` = Tuning()
    }

    /// これ未満の変化は「動かす価値なし」として捨てる（EV）。
    /// 端末へ毎回 setExposureTargetBias を投げると無駄に電力を使うし、微小な揺れが目に見える。
    public static let negligibleChangeEV: Float = 0.02

    // MARK: - 測光

    /// 輝度プレーン（Y）から「白飛びしている画素の割合」を数える。
    ///
    /// - Parameters:
    ///   - luma: 間引き済みの輝度サンプル（0〜255）
    ///   - threshold: これ以上を白飛びとみなす値
    /// - Returns: 0〜1 の割合。サンプルが空なら 0
    public static func clippedFraction(luma: [UInt8], threshold: UInt8) -> Double {
        guard !luma.isEmpty else { return 0 }
        var clipped = 0
        for value in luma where value >= threshold {
            clipped += 1
        }
        return Double(clipped) / Double(luma.count)
    }

    /// Full Range 基準（0〜255）の閾値を、実際に届いたバッファの流儀へ換算する。
    ///
    /// カメラの輝度プレーン（Y）には 2 つの流儀がある。
    /// - Full Range: 0〜255 をそのまま使う（真っ白 = 255）
    /// - Video Range: 16〜235 に圧縮されている（真っ白 = 235）
    ///
    /// ⚠️ ここを間違えると機能が**黙って死ぬ**。Video Range のバッファに対して
    ///    255 基準の閾値 250 をそのまま使うと、Y は 235 までしか来ないので
    ///    「白飛びは 1 画素も無い」と判定し続け、露出を一度も下げない。
    ///
    /// - Parameters:
    ///   - fullRangeThreshold: Full Range 基準（0〜255）の閾値
    ///   - isFullRange: 届いたバッファが Full Range なら true
    /// - Returns: そのバッファでそのまま比較してよい閾値
    public static func effectiveThreshold(fullRangeThreshold: UInt8, isFullRange: Bool) -> UInt8 {
        guard !isFullRange else { return fullRangeThreshold }
        // Video Range の有効幅は 16...235 の 219 段階。比率を保って写す。
        let scaled = 16.0 + (Double(fullRangeThreshold) / 255.0) * 219.0
        return UInt8(min(235.0, max(16.0, scaled.rounded())))
    }

    // MARK: - 実測値の取り出し

    /// 撮影メタデータ（EXIF）から、その 1 枚が**実際に受けた**露出補正値を取り出す。
    ///
    /// ⭐️ 計装にはこちらを使う。アプリが「最後に要求した値」ではなく
    ///    「撮れた写真そのものに記録された値」なので、次の 2 つのズレを同時に消せる。
    ///    - 撮影処理中も測光は動き続けるので、撮影後に現在値を読むと別の瞬間の値になる
    ///    - AE ロック中は要求値を書いても実露出が追従しないことがある
    ///
    /// - Parameter metadata: `AVCapturePhoto.metadata`（`{Exif}` サブ辞書を含む）
    /// - Returns: 露出補正値（EV）。EXIF に無ければ nil
    public static func exposureBias(fromMetadata metadata: [String: Any]) -> Float? {
        guard let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let value = exif[kCGImagePropertyExifExposureBiasValue as String] as? NSNumber else {
            return nil
        }
        return value.floatValue
    }

    /// 輝度サンプルの最大値を返す（較正用の計測）。
    ///
    /// ⭐️ これは「閾値が届く高さにあるか」を確かめるための計器。
    ///    映像ストリームは ISP がトーンカーブをかけて明るい側を寝かせることがあり、
    ///    写真なら 255 に張り付く場面でもプレビューは 240 前後で止まりうる。
    ///    その場合 250 の閾値には永遠に届かず、白飛び率は常に 0＝機能が出番を失う。
    ///    閾値を動かす前に、まず実機で実際どこまで来るのかを測る。
    ///
    /// - Returns: 0〜255。サンプルが空なら 0
    public static func peakLuma(luma: [UInt8]) -> UInt8 {
        luma.max() ?? 0
    }

    // MARK: - 判定

    /// 白飛び率から、次にかけるべき露出補正値（EV）を決める。
    ///
    /// - Parameters:
    ///   - clippedFraction: 実測した白飛び画素の割合（0〜1）
    ///   - currentBias: いま端末にかけている補正値（EV）
    ///   - tuning: 判定パラメータ
    ///   - deviceLimits: 端末が受け付ける補正範囲（`minExposureTargetBias...maxExposureTargetBias`）
    /// - Returns: 次に設定すべき補正値（EV）。変える必要が無ければ `currentBias` と同値
    public static func decideBias(
        clippedFraction: Double,
        currentBias: Float,
        tuning: Tuning = .default,
        deviceLimits: ClosedRange<Float>
    ) -> Float {
        // この機能は「守る」だけで「明るくする」ことはしない。
        // 上限を 0 に切ることで、暴走しても標準の明るさより明るくはならないと保証できる。
        let upper = min(deviceLimits.upperBound, 0)
        let lower = max(deviceLimits.lowerBound, tuning.minBiasEV)
        // 端末が補正そのものを受け付けない（範囲が潰れている）場合は何もしない。
        guard lower <= upper else { return currentBias }

        let target: Float
        if clippedFraction > tuning.allowedClippedFraction {
            // 飛んでいる → 下げる。超過が大きいほど大きく下げる（比例制御）。
            let excess = clippedFraction - tuning.allowedClippedFraction
            let raw = Float(excess * tuning.attackGain)
            let step = min(tuning.maxAttackStep, max(tuning.minAttackStep, raw))
            target = currentBias - step
        } else if clippedFraction < tuning.allowedClippedFraction * tuning.recoveryRatio {
            // 十分に収まった → 0 EV へゆっくり戻す。
            target = currentBias + tuning.recoveryStep
        } else {
            // 許容と戻し閾値のあいだ＝不感帯。触らないことでチカチカを防ぐ。
            return currentBias
        }

        let clamped = min(upper, max(lower, target))
        // 誤差レベルの動きは捨てる（端末への無駄な書き込みを減らす）。
        guard abs(clamped - currentBias) >= negligibleChangeEV else { return currentBias }
        return clamped
    }
}
