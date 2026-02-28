// ⭐️ MetalShaderPipeline.swift
// Metal CIKernel を使った高速レンダリングパイプライン
//
//  MetalShaderPipeline.swift
//  Soramoyou
//
// 設計:
// - CIKernel は `default.metallib`（Xcode がビルド時に生成）から読み込む
// - カーネル取得に失敗した場合は nil を返し、呼び出し元が CIFilter フォールバックへ切り替える
// - シングルトンとして CIContextPool と同じライフサイクルで管理

import CoreImage
import Foundation

/// Metal CIKernel ラッパー
///
/// `ExposureContrast.metal` に定義された `exposureContrastSaturation` カーネルを
/// `CIKernel` としてロードし、CIImage グラフに組み込む。
///
/// Usage:
/// ```swift
/// if let result = MetalShaderPipeline.shared.applyExposureContrastSaturation(
///     image: img, exposureEV: 1.0, contrast: 1.2, saturation: 1.0) {
///     img = result
/// }
/// ```
final class MetalShaderPipeline {

    // MARK: - Singleton

    static let shared = MetalShaderPipeline()

    // MARK: - Properties

    /// `exposureContrastSaturation` カーネル（ロード失敗時は nil）
    private let exposureContrastKernel: CIKernel?

    // MARK: - Init

    private init() {
        // Xcode は .metal ファイルを自動コンパイルして `default.metallib` に結合する
        // Bundle.main からロードして CIKernel を初期化
        if let url  = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let data = try? Data(contentsOf: url) {
            self.exposureContrastKernel = try? CIKernel(
                functionName: "exposureContrastSaturation",
                fromMetalLibraryData: data
            )
            if exposureContrastKernel == nil {
                print("[MetalShaderPipeline] CIKernel の初期化に失敗（フォールバック使用）")
            }
        } else {
            self.exposureContrastKernel = nil
            print("[MetalShaderPipeline] metallib が見つかりません（フォールバック使用）")
        }
    }

    // MARK: - Public API

    /// Metal カーネルで露出・明るさ・コントラスト・彩度を 1 パスで処理する
    ///
    /// - Parameters:
    ///   - image:       入力 CIImage
    ///   - exposureEV:  露出補正（EV 単位）
    ///   - brightness:  明るさオフセット（加算）
    ///   - contrast:    コントラスト係数（1.0 = 変化なし）
    ///   - saturation:  彩度係数（1.0 = 変化なし）
    /// - Returns: 処理後の CIImage、カーネル未ロード時は nil（フォールバック用）
    func applyExposureContrastSaturation(
        image:       CIImage,
        exposureEV:  Float,
        brightness:  Float,
        contrast:    Float,
        saturation:  Float
    ) -> CIImage? {
        guard let kernel = exposureContrastKernel else { return nil }

        return kernel.apply(
            extent:      image.extent,
            roiCallback: { _, rect in rect },
            arguments:   [image, exposureEV, brightness, contrast, saturation]
        )
    }

    /// Metal カーネルが使用可能かどうか
    var isAvailable: Bool { exposureContrastKernel != nil }
}
