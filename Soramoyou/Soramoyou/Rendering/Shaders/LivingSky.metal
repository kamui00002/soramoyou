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
/// v3（軌道うねり）用の位相・半径ノイズと、シマー用の輝度ゆらぎ（§2.2）の両方で共用する。
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

// MARK: - v8: タイル化ノイズ（雲ベール用）
//
// 上の hash21/valueNoise/fbm は非周期（座標をそのままハッシュするため、平行移動すると
// 別の値になる）。雲ベールのスクロールを「1ループでちょうど整数×周期分だけ進める」ことで
// 継ぎ目なしループにするには、スクロールする軸（u軸）の格子座標だけを周期 P で折り返す
// （mod）タイル化版の hash/value noise/fbm が必要（出典:
// docs/research/living-sky-research-2026-07-part2-synthesis.md「v8（B2案）設計メモ」）。
//
// ⚠️ v8.1（2026-07-17 シミュレータ実写QA指摘）: 当初は u軸・v軸の両方を周期 period で
//    タイル化していたが、これだと格子点の組み合わせが period×period 通り（period=4.0なら
//    4×4=16通り）しか存在せず、実質1〜数種類の同一ブロブが縦横に格子状に反復して見える
//    不具合が実写QAで判明した。ループ整合に必要なのはスクロールする u 軸だけ（v 軸は
//    スクロールしないため周期性は不要）なので、v 軸（＝y格子）は通常の非タイル hash に戻し、
//    u 軸（＝x格子）だけを period で折り返す非対称タイル化にする。関数名の "U" は
//    「u軸のみタイル化」を表す。

/// x格子（u軸・スクロール軸）だけを周期 period で折り返し、y格子（v軸）は折り返さない
/// 非対称タイル化 hash。fmod は負値で符号付き余りを返すため、+period してから再度 fmod して
/// 0...period に正規化する（x側のみ）。y側は period を無視して i.y をそのまま使う
/// （＝通常の非タイル hash と同じ挙動）。
static inline float hashTileableU(float2 i, float period) {
    float wx = fmod(fmod(i.x, period) + period, period);
    return hash21(float2(wx, i.y));
}

