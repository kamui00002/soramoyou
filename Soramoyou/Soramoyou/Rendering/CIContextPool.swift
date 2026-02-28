// ⭐️ CIContextPool.swift
// CIContext・Metal デバイスのシングルトンプール
// 【修正】CIContext を毎回生成していたバグを解消
//
//  CIContextPool.swift
//  Soramoyou
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
        // 色空間を設定（フォールバック: device RGB）
        self.workingColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        self.outputColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpaceCreateDeviceRGB()

        let options: [CIContextOption: Any] = [
            .workingColorSpace: workingColorSpace,
            .outputColorSpace:  outputColorSpace,
            // 半精度 float: HDR/強い補正でのバンディング防止
            .workingFormat:     CIFormat.RGBAh
        ]

        if let device = MTLCreateSystemDefaultDevice() {
            // Metal GPU アクセラレーション（推奨）
            self.mtlDevice = device
            self.ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            // Metal 非対応端末（シミュレーターなど）: CPU フォールバック
            self.mtlDevice = nil
            var fallbackOptions = options
            fallbackOptions[.useSoftwareRenderer] = false
            self.ciContext = CIContext(options: fallbackOptions)
        }
    }
}
