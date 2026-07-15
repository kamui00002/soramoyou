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

// v2/v4: 方向乱流のパラメータ（マジックナンバー回避）。
// kDirNoiseScale: 方向乱流用 fbm の空間スケール（フロー速度ムラ用 noiseScale 引数より粗い
//   ＝低周波の緩やかな「うねり」にする）。
// kMaxTurnRad: 風向きベクトルを回転させる最大角。v2時代は0.44rad(25°)だったが、
//   v4ではドリフト方向の可読性を優先し0.26rad(15°)へ緩和。
#define kDirNoiseScale 0.004
#define kMaxTurnRad 0.26

// v4: 窓クロスフェード＋画素ごと位相オフセットのパラメータ（マジックナンバー回避）。
// kPhaseOffsetScale: 位相オフセット用 fbm の空間スケール（粗い＝大きなパッチ単位で世代交代）。
// kXfadeHalfWidth: 三角窓 tri を smoothstep で急峻化するクロスフェード半幅（0.15 ⇒ 全体の約3割の
//   時間だけ2コピーが重なる。残り約7割は片方のコピーが単独表示される）。
#define kPhaseOffsetScale 0.003
#define kXfadeHalfWidth 0.15

// v3: 軌道うねり方式のパラメータ（マジックナンバー回避）。
// kPhaseNoiseScale: 周回位相 ph(p) を場所ごとにばらつかせる fbm の空間スケール（粗め＝
//   隣接画素は似た位相を持ちつつ、離れた場所では周回タイミングがずれる）。
// kRadiusNoiseScale: 軌道半径を場所ごとにばらつかせる fbm の空間スケール。
// kOrbitRadiusRatio: 軌道半径 = 最大変位px × この係数（0.5 → 約±4%幅・ピーク速度
//   2πR/T ≈ 23px/s で明確に視認可能）。
#define kPhaseNoiseScale 0.006
#define kRadiusNoiseScale 0.01
#define kOrbitRadiusRatio 0.5