/// タイル化 value noise（u軸のみ）: 格子4隅のハッシュを x軸だけ周期 period で折り返してから
/// 補間する。p.x を period の整数倍だけ平行移動しても同じ場を返す（= u軸方向のみ周期
/// period の周期関数）。p.y 方向は折り返さないため、通常の非周期ノイズと同様に
/// 平行移動すると別の値になる（＝縦方向に同一ブロブが格子状反復しない）。
static inline float tileableValueNoiseU(float2 p, float period) {
    float2 i = floor(p);
    float2 f = fract(p);

    float a = hashTileableU(i, period);
    float b = hashTileableU(i + float2(1.0, 0.0), period);
    float c = hashTileableU(i + float2(0.0, 1.0), period);
    float d = hashTileableU(i + float2(1.0, 1.0), period);

    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// タイル化 fbm 2オクターブ（u軸のみ）。オクターブごとに座標を2倍にする際、周期 period も
/// 2倍にすることで「p.x を period の整数倍だけ平行移動しても不変」という性質をオクターブ間
/// で保つ（座標2倍・周期2倍が連動しているため、シフト量も自動的に新しい周期の整数倍になる）。
/// この period 連動倍増は hashTileableU 内で x軸（u軸）にのみ効くため、周期不変性も
/// u 軸方向のみに成立する（v 軸は非タイルのまま）。
static inline float tileableFbm2U(float2 p, float period) {
    float value = 0.0;
    float amplitude = 0.5;
    float per = period;
    for (int i = 0; i < 2; i++) {
        value += amplitude * tileableValueNoiseU(p, per);
        p *= 2.0;
        per *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

// MARK: - Living Sky カーネル本体

// v8: 雲ベールのパラメータ（マジックナンバー回避）。
// 出典: docs/research/living-sky-research-2026-07-part2-synthesis.md「v8（B2案）設計メモ」。
// kVeilScale1 / kVeilScale2: 雲ベールの空間スケール（ノイズ空間の1単位あたりの画面px の逆数。
//   つまり1セルの画面幅px = 1/scale）。層1(kVeilScale1)=大きな雲塊、層2(kVeilScale2・約2倍
//   細かい)=細かい流れ、の役割分担で2層パララックスを作る。
//   ⚠️ 速度の関係式: 1ループあたりのドリフト距離(px) = kVeilPeriod / scale（scrollUnitが
//   ノイズ空間でkVeilPeriod進むのに対し、1ノイズ空間単位=1/scale画面pxのため）。
//   初期値0.004/0.009だと層1だけで 4.0/0.004=1000px/ループ（T=6s・k=1で毎秒167px）と
//   速すぎる誤りがあったため、2026-07-17 テスト結果を受けて再較正: kVeilScale1=0.016
//   （1セル=62.5px・250px/ループ＝毎秒約42px @T=6s,k=1）、kVeilScale2=0.032（1セル=31.25px・
//   層2はk=2倍速のため毎秒約83px・層1とのパララックス比は維持）。
// kVeilPeriod / kVeilPeriodB: タイル周期（ノイズ格子のセル数）。スクロール量をこの整数倍に
//   することでループ境界での場の不連続をゼロにする（下の livingSky 本体 v8 ブロックの
//   ループ保証コメント参照）。
//   ⚠️ v8.1（2026-07-17 シミュレータ実写QA指摘）: 単一周期 kVeilPeriod=4.0 だけだと、
//   空間的な反復周期がそのまま4セル（kVeilScale1=0.016なら4/0.016=250px）になり、
//   画面内に同じブロブが何度も反復する模様が目視できた。互いに素な2周期
//   kVeilPeriod(4.0) と kVeilPeriodB(5.0) の場をそれぞれ独立にスクロールして平均する
//   ことで、実質の空間反復周期を LCM(4,5)=20セル（同条件で20/0.016=1250px）まで
//   引き伸ばす。プレビュー作業解像度（長辺1080px。設計書§4）を超えるため反復は
//   視界に収まらず実質不可視になる。副作用として、速度比4:5の2場が独立に動くことで
//   ベール自身がゆっくり形を変えながら流れる（望ましい副作用）。
//   ループ整合はスクロールされる場ごとに独立して厳密成立する（下の livingSky 本体
//   v8 ブロックのループ保証コメント参照）。
// kVeilLo / kVeilHi: 密度→不透明度変換の smoothstep しきい値。ベタ曇りにせず「雲の塊」感を
//   出すための閾値帯。2026-07-17 テスト結果を受けて0.45/0.75→0.40/0.70へ緩和（コントラスト
//   引き伸ばし後の veil 分布に合わせた再較正）。v8.1 の2周期平均化で veil の分散はやや
//   縮小する（独立に近い2場を平均するとサンプル平均の性質で分散が縮む）が、Monte Carlo
//   検証（実装レポート参照）では T/4 ループ差分テストの合格マージンが十分大きいまま
//   だったため、kVeilLo/Hi はこの変更単体では再調整不要と判断した（下の livingSky 本体
//   v8 ブロックのコメント・実装レポート「迷った点」も参照）。
#define kVeilScale1 0.016
#define kVeilScale2 0.032
#define kVeilPeriod 4.0
#define kVeilPeriodB 5.0
#define kVeilLo 0.40
#define kVeilHi 0.70

// v3: 軌道うねり方式のパラメータ（マジックナンバー回避）。
// kPhaseNoiseScale: 周回位相 ph(p) を場所ごとにばらつかせる fbm の空間スケール（粗め＝
//   隣接画素は似た位相を持ちつつ、離れた場所では周回タイミングがずれる）。
// kRadiusNoiseScale: 軌道半径を場所ごとにばらつかせる fbm の空間スケール。
// kOrbitRadiusRatio: 軌道半径 = 最大変位px × この係数（0.5 → 約±4%幅・ピーク速度
//   2πR/T ≈ 23px/s で明確に視認可能）。
#define kPhaseNoiseScale 0.006
#define kRadiusNoiseScale 0.01
#define kOrbitRadiusRatio 0.5

/// 静止画の空領域はワープせず、上に雲ベール（v8）または軌道うねり変位（v3・比較用）を重ねる
/// general CIKernel。
///
/// - Parameters:
///   - photo: 編集済み写真（v3 分岐は変位先の画素を読むため sampler として受け取る）
///   - mask: フェザー済み空マスク＝合成用マスク compositeMask（グレースケール・rチャンネルを
///     使用。1.0=空 / 0.0=地上）。最終合成 `mix(base, c, m)` の重みに使う
///   - time01: `frac(経過時間 / ループ長T)` の 0...1 値（ループの位相）
///   - flowDirPxX: 風向き単位ベクトル × ドリフト振幅px の X 成分（ワーキング座標系。Swift 側で事前計算）。
///     v8 は方向（normalize）だけを使い、v3 は大きさ（length）も使う（下記 v3 ブロック参照）
///   - flowDirPxY: 風向き単位ベクトル × ドリフト振幅px の Y 成分
///   - motionModel: 動きモデル切替。0.5未満=v8タイル化ノイズ雲ベール（既定）／それ以外=v3軌道うねり
///     （比較用）。`LivingSkyParameters.motionModel` の Int(0/1) をそのまま Float へキャストして渡す
///   - veilIntensity: v8 雲ベールの不透明度係数 0...1（「雲の量」スライダー）
///   - veilColR / veilColG / veilColB: v8 雲ベールの色（写真の空平均色を明側に寄せた値。Swift
///     `LivingSkyEngine.prepare` で1回だけ計測）
///   - speedPeriods: v8 雲ベールのスクロール速度＝1ループあたりのタイル周期数（k）。
///     **整数値のみ渡される前提**（ループ整合。下記 v8 ブロックのループ保証コメント参照）
///   - shimmerAmp: 光のゆらぎ振幅 0...0.1
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
///    （引数は sampler/float スカラーのみにする方針は v8 でも踏襲している）。
extern "C" float4 livingSky(
    coreimage::sampler photo,
    coreimage::sampler mask,
    float time01,
    float flowDirPxX,
    float flowDirPxY,
    float motionModel,
    float veilIntensity,
    float veilColR,
    float veilColG,
    float veilColB,
    float speedPeriods,
    float shimmerAmp,
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
    // 「生きてる感」を出そうとしていたことだと判明した。v7（レポート準拠ハイブリッド）はドリフトを
    // 短辺の0.8%へ縮小し、微小モーフ＋光のゆらぎを主役にする方針へ転換したが、TestFlight実機評価
    // （2026-07-17）で「振動してるようにしか見えない」との最終NGを受けた。第2次 Deep Research
    // （docs/research/living-sky-research-2026-07-part2-synthesis.md）により
    // ①ピクセルワープでの可視ドリフトは知覚科学的に不可能（Braddick 1971: 融合限界≈画面3pt。
    // 「見える速度」と「融合する分身幅」は原理的に両立不可）②商用製品の答えは実写/手続き的な
    // 雲オーバーレイの重ね合わせ、と確定したため、v8 は方針を根本転換する: **写真は一切ワープ
    // せず**、上に自前生成の雲ベール（タイル化ノイズ）を風向きへスクロールして重ねる
    // （詳細は下記 v8 ブロック）。これにより v4〜v7 が抱えていた分身・巻き戻り・振動・
    // 電線/電柱の破綻は構造的に存在しなくなる。motionModel=0=ドリフト系の実装差し替えであり、
    // 新しい motionModel 値は追加していない（v3「軌道うねり」は比較用に不変更のまま残る）。
    float4 c;
    if (motionModel < 0.5) {
        // ===== v8: タイル化ノイズ雲ベールのオーバーレイ（写真は不変・ドリフトはベール側） =====
        // 出典: docs/research/living-sky-research-2026-07-part2-synthesis.md
        //   「v8（B2案）設計メモ」（採用方針=B案「雲オーバーレイ」）。
        // 原理: タイル化ノイズ（u軸格子座標を周期 P で mod）を風向きへ
        //   offset = fract(time01) * P * speedPeriods * k（k=層ごとの周期数）でスクロールする。
        //   speedPeriods は整数値のみ渡される前提（Swift 側 speedQuantize 参照）のため、
        //   1ループの総移動量は常に P の整数倍になる。写真を一切ワープしないため、v4〜v7 が
        //   抱えていた分身・巻き戻り・振動・電線/電柱の破綻（上記コメント参照）は構造的に
        //   存在しない。
        // v8.1（2026-07-17 シミュレータ実写QA指摘）: 単一周期だけだと空間反復が目視できたため、
        //   互いに素な2周期 kVeilPeriod(4.0)・kVeilPeriodB(5.0) の場を層ごとに独立にスクロール
        //   して平均する（各層 d1a/d1b、d2a/d2b。定数コメント参照）。

        float2 windDir = (length(flowDirPx) > 1e-6) ? normalize(flowDirPx) : float2(1.0, 0.0);
        float2 perpDir = float2(-windDir.y, windDir.x);

        // 層1: 大きな雲塊。セル座標系 u=風向き軸・v=直交軸に回転してから u 軸だけをスクロール
        // する（v はスクロールしない＝風向きに直交する動きは出さない）。u1/v1 自体はスクロール
        // 量を含まない基準座標（2周期それぞれの scrollUnit を後段で個別に加算するため）。
        float u1 = dot(p, windDir) * kVeilScale1;
        float v1 = dot(p, perpDir) * kVeilScale1;

        // fract(time01) は t=0/T でともに0（Swift 側の time01 計算で保証済み）。
        // P・speedPeriods（整数）を掛けた scrollUnit だけスクロールすると、1ループの総移動量が
        // 常に P の整数倍になる（下のループ保証コメント参照）。層1は k=1（speedPeriods倍速）。
        float scrollUnit4L1 = fract(time01) * kVeilPeriod * speedPeriods;
        float scrollUnit5L1 = fract(time01) * kVeilPeriodB * speedPeriods;
        float d1a = tileableFbm2U(float2(u1 + scrollUnit4L1, v1), kVeilPeriod);
        float d1b = tileableFbm2U(float2(u1 + scrollUnit5L1, v1), kVeilPeriodB);
        float d1 = 0.5 * (d1a + d1b);

        // 層2: 細かい流れ（k=2周期/ループ＝層1の2倍速のパララックス）。kVeilScale2 は層1より
        // 細かいセル。seedオフセット(+37.7等)は時不変の定数のため周期性に影響しない
        // （固定シフトはループ整合の証明と無関係——制約が要るのは時間項にのみ）。
        float u2 = dot(p, windDir) * kVeilScale2 + 37.7;
        float v2 = dot(p, perpDir) * kVeilScale2 + 91.3;
        float scrollUnit4L2 = fract(time01) * kVeilPeriod * speedPeriods * 2.0;
        float scrollUnit5L2 = fract(time01) * kVeilPeriodB * speedPeriods * 2.0;
        float d2a = tileableFbm2U(float2(u2 + scrollUnit4L2, v2), kVeilPeriod);
        float d2b = tileableFbm2U(float2(u2 + scrollUnit5L2, v2), kVeilPeriodB);
        float d2 = 0.5 * (d2a + d2b);

        float veil = 0.65 * d1 + 0.35 * d2;

        // 2026-07-17 テスト結果を受けたコントラスト引き伸ばし: fbm は複数オクターブの加重和
        // であるため中心極限定理的に 0.5 付近へ値が集中し、分散が圧縮される（=雲塊の濃淡が
        // 出にくく、smoothstep(0.45,0.75) 帯域ではほぼ常に alpha≈0 になっていた）。
        // 0.5 を中心に 1.8 倍へ引き伸ばして分散圧縮を補正し、雲塊のコントラストを出す。
        veil = clamp((veil - 0.5) * 1.8 + 0.5, 0.0, 1.0);

        // 密度→不透明度: しきい値付き smoothstep で「雲の塊」感を出す（ベタ曇りにしない）。
        // ⚠️ m は掛けない: 下部の最終合成 `mix(base, c, m)`（v3 分岐も共有する既存構造・不変更）
        //    が既にマスクで補間するため、ここでも m を掛けると境界で m^2 の二重減衰になってしまう。
        float alpha = smoothstep(kVeilLo, kVeilHi, veil) * veilIntensity;

        // 色: Swift から渡る veilColR/G/B（写真の空平均色を明側に寄せた色）。screen 合成
        // （元の空・雲は下に透けたまま明るく重なる）。
        float3 veilRGB = float3(veilColR, veilColG, veilColB);
        c = photo.sample(photo.transform(p));
        c.rgb = c.rgb + (1.0 - c.rgb) * veilRGB * alpha;

        // ループ保証: scrollUnit4L1/scrollUnit5L1/scrollUnit4L2/scrollUnit5L2 はいずれも
        // fract(time01)（t=0/Tでともに0）に「その場自身の周期（kVeilPeriod または
        // kVeilPeriodB）× speedPeriods（整数）× 層の速度倍率（層1=1・層2=2）」を掛けた値
        // のため、1ループの総移動量は常にその場自身の周期の整数倍になる——4本の scrollUnit
        // それぞれが独立にこの性質を満たす。tileableFbm2U は入力座標を period の整数倍だけ
        // 平行移動しても不変（オクターブごとに座標とperiodを連動して2倍にしているため、
        // この不変性はオクターブ間で伝播する——tileableFbm2U の定義コメント参照）ため、
        // d1a/d1b/d2a/d2b の4項それぞれが time01 の周期関数のまま、その加重平均・加算で
        // 構成される veil、ひいては c 全体も time01 の周期関数のまま＝
        // frame(0)≡frame(T) が数式レベルで保証される（既存のループ境界テストが担保する）。
        // 写真自体は一切参照座標をずらしていない（photo.sample は常に p のまま）ため、
        // この保証は warpMask/safeSample のような補助機構を必要としない。
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
