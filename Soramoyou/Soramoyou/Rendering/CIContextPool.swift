// ⭐️ CIContextPool.swift
// CIContext・Metal デバイスのシングルトンプール
// 【修正】CIContext を毎回生成していたバグを解消
//
//  CIContextPool.swift
//  Soramoyou
//
// 🔧 Phase 1 修正 (2026-04-22):
//   #H-1: Metal 非対応時の .useSoftwareRenderer を false → true に是正
//         （「ソフトウェアレンダラーを有効化する」意図に一致させる）
//   #H-2: .cacheIntermediates = true を明示（スライダー連続操作の中間結果再利用）
//   #H-3: .highQualityDownsample = true を明示（Lanczos 相当の高品質縮小）
//

import CoreImage
import Metal

/// CIContext を再利用するシングルトンプール
///
/// Apple 公式推奨: CIContext は作り直さず再利用する。
/// MTLDevice・CIContext の生成は高コストのため、アプリ起動時に一度だけ生成し以降は共有する。
///
/// 色空間設定:
/// - 作業色空間: linear sRGB（ハイライト/シャドウ復元が精密になる）
/// - 出力色空間: Display P3（Wide Gamut 対応端末でより豊かな色表現）
/// - 作業フォーマット: RGBAh（半精度 float、HDR/強い補正での精度を確保）
/// - cacheIntermediates: true（同一グラフの繰り返し評価を高速化）
/// - highQualityDownsample: true（PreviewRenderer の 2400px 縮小で Lanczos 相当の品質）
final class CIContextPool {

    /// シングルトンインスタンス
    static let shared = CIContextPool()

    /// 共有 CIContext（スレッドセーフ）
    let ciContext: CIContext

    /// 出力色空間（HEIF/JPEG 書き出し時に使用）
    let outputColorSpace: CGColorSpace

    /// 作業色空間（フィルターチェーン内部で使用）
    let workingColorSpace: CGColorSpace

    /// Metal デバイス（Metal シェーダーパイプラインで共有）
    /// Metal 非対応端末では nil
    private(set) var mtlDevice: MTLDevice?

    // MARK: - Private Init（シングルトンのため private）

    private init() {
        self.workingColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        self.outputColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpaceCreateDeviceRGB()

        // Phase 1 #H-2 / #H-3: cacheIntermediates と highQualityDownsample を明示
        let options: [CIContextOption: Any] = [
            .workingColorSpace:     workingColorSpace,
            .outputColorSpace:      outputColorSpace,
            .workingFormat:         CIFormat.RGBAh,
            .cacheIntermediates:    true,
            .highQualityDownsample: true
        ]

        if let device = MTLCreateSystemDefaultDevice() {
            self.mtlDevice = device
            self.ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            // Phase 1 #H-1: Metal 非対応時はソフトウェアレンダラーを有効化する
            // （旧: false は意味反転。Apple 公式推奨に合わせ true に是正）
            self.mtlDevice = nil
            var fallbackOptions = options
            fallbackOptions[.useSoftwareRenderer] = true
            self.ciContext = CIContext(options: fallbackOptions)
        }
    }
}
