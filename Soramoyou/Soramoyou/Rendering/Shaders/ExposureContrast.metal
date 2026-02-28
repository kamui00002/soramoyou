// ⭐️ ExposureContrast.metal
// Exposure + Contrast を 1 GPU パスで処理する CIKernel シェーダー
//
//  ExposureContrast.metal
//  Soramoyou
//
// 目的: CIExposureAdjust → CIColorControls の 2 パスを 1 Metal カーネルに統合し
//       中間テクスチャの読み書きを削減することでパフォーマンスを向上させる。
//
// 参考: Apple Developer — Writing Custom Kernels Using Metal Shading Language
//       https://developer.apple.com/documentation/coreimage/writing-custom-kernels

#include <CoreImage/CoreImage.h>
#include <metal_stdlib>

using namespace metal;

/// 露出 + 明るさ + コントラスト + 彩度 統合カーネル
///
/// CIExposureAdjust + CIColorControls の 2 パスを 1 Metal カーネルに統合。
/// 中間テクスチャの読み書きを削減しパフォーマンスを向上させる。
///
/// - Parameter sample:      入力ピクセル（linear sRGB）
/// - Parameter exposureEV:  露出補正（EV 値、例: +1.0 = 2 倍の明るさ）
/// - Parameter brightness:  明るさオフセット（加算、通常 -0.5...0.5）
/// - Parameter contrast:    コントラスト係数（1.0 = 変化なし、> 1.0 でコントラスト増）
/// - Parameter saturation:  彩度係数（1.0 = 変化なし、> 1.0 で彩度増）
/// - Returns: 調整後のピクセル
extern "C" float4 exposureContrastSaturation(
    coreimage::sample_t sample,
    float exposureEV,
    float brightness,
    float contrast,
    float saturation,
    coreimage::destination dest
) {
    // --- 露出調整（EV → 乗数） ---
    float expMult = pow(2.0f, exposureEV);
    float3 color = sample.rgb * expMult;

    // --- 明るさ（加算オフセット） ---
    color = color + brightness;

    // --- コントラスト調整（中間輝度 0.5 を基準にスケール） ---
    // linear sRGB での操作なのでガンマ変換なし
    color = (color - 0.5f) * contrast + 0.5f;

    // --- 彩度調整（ITU-R BT.709 輝度係数で灰色変換） ---
    float luminance = dot(color, float3(0.2126f, 0.7152f, 0.0722f));
    color = mix(float3(luminance), color, saturation);

    // クランプ（linear sRGB の正規化範囲）
    color = clamp(color, 0.0f, 1.0f);

    return float4(color, sample.a);
}