/// 静止画の空領域だけを風向きに沿ってループ変位させ、光のゆらぎを加える general CIKernel。
///
/// - Parameters:
///   - photo: 編集済み写真（変位先の画素を読むため sampler として受け取る）
///   - mask: フェザー済み空マスク（グレースケール・rチャンネルを使用。1.0=空 / 0.0=地上）
///   - time01: `frac(経過時間 / ループ長T)` の 0...1 値（ループの位相）
///   - flowDirPxX: 風向き単位ベクトル × 最大変位px の X 成分（ワーキング座標系。Swift 側で事前計算）
///   - flowDirPxY: 風向き単位ベクトル × 最大変位px の Y 成分
///   - motionModel: 動きモデル切替。0.5未満=v4窓クロスフェード（ドリフト・既定）／
///     それ以外=v3軌道うねり（比較用）。`LivingSkyParameters.motionModel` の Int(0/1) を
///     そのまま Float へキャストして渡す
///   - shimmerAmp: 光のゆらぎ振幅 0...0.1
///   - speedJitter: 速度ムラの強さ（既定 0.3）
///   - noiseScale: フロー速度ムラ用 fbm の空間スケール（例 0.008）
///   - shimmerScale: シマー用 fbm の空間スケール（例 0.004）
///   - shimmerRadius: シマーの円周サンプリング半径（例 2.0）
///   - dest: 出力先（座標取得に使用）
/// - Returns: 1画素分の出力色（RGBA）
///
/// ⚠️ 段階3 vision レビュー指摘#1: 当初 `float2 flowDirPx` として単一ベクトル引数で受け取っていたが、
///    Metal general CIKernel の引数マーシャリングで CIVector → float2 が正しく渡らず (0,0) になり
///    「フロー変位が実質ゼロ（シマーだけが動く）」という不具合が実機/シミュレータ双方で再現した。
///    time01/shimmerAmp 等のスカラー float 引数は正しくマーシャリングされることが実証済みのため、
///    float2 引数を避けて2つの float スカラーに分解し、カーネル冒頭で float2 に再構成する。
extern "C" float4 livingSky(
    coreimage::sampler photo,
    coreimage::sampler mask,
    float time01,
    float flowDirPxX,
    float flowDirPxY,
    float motionModel,
    float shimmerAmp,
    float speedJitter,
    float noiseScale,
    float shimmerScale,
    float shimmerRadius,
    coreimage::destination dest
) {
    // スカラー引数から float2 を再構成（上記の理由により float2 引数を経由しない）
    float2 flowDirPx = float2(flowDirPxX, flowDirPxY);

    // 設計書§2: 現在の出力画素座標（ワーキング座標系）
    float2 p = dest.coord();

    // 設計書§2.4「最終合成（地上静止の保証）」の前段ガード:
    // マスクは 1.0=空 / 0.0=地上。ほぼ完全に地上（m<0.001）の画素は変位・ノイズ計算そのものが
    // 無駄になるため、photo をそのまま返す早期returnで「地上は完全静止」を数式レベルより早く保証する。
    float m = mask.sample(mask.transform(p)).r;

    // 段階3 vision レビュー指摘#3: ヒューリスティックマスクの中間値漏れ（樹冠・樹間が0.4〜0.6帯に
    // 乗る）対策。att=m^2 だけでは中間値が十分に減衰しきらず地上がゆらいでいたため、下限0.45未満を
    // 完全にゼロへ落とし、コア空域（0.75以上）は1.0のまま、境界のグラデーションは0.45〜0.75帯で
    // 維持する再マップを追加する（下限0.30では樹冠・樹間の0.4〜0.6帯を通過してしまい、att=m^2でも
    // 7px程度動くゴースト状スミアが残存したため、指摘#3再発を受けて0.45へ引き上げ）。
    // 地平線ぎわの晴天域は0.7以上のため上限0.75への引き上げによる影響はない。
    // 早期return閾値（m<0.001）はこの再マップ後の m で判定する（漏れ値がゼロ側へ落ちてから
    // 早期returnを効かせるため）。
    m = smoothstep(0.45, 0.75, m);

    if (m < 0.001) {
        return photo.sample(photo.transform(p));
    }

    // 設計書§2.1: 変位減衰 m^k（k=2）。境界ほど動きを減衰させることで、
    // マスクの誤判定や境界のにじみがあっても地上を引っ張らないようにする。
    float att = m * m;

    // 動きモデルの変遷: v2（三相クロスフェード＋方向乱流）は実機シミュレータで分身を抑制できたが、
    // T/4差の変化画素が v1 比 9.3%→1.28% に激減し動き自体が知覚困難になった。そこでクロスフェード
    // を使わない v3「軌道うねり」を追加したが、ユーザー実機評価は「ちょっと気持ち悪い」。一方
    // v2 系のドリフトは「雲が多重に見えて錯視みたい」との評価だった（三相正規化ブレンドが
    // 静止時点でも常に3コピーが重なる「多重露光」構造が原因）。ユーザーはドリフト系を支持した
    // ため、Valve の flow map 定石（窓クロスフェード＋画素ごと位相オフセット）で多重露光を
    // 解消した v4 を新既定にした。motionModel で v4/v3 を切り替えられるようにしている。
    float4 c;
    if (motionModel < 0.5) {
        // ===== v4: フロー変位＋窓クロスフェード＋画素ごと位相オフセット（ドリフト） =====
        // v2（三相正規化ブレンド）は静止時点でも常に3コピーが重なって見える「多重露光」に
        // なる構造的欠陥があり、実機評価で「雲が多重に見えて錯視みたい」と判定された。
        // v4 は Valve の flow map 定石（Vlachos, SIGGRAPH 2010「Water Flow in Portal 2」等で
        // 広く使われる手法）に基づく: ①位相2枚のうち大半の時間はどちらか一方だけを単独表示し、
        // 切替の瞬間だけ短くクロスフェードする「窓クロスフェード」②位相タイミングを画素ごとに
        // ノイズでオフセットし、全画面が同時にフェードする「脈動」を消す。

        // 設計書§2.1「フロー変位」— 速度ムラ:
        // 一様な流れだけだと不自然な「ベルトコンベア感」が出るため、fbm で位置ごとに
        // 流れの速さへ有機的なムラを付与する（F(p) = 風向き × (1 + 0.3・(fbm(p·s) − 0.5)・2)）。
        float j = fbm(p * noiseScale);

        // 方向の乱流（分身対策）。全画素が同方向に平行移動すると分身がくっきり見えるため、
        // 場所ごとに風向きを揺らし、コピー同士を非剛体変形（モーフ）の関係にする
        // （最大回転角 kMaxTurnRad は v4 でドリフト方向の可読性を優先し 0.44→0.26rad へ緩和）。
        // 方向乱流: 粗いfbm（+37.7は速度ムラのノイズ j と座標をずらして相関を切るオフセット。
        // 同じ座標系だと速度ムラと回転ムラが同期し乱流としての効果が薄れるため）で回転する。
        float turn = (fbm(p * kDirNoiseScale + float2(37.7, 37.7)) - 0.5) * 2.0 * kMaxTurnRad;
        float cs = cos(turn);
        float sn = sin(turn);
        // ⚠️ flowDirPx はカーネル冒頭でスカラー引数から再構成済み（float2 引数マーシャリング
        // 不具合を避けるための既存の仕組み。上記コメント参照）。ここではそれをそのまま回転させる。
        float2 turnedDir = float2(
            flowDirPx.x * cs - flowDirPx.y * sn,
            flowDirPx.x * sn + flowDirPx.y * cs
        );
        float2 flow = turnedDir * (1.0 + speedJitter * (j - 0.5) * 2.0);

        // v4 ドリフト（Valve flow map 定石: 窓クロスフェード＋画素ごと位相オフセット）
        // - 位相2枚。各画素は大半の時間どちらか単独のコピーがスライド表示され、
        //   三角窓を smoothstep で急峻化した「窓」の間だけ短くクロスフェードする
        //   （多重像が見えるのは各所で周期の約3割の時間だけ）。
        // - 位相タイミングを粗いノイズで画素ごとにオフセットすることで、
        //   全画面が同時にフェードする「脈動」を消し、雲がパッチ状に世代交代する自然な見えにする。
        // - 全項が time01 の周期関数（オフセットは時不変）なので frame(0)≡frame(T) は維持。
        float phaseOffset = fbm(p * kPhaseOffsetScale);            // 画素ごとの位相オフセット(0..1近傍)
        float f1 = fract(time01 + phaseOffset);
        float f2 = fract(time01 + phaseOffset + 0.5);
        float tri = 1.0 - fabs(2.0 * f1 - 1.0);                    // f1中間で1・リセット時0の三角波
        float wA = smoothstep(0.5 - kXfadeHalfWidth, 0.5 + kXfadeHalfWidth, tri); // 窓化: 1=位相1単独/0=位相2単独
        float2 d1 = flow * f1 * att;
        float2 d2 = flow * f2 * att;
        float4 cA = photo.sample(photo.transform(p - d1));
        float4 cB = photo.sample(photo.transform(p - d2));
        c = mix(cB, cA, wA);
    } else {
        // ===== v3: 軌道うねり（クロスフェードなし・分身原理ゼロ） =====
        // 各画素のサンプル点が閉軌道（風向きに長軸を向けた楕円）を周回する。
        // time01 は cos/sin(2π·time01 + 位相(p)) の形でのみ入るため frame(0)≡frame(T) が
        // 厳密成立（ループ構造保証）。クロスフェードが存在しないため分身（二重像）は原理的にゼロ。
        // 位相 ph(p) を空間ノイズでばらつかせることで、場所ごとに周回タイミングがずれ、
        // 剛体的な「全体が同時に揺れる」動きではなく雲が湧き立つような乱流的な動きに見える。
        float maxDispPx = length(flowDirPx); // Engine が 方向単位ベクトル×最大変位px で渡している
        if (maxDispPx < 0.001) {
            // ⚠️ speed 極小（≈0）で maxDispPx≈0 のとき normalize がNaNになり得るためフォールバック。
            c = photo.sample(photo.transform(p));
        } else {
            float2 windDir = normalize(flowDirPx); // 単位ベクトル（長さは下の radius で扱う）
            float ph = 6.2831853 * time01 + 6.2831853 * fbm(p * kPhaseNoiseScale);
            float radius = maxDispPx * kOrbitRadiusRatio
                * (0.5 + 0.5 * fbm(p * kRadiusNoiseScale + float2(11.3, 11.3)));
            float2 axisMajor = windDir * radius;                                  // 風向きに長軸
            float2 axisMinor = float2(-windDir.y, windDir.x) * radius * 0.35;     // 直交方向は35%
            float2 d = (axisMajor * cos(ph) + axisMinor * sin(ph)) * att;
            c = photo.sample(photo.transform(p - d));
        }
    }

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
