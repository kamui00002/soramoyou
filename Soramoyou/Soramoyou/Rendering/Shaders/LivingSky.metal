// ⭐️ LivingSky.metal
// 静止画の空だけをループアニメーション化する general CIKernel
//
//  LivingSky.metal
//  Soramoyou
//
// 設計書: docs/living-sky-design.md §2（動きの数式）§3（Metal シェーダー構成）
//
// ⚠️ 既存 ExposureContrast.metal は「色カーネル」（coreimage::sample_t を受け取り、1画素完結の
//    色変換だけを行う）。Living Sky は「変位先（ずらした座標）の画素を読む」必要があるため、
//    coreimage::sampler を受け取る「general kernel」で書く必要がある（色カーネルのテンプレは
//    coreimage::sampler を扱えないためコピペ不可）。
//    参考: Apple Developer — Writing Custom Kernels Using Metal Shading Language

#include <CoreImage/CoreImage.h>
#include <metal_stdlib>

using namespace metal;

// MARK: - ノイズ（設計書§2.3: シェーダ内 inline の hash ベース value noise + fbm）
//
// 乱数テクスチャを持ち込まず、完全決定的（同じ引数なら常に同じ結果）な hash ベースの
// value noise を使う。これにより「フロー速度ムラ」（§2.1）と「光のゆらぎ」（§2.2）の
// 両方を同じノイズ関数で賄い、1パスのシェーダ構成を維持する。

/// 2D 疑似乱数ハッシュ（sin ベース）。テクスチャ不要・完全決定的。
static inline float hash21(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

/// 2D value noise: 格子4隅のハッシュ値を smoothstep カーブで補間する。
static inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);

    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));

    // smoothstep 相当の補間カーブ（線形補間だと格子の継ぎ目が見えるため）
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// fbm（fractal Brownian motion）3オクターブ。
/// フロー用の速度ムラ（§2.1）とシマー用の輝度ゆらぎ（§2.2）の両方で共用する。
static inline float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 3; i++) {
        value += amplitude * valueNoise(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

// MARK: - Living Sky カーネル本体

/// 静止画の空領域だけを風向きに沿ってループ変位させ、光のゆらぎを加える general CIKernel。
///
/// - Parameters:
///   - photo: 編集済み写真（変位先の画素を読むため sampler として受け取る）
///   - mask: フェザー済み空マスク（グレースケール・rチャンネルを使用。1.0=空 / 0.0=地上）
///   - time01: `frac(経過時間 / ループ長T)` の 0...1 値（ループの位相）
///   - flowDirPx: 風向き単位ベクトル × 最大変位px（ワーキング座標系。Swift 側で事前計算して渡す）
///   - shimmerAmp: 光のゆらぎ振幅 0...0.1
///   - speedJitter: 速度ムラの強さ（既定 0.3）
///   - noiseScale: フロー速度ムラ用 fbm の空間スケール（例 0.008）
///   - shimmerScale: シマー用 fbm の空間スケール（例 0.004）
///   - shimmerRadius: シマーの円周サンプリング半径（例 2.0）
///   - dest: 出力先（座標取得に使用）
/// - Returns: 1画素分の出力色（RGBA）
extern "C" float4 livingSky(
    coreimage::sampler photo,
    coreimage::sampler mask,
    float time01,
    float2 flowDirPx,
    float shimmerAmp,
    float speedJitter,
    float noiseScale,
    float shimmerScale,
    float shimmerRadius,
    coreimage::destination dest
) {
    // 設計書§2: 現在の出力画素座標（ワーキング座標系）
    float2 p = dest.coord();

    // 設計書§2.4「最終合成（地上静止の保証）」の前段ガード:
    // マスクは 1.0=空 / 0.0=地上。ほぼ完全に地上（m<0.001）の画素は変位・ノイズ計算そのものが
    // 無駄になるため、photo をそのまま返す早期returnで「地上は完全静止」を数式レベルより早く保証する。
    float m = mask.sample(mask.transform(p)).r;
    if (m < 0.001) {
        return photo.sample(photo.transform(p));
    }

    // 設計書§2.1「フロー変位＋二相クロスフェード」— 速度ムラ:
    // 一様な流れだけだと不自然な「ベルトコンベア感」が出るため、fbm で位置ごとに
    // 流れの速さへ有機的なムラを付与する（F(p) = 風向き × (1 + 0.3・(fbm(p·s) − 0.5)・2)）。
    float j = fbm(p * noiseScale);
    float2 flow = flowDirPx * (1.0 + speedJitter * (j - 0.5) * 2.0);

    // 設計書§2.1: 変位減衰 m^k（k=2）。境界ほど動きを減衰させることで、
    // マスクの誤判定や境界のにじみがあっても地上を引っ張らないようにする。
    float att = m * m;

    // 設計書§2.1「二相クロスフェード（ループの核）」:
    // 1つの位相だけをUV変位させ続けると空が伸び切って破綻するため、0.5 位相ずらした
    // 2つの流れをクロスフェードする。各位相は自身のウェイトが0になる瞬間にだけリセットされる
    // ため、リセットの継ぎ目が視覚的に不可視になる（詳細は設計書「継ぎ目なしの証明」参照）。
    float phi1 = time01;
    float phi2 = fract(time01 + 0.5);
    float4 c1 = photo.sample(photo.transform(p - flow * phi1 * att));
    float4 c2 = photo.sample(photo.transform(p - flow * phi2 * att));
    float w = fabs(2.0 * time01 - 1.0);
    float4 c = mix(c1, c2, w);

    // 設計書§2.2「光のゆらぎ — 円周サンプリングによる周期ノイズ」:
    // 時間項をノイズ空間の「円周上」に置くことで周期性を構造的に保証する
    // （t が一周すると引数が同一点に戻る＝ループ境界で不連続が起きない）。
    float2 shimmerOffset = shimmerRadius * float2(cos(6.2831853 * time01), sin(6.2831853 * time01));
    float eta = fbm(p * shimmerScale + shimmerOffset);
    // 輝度ゲイン L(p,t) = 1 + a_shimmer・m(p)・(η−0.5)・2。マスク乗算済みなので地上は不変。
    c.rgb *= 1.0 + shimmerAmp * m * (eta - 0.5) * 2.0;

    // 設計書§2.4「最終合成（地上静止の保証）」:
    // c_final = mix(photo(p), c_animated, m_feathered(p))。m=0（地上）なら base（元画素そのもの）が
    // 数式レベルで保証され、境界はマスク値でなめらかにブレンドされる。
    float4 base = photo.sample(photo.transform(p));
    return mix(base, c, m);
}
