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

// v7: 微ドリフト＋周期モーフのパラメータ（マジックナンバー回避）。
// 出典: docs/research/living-sky-research-2026-07.md「推奨パラメータ」（方式B 周期ノイズに
// よるUVワープ／方式C+D のハイブリッド）。v4〜v6 が採用していた「色クロスフェード窓」
// （kPhaseOffsetScale/kXfadeHalfWidth）と「エッジ接線偏向」（kGradSamplePx/kEdgeLo/kEdgeHi/
// kEdgeAmpReduce/kTangentMax）は v7 で撤去したため、それらのパラメータ定義も削除した
// （詳細は下の livingSky 本体 v7 ブロックのコメント参照）。
// kMorphScale1 / kMorphScale2: 周期モーフ用 fbm の空間スケール。低周波(kMorphScale1)=
//   大きな雲塊のうねり、高周波(kMorphScale2)=微細な輪郭変化という役割分担は、レポートの
//   lowFreqScale（空幅に1〜2波）/ highFreqScale（空幅に5〜8波）に対応する。1080px
//   （v7導入時のプレビュー作業解像度の目安）換算の初期値であり、実機目視での較正を
//   前提とする（2026-07-17 v7導入時点では未検証）。
// kMorphRadius: 周期モーフの円周サンプリング半径（cyc = (cos, sin) への係数）。値が大きいほど
//   1ループ中にノイズ場を広く周回して変化が大きくなる。
// kWarpSafeThreshold: safeSample フォールバックが参照する warpMask の閾値。変位後の参照先
//   warpMask 値がこの値未満（=侵食済み安全領域の外）なら元画素へフォールバックする。
#define kMorphScale1 0.004
#define kMorphScale2 0.011
#define kMorphRadius 1.5
#define kWarpSafeThreshold 0.35

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
///   - mask: フェザー済み空マスク＝合成用マスク compositeMask（グレースケール・rチャンネルを
///     使用。1.0=空 / 0.0=地上）。最終合成 `mix(base, c, m)` の重みに使う
///   - warpMask: 侵食＋ブラー済みの変形安全マスク（v7 で追加。出典:
///     docs/research/living-sky-research-2026-07.md「二重マスク構成」）。変位減衰の距離減衰
///     近似、および safeSample フォールバックの安全判定に使う
///   - time01: `frac(経過時間 / ループ長T)` の 0...1 値（ループの位相）
///   - flowDirPxX: 風向き単位ベクトル × ドリフト振幅px の X 成分（ワーキング座標系。Swift 側で事前計算）
///   - flowDirPxY: 風向き単位ベクトル × ドリフト振幅px の Y 成分
///   - motionModel: 動きモデル切替。0.5未満=v7微ドリフト＋周期モーフ＋二重マスク
///     （レポート準拠ハイブリッド・既定）／それ以外=v3軌道うねり（比較用）。
///     `LivingSkyParameters.motionModel` の Int(0/1) をそのまま Float へキャストして渡す
///   - microWarpPx: 周期モーフ（雲の輪郭の微小な形状変化）の振幅px（v7 で追加）
///   - shimmerAmp: 光のゆらぎ振幅 0...0.1
///   - speedJitter: 速度ムラの強さ（既定 0.5）
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
///    float2 引数を避けて2つの float スカラーに分解し、カーネル冒頭で float2 に再構成する
///    （v7 で追加した warpMask/microWarpPx も同じ理由で sampler/float スカラーのみにしている）。
extern "C" float4 livingSky(
    coreimage::sampler photo,
    coreimage::sampler mask,
    coreimage::sampler warpMask,
    float time01,
    float flowDirPxX,
    float flowDirPxY,
    float motionModel,
    float microWarpPx,
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
    // その後 v4 は TestFlight 実機評価（2026-07-16）で「輪郭の鋭い雲だと分身が見える」との
    // 最終NGを受けた。原因は構造的: クロスフェード窓の間（周期の約3割）は2コピーが
    // flow×0.5 ずれて重なったまま**色をブレンド**するため、鋭いエッジでは二重線として見えてしまう。
    // そこで色のブレンドをやめ「サンプル位置（変位）のブレンド」に変える v5 へ刷新したが、
    // v5 は窓の間にサンプル位置が新位相へ滑り戻る「局所的な巻き戻し」（順方向の約2.3倍速）という
    // 構造的トレードオフを抱えており、ユーザー実機評価（2026-07-17）で「すごい気持ち悪い」との
    // 最終NGを受けた。そこで v6 は「輪郭を横切る方向」の変位だけが分身に見えるという観察に基づき、
    // v4 の色クロスフェードを復活させつつ輝度勾配で輪郭の接線方向へフロー方向を曲げる
    // 「エッジ接線偏向」を追加したが、TestFlight実機提出前の技術調査
    // （docs/research/living-sky-research-2026-07.md）で振り返った結果、v4〜v6 共通の根本原因は
    // 「振幅過大」（幅5%/ループ＝レポート推奨0.4%〜1.8%の4〜8倍）で、ドリフトの大振幅だけで
    // 「生きてる感」を出そうとしていたことだと判明した。
    // v7（レポート準拠ハイブリッド）は発想を転換する: ドリフトは短辺の0.8%へ縮小し脇役に回す
    // （分身の見た目の幅も知覚限界=3px相当以下に収まる）。「生きてる感」は主役を
    // ①円周サンプリングで厳密に周期化された微小モーフ（周期ノイズによるUVワープ＝レポート
    // 方式B）と②控えめな光のゆらぎに持たせる。振幅そのものを知覚限界以下に縮小したため、
    // v6 のエッジ接線偏向（勾配サンプル・輪郭検出による偏向）はもはや不要と判断し撤去した。
    // 電線・電柱等の細い前景構造は warpMask（侵食＋ブラー済み安全領域）と safeSample
    // フォールバックで保護する（レポート「二重マスク構成」）。motionModel=0=ドリフトの実装
    // 差し替えであり、新しい motionModel 値は追加していない。
    float4 c;
    if (motionModel < 0.5) {
        // ===== v7: レポート準拠ハイブリッド（微ドリフト＋周期モーフ＋二重マスク） =====
        // 出典: docs/research/living-sky-research-2026-07.md（方式 C flow map + B 周期ノイズ +
        // D 複数サンプルの位相差ブレンド、二重マスク・safeSampleフォールバック込み）。
        // レポートが提案する MTLTexture 直描き構成ではなく、既存の CIKernel 1パス構成の
        // 中へそのまま移植したもの（distanceTexture の EDT は用意せず、warpMask 自体の
        // ブラーで距離減衰を近似する簡略版）。

        // 設計書§2.1「フロー変位」— 速度ムラ・方向乱流（v4〜v6 から不変。下の値そのものは
        // 一切変更していない。分身対策としての役割はドリフト振幅が小さくなった v7 でも
        // 引き続き有効）:
        // 一様な流れだけだと不自然な「ベルトコンベア感」が出るため、fbm で位置ごとに
        // 流れの速さへ有機的なムラを付与する（F(p) = 風向き × (1 + speedJitter・(fbm(p·s) − 0.5)・2)、
        // speedJitter既定0.5）。
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

        // v7: 変位減衰は warpMask（侵食＋ブラー済みの変形安全領域）ベースにする。従来の
        // m^2（合成用マスク mask 由来。上の att 変数）は境界のにじみをそのまま距離減衰の
        // 近似として使っていたが、warpMask は明示的に erosion 済みのため「この内側なら
        // 動かしてよい」という安全余白（レポート「二重マスク構成」）をより厳密に表現できる。
        // ⚠️ この att はこの if ブロック内でのみ有効な局所変数で、外側スコープの
        //    `att`（m^2・上で宣言済み・v3 が使う）を意図的にシャドウする。v3 分岐は
        //    不変更のため warpMask を使わず外側の att（m^2）をそのまま使い続ける。
        float attW = warpMask.sample(warpMask.transform(p)).r;
        float att = attW * attW;

        // ===== v7: 微ドリフト（二相・中心対称）＋周期モーフ（レポート方式 C+B+D） =====
        // (1) 周期モーフ（方式B）: 円周サンプリングで厳密周期。両位相に共通加算（共通モード＝分身に寄与しない）
        float2 cyc = float2(cos(6.28318530718 * time01), sin(6.28318530718 * time01));
        float n1 = fbm(p * kMorphScale1 + cyc * kMorphRadius) - 0.5;
        float n2 = fbm((p + float2(17.7, 41.3)) * kMorphScale2 + cyc * kMorphRadius) - 0.5;
        float2 micro = float2(n1, n2) * microWarpPx * att;

        // (2) 二相・中心対称ドリフト（方式C+D・レポートの (p-0.5) 形式・窓化なしの素の三角重み）
        float p1 = fract(time01);
        float p2 = fract(time01 + 0.5);
        float w1 = 1.0 - fabs(2.0 * p1 - 1.0);
        float w2 = 1.0 - w1;
        float2 uv1 = -flow * (p1 - 0.5) * att + micro;
        float2 uv2 = -flow * (p2 - 0.5) * att + micro;

        // (3) safeSample フォールバック: 変位後の参照先が変形安全領域(warpMask)外なら元画素へ
        float2 q1 = p + uv1;
        float4 c1 = (warpMask.sample(warpMask.transform(q1)).r < kWarpSafeThreshold)
            ? photo.sample(photo.transform(p)) : photo.sample(photo.transform(q1));
        float2 q2 = p + uv2;
        float4 c2 = (warpMask.sample(warpMask.transform(q2)).r < kWarpSafeThreshold)
            ? photo.sample(photo.transform(p)) : photo.sample(photo.transform(q2));
        c = c1 * w1 + c2 * w2;

        // ループ保証: p1/p2/cyc はすべて time01 の周期関数（fract/cos/sin）で構成され、
        // micro は cyc 経由で周期、warpMask は時不変（prepare 時に画像1回につき1回だけ生成・
        // フレームごとの再生成はしない）ため、c 全体が time01 の周期関数のまま
        // ＝ frame(0)≡frame(T) が数式レベルで保証される（既存のループ境界テストが担保する）。
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
