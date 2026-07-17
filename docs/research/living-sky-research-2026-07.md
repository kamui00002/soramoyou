# Living Sky 技術調査レポート

## 最終推奨

* 推奨するアニメーション方式：**方式C Flow map方式**を中心に、**方式B 周期ノイズによる微小UVワープ**と**方式D 複数サンプルの位相差ブレンド**を組み合わせるハイブリッド方式です。大域の流れは flow field で制御し、雲の形のわずかな変化は periodic noise / 4D noise で与え、ループ境界の隠蔽は half-phase の二重サンプルで行うのが、自然さ・ループ性・境界安全性・iPhone実装性のバランスが最も良いです。 citeturn22view2turn23view2turn24search2turn22view1
* 推奨するループ方式：**`phase = 2πt/T` を使う数学的周期化**を基本にし、局所変形は **sin/cos を 4D periodic noise の追加次元に入れて厳密周期化**、大域移動は **2本の位相差 0.5 の flow サンプリングを三角重みでブレンド**して、見た目の一方向移動を保ったままシームレス化します。単純な ping-pong や終端クロスフェードは補助策に留めるべきです。 citeturn24search2turn22view2turn7search21turn22view1
* 推奨するマスク処理：**SkyMaskProvider の生マスクをそのまま使わず**、`warpMask` と `compositeMask` を分離します。`warpMask` は erosion と edge-aware refinement 後の安全領域、`compositeMask` は見た目の自然さを保つための feather 済み合成用マスクです。さらに **距離変換 distance transform** を作って、境界に近づくほど変形量を 0 に落とします。 citeturn4search0turn4search1turn22view1turn20search0turn19search2
* 推奨するMetalパス構成：**前処理は複数パス、毎フレームは原則 1 パス**です。前処理でリサイズ・マスク補正・guided filter・distance transform を行い、プレビュー/書き出し本体は **同一の renderFrame 関数**で 1 枚の出力 `MTLTexture` に直接描画する構成が最も安全です。 citeturn15search3turn6search7turn35view1turn25view0
* 推奨するプレビュー構成：**MTKView** を使い、`drawableSize` に合わせた低〜中解像度のリアルタイム描画、既存編集画面のパイプラインを維持しつつ、**書き出しと同じシェーダー・同じパラメータ・同じ色変換**を使うべきです。 citeturn15search3turn15search27turn6search10
* 推奨する動画書き出し構成：**CVPixelBufferPool + CVMetalTextureCache + AVAssetWriterInputPixelBufferAdaptor** を使い、各フレームの `CVPixelBuffer` を Metal テクスチャ化して、そこへ **同じ renderFrame** を直接描画する方式です。MVP は **1080p / 30fps / H.264 / MP4 / SDR BT.709** を推奨し、HEVC は次段階で追加します。 citeturn1search13turn15search2turn6search3turn1search1turn2search22turn2search24
* MVPで採用する機能：**自動空マスクのみ、方向プリセット数種類、強度スライダー 1 本、ループ時間 3 段階、微小な光変化 On/Off、1080p H.264 書き出し**までに絞るのが妥当です。手動マスク修正、ユーザー編集 flow map、4K、HEVC、複雑な alpha matting は次版でよいです。 citeturn4search0turn4search1turn15search2turn1search1
* 採用しない方式と理由：**方式A 単純UVスクロール**は「写真を横にずらしただけ」に見えやすく、**方式E オプティカルフロー**は静止画1枚起点では不安定で occlusion 補完が重く、**方式G 生成AI動画化**は元写真らしさ・空以外を動かさない条件・完全オフライン条件と相性が悪いです。 citeturn22view3turn8search1turn8search2
* 実装難易度：**中〜やや高**です。Metal 自体は標準 API で完結できますが、難所は shader 本体より **マスク境界、安全な UV 参照、色管理、AVAssetWriter の安定化**です。 citeturn22view1turn4search0turn15search12turn16search14
* 最大の技術リスク：**空マスク境界の破綻**です。特に木の枝、電線、髪、ガラス、水面反射、山の稜線では、変形後 UV がマスク外画素を読んでしまうとハロー・はみ出し・色にじみが出ます。ここを防ぐには、**二重マスク・距離減衰・安全サンプル fallback** が必須です。 citeturn4search0turn4search1turn22view1turn19search2

## 方式比較と選定理由

以下の比較表は、Apple の Metal / AVFoundation 制約、guided filter と distance transform の性質、flow map の二重レイヤーによるループ隠蔽、periodic simplex / flow noise の周期化手法、そして静止画アニメーション系研究の失敗モードを踏まえた **Living Sky 向けの提案評価**です。スコアは「◎ 良い / ○ 実用 / △ 条件付き / × 不向き」で示しています。 citeturn22view2turn23view2turn24search2turn22view1turn22view3turn4search0turn4search1

| 方式 | 見た目の自然さ | ループの作りやすさ | 境界安全性 | 元写真の雲維持 | iPhone負荷 | 書き出し容易性 | 実装難易度 | メモリ | オフライン | 組み込みやすさ | MVP適性 | 拡張性 | Living Sky判定 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| A 単純UVスクロール | △ | ○ | △ | ◎ | ◎ | ◎ | ◎ | ◎ | ◎ | ◎ | ○ | △ | **不採用**。単調で「写真のスライド」に見えやすい |
| B 周期ノイズUVワープ | ○ | ◎ | △ | ○ | ○ | ○ | ○ | ◎ | ◎ | ◎ | ◎ | ○ | **採用要素あり**。ただし単独だとゴムっぽい |
| C Flow map | ◎ | ○ | ○ | ◎ | ○ | ○ | ○ | ○ | ◎ | ◎ | ○ | ◎ | **中核採用**。方向性と速度差を作りやすい |
| D 複数サンプルブレンド | ○ | ◎ | ○ | ○ | △ | ○ | ○ | △ | ◎ | ◎ | ○ | ◎ | **補助採用**。ループ境界を隠す要 |
| E オプティカルフロー | △ | △ | × | △ | × | △ | × | × | ○ | △ | × | ○ | **不採用**。静止画1枚起点では過剰 |
| F 雲/光オーバーレイ | ○ | ◎ | ◎ | × | ◎ | ◎ | ◎ | ○ | ◎ | ◎ | ◎ | ○ | **補助候補**。雲が少ない写真への保険 |
| G 生成AI動画化 | △〜◎ | ○ | × | × | ×〜△ | △ | × | × | ×〜△ | × | × | ○ | **不採用**。要件から外れる |

Living Sky では、「元写真らしさを保つ」「空以外は動かさない」「iPhone端末内で安定」「既存パイプライン変更最小」が最優先なので、最終的には **C + B + D** が最も噛み合います。F は「雲がほとんど無い空」でのみ次版の補助として有効ですが、MVP で強く入れると“元画像を動かした”というより“素材を被せた”印象になりやすいです。E と G は研究としては高度でも、Living Sky のプロダクト要件とはズレます。 citeturn22view2turn24search2turn22view3turn29view0turn29view1turn30view2

前回実装が失敗した可能性が高いのは、**B を単独で大きくかけた**ことです。周期ノイズだけで写真そのものを大きくワープすると、雲の移動ではなく「空の紙がぐにゃぐにゃ動く」見え方になります。逆に、flow field による大域移動を弱く入れ、そこへごく小さな periodic noise を足すと、雲の塊は保ったまま輪郭だけが少し変わる見え方に寄せられます。さらに二重位相ブレンドを足すと、ループ終端のリセットを視覚的に隠せます。 citeturn22view2turn23view2turn24search2turn22view1

## ループ設計とMetalシェーダー構成

### 周期ループの考え方

シームレスループの基本は、**時間そのものを円周上で扱う**ことです。  
ループ長を `T`、時刻を `t` とすると、まず

```text
phase = 2π * t / T
c = cos(phase)
s = sin(phase)
```

と置きます。`c` と `s` は `t = 0` と `t = T` で完全に同じ値に戻るので、これらをノイズ関数や強度関数の入力に使えば、**始点と終点の状態が数学的に一致**します。これは「最後だけクロスフェードする」より根本的に強い方法です。 citeturn24search2turn7search21

単純な `sin` だけで位置を動かすと、半周期で速度の向きが逆転します。  
たとえば `x(t)=A sin(2πt/T)` だと、速度 `dx/dt` は `cos` に比例するので、**雲が途中で折り返す**印象が出やすいです。これが ping-pong の不自然さの本質です。ping-pong は始点と終点の絵が一致しやすい一方で、端点または折り返し点で「進行方向の意思」が消えるため、空の流れとしては不自然になりやすいです。 citeturn24search2turn22view2

また、開始・終了フレームのクロスフェードだけでループを作ると、**位置・速度・局所形状が一致していなくても見た目だけ無理に継ぐ**ことになります。結果として、終端近くで雲が二重に見える、薄くなる、ゴーストが出る、明るさがにじむ、といった問題が起きます。クロスフェードは「最後の保険」としては有効ですが、Living Sky の中核方式には向きません。 citeturn23view2turn24search2

### Living Sky に最適なループ方式

Living Sky では、次の **二層ループ**が最も安全です。

**層ひとつ目**は、雲全体のゆっくりした流れを作る **flow-based advection**。  
**層ふたつ目**は、雲の輪郭変化を作る **4D periodic noise**。  
この二つを重ねます。 citeturn22view2turn24search2

#### 大域の流れ

Valve の flow map 手法では、2D flow vector を使って UV を流し、**位相を半周期ずらした 2 レイヤー**をブレンドしてリセットを隠しています。Living Sky でも、写真の空領域に対して同じ考え方を縮小して使えます。違うのは、水面の normal map ほど大きく流してはいけない点です。元写真はタイル可能ではないため、**変位量は小さく、境界減衰つき**が必須です。 citeturn22view2turn23view2

擬似コードは次の形が安全です。

```text
p  = fract(t / Tadv)
p2 = fract(p + 0.5)

w1 = 1 - abs(2*p  - 1)   // 三角波。0..1..0
w2 = 1 - w1              // 常に w1 + w2 = 1

uv1 = uv + flow(uv) * driftAmp * (p  - 0.5)
uv2 = uv + flow(uv) * driftAmp * (p2 - 0.5)

baseWarp = sample(src, uv1) * w1 + sample(src, uv2) * w2
```

この構成だと、各レイヤーの「リセット瞬間」を、もう片方が見えにくくしてくれます。Living Sky では `driftAmp` を水面シェーダーよりはるかに小さくし、後述の `distance attenuation` で境界・細線近傍を封じます。 citeturn23view2turn22view2

#### 局所の形の変化

雲の輪郭変化は、2D ノイズを時間で直接動かすより、**4D periodic noise** のほうが良いです。考え方は、

```text
n1 = noise4(uv * scale1, cos(phase) * r1, sin(phase) * r1)
n2 = noise4((uv + offset) * scale2, cos(phase) * r2, sin(phase) * r2)
micro = float2(n1, n2)
```

のように、`(cos phase, sin phase)` をノイズ関数の追加次元に入れる方法です。これでノイズ場そのものが完全に周期化されます。JCGT の tiling simplex / flow noise は、**strictly periodic** なループに向く設計で、4D を直接使わずとも、勾配回転による周期的な animated noise が 3D/2D で実装できることを示しています。Living Sky では、実装負荷と速度の観点から **2D UV + 円周位相入力** で十分です。 citeturn24search2turn7search21

### 推奨Metalシェーダーの実体

Living Sky の本番フレームは、**1 フレーム 1 パス**で次を行う構成が最も安全です。

```text
input:
  srcTexture          // 元画像
  warpMaskTexture     // 侵食済み安全マスク
  compositeMaskTexture// 合成用マスク
  distanceTexture     // 境界からの距離
  params              // phase, direction, strengths...

per pixel:
  mComp = sample(compositeMask, uv)
  if mComp <= tiny:
      return src(uv)

  d = sample(distanceTex, uv)
  atten = smoothstep(edgeStartPx, edgeFullPx, d)

  phase = 2π * t / T
  cyc = float2(cos(phase), sin(phase))

  // flow field
  dir0 = normalize(userDirection)
  lp = periodicNoise4(uv * lowFreqScale, cyc * loopRadius1)
  hp = periodicNoise4((uv+17.7) * highFreqScale, cyc * loopRadius2)
  flowDir = normalize(dir0 + perp(dir0) * flowBend * lp)

  // dual-phase advection
  p1 = fract(t / advectPeriod)
  p2 = fract(p1 + 0.5)
  w1 = 1 - abs(2*p1 - 1)
  w2 = 1 - w1

  micro = float2(lp, hp) * microWarpAmp * atten
  uv1 = uv + flowDir * driftAmp * (p1 - 0.5) * atten + micro
  uv2 = uv + flowDir * driftAmp * (p2 - 0.5) * atten + micro

  c1 = safeSample(src, warpMask, uv, uv1)
  c2 = safeSample(src, warpMask, uv, uv2)

  skyColor = c1 * w1 + c2 * w2

  // subtle lighting
  lumN = periodicNoise4(uv * lightScale, cyc * loopRadius3)
  gain = 1 + lightAmp * atten * lumN
  skyColor.rgb *= gain

  out = mix(src(uv), skyColor, mComp)
  return out
```

ここで重要なのは、**`safeSample()` が変形後 UV の安全性を必ず検査する**ことです。  
`uv'` が画像外なら元画像へ fallback、`warpMask(uv')` が閾値未満でも元画像へ fallback にします。これをやらないと、建物の縁・葉先・電線で必ず破綻します。 citeturn31search0turn31search3turn31search1turn4search0turn22view1

### 推奨パラメータ

以下は **MVP の初期値**です。絶対値より **画像短辺比** を優先してください。これは Apple API の制約ではなく、本調査に基づく実装提案です。

| パラメータ | 初期値 | 安全範囲 | 備考 |
|---|---:|---:|---|
| `driftAmp` | 短辺の **0.8%** | **0.4%〜1.8%** | 大域移動。大きすぎるとスライド感が出る |
| `microWarpAmp` | 短辺の **0.25%** | **0.1%〜0.6%** | 輪郭変化。大きいとゴム化 |
| `flowBend` | **0.20** | **0.10〜0.35** | 基本方向からの横揺れ |
| `lowFreqScale` | 空幅に **1〜2 波** | **0.5〜3 波** | 大きな雲塊のうねり |
| `highFreqScale` | 空幅に **5〜8 波** | **3〜10 波** | 微細変化。強すぎるとちらつく |
| `lightAmp` | **±1.2%** | **±0.5%〜±2.5%** | 青空は小さく、夕焼けでも ±3% 以内推奨 |
| `loopDuration` | **4.5s** | **3s / 4.5s / 6s** | MVP は3段階で十分 |
| `advectPeriod` | **loopDuration と同一** | 同一固定推奨 | 初版は分離しない方が安全 |
| `maskFeather` | 短辺の **0.6%** | **0.3%〜1.2%** | 合成用マスク |
| `warpErode` | 短辺の **0.5%** | **0.3%〜1.0%** | 変形用マスクの安全余白 |
| `edgeFullPx` | **8〜20 px** 相当 | 画像解像度依存 | 距離テクスチャで 1 に達する距離 |

青空だけの画像では、`microWarpAmp` を下げ、`lightAmp` を主役にした方が自然です。逆に雲が多い写真では `lightAmp` を下げ、`driftAmp` と `microWarpAmp` を少し上げた方が良いです。サンプリングモードは、**元画像は `clampToEdge`、生成ノイズや flow texture は `repeat` または `mirrorRepeat`** が基本です。 `repeat` は分数部だけを使って反対側へ回り込み、`mirrorRepeat` は -1..1 範囲で鏡像反転するので、繰り返し素材の境界がやや目立ちにくい場面があります。 citeturn31search3turn31search1turn6search0turn31search0

## マスク境界と SkyMaskProvider 連携

### 生マスクをそのまま使ってはいけない理由

SkyMaskProvider が返すマスクは、機能的には十分でも、**そのまま変形用マスクとして使うには危険**です。特に木の枝、葉、電線、髪、ガラス、山の稜線では、「見た目の境界」と「変形後に安全に参照できる領域」が一致しません。生マスクの境界まで強く動かすと、変形後 UV がマスク外の建物色や木の色を読んで、ハロー、にじみ、はみ出しが出ます。 citeturn4search0turn4search1turn19search2turn22view1

guided filter は、入力画像をガイドにして **エッジを保ちながら平滑化・構造転写**でき、matting / feathering に向くことが原論文でも示されています。Apple も `MPSImageGuidedFilter` を提供しており、iOS 上で edge-aware filtering を実装できます。Living Sky では、単純 Gaussian blur より guided filter を優先すべきです。blur だけだと空と建物の境界をまたいでマスクがにじみ、まさに前回の「建物周辺のハロー」が起きやすくなります。 citeturn22view1turn4search1

### 推奨する二重マスク構成

最も安全なのは、**変形用マスクと合成用マスクを分離**することです。

| テクスチャ | 役割 | 作り方 | 使い方 |
|---|---|---|---|
| `rawMask` | SkyMaskProvider 元出力 | 既存 provider の出力 | 保存用、再生成基準 |
| `refinedMask` | edge-aware 補正済み | guided filter / bilateral 相当の edge-aware 処理 | 以降のベース |
| `warpMask` | 変形してよい安全領域 | `refinedMask` を erosion、必要に応じて軽い blur | UV 安全判定と変形強度 |
| `compositeMask` | 最終合成用 | `refinedMask` を微小 feather | `mix(original, animated, compositeMask)` |
| `distanceTex` | 境界からの距離 | `warpMask` に EDT | 境界減衰 |

この構成だと、「見た目としては境界ギリギリまで空だが、変形自体は少し内側で止める」ができます。Living Sky ではこれが本質です。**空を動かす**ことより、**空以外を決して壊さない**ことが重要だからです。 citeturn4search0turn4search1turn22view1

具体式はこうです。

```text
atten = smoothstep(edgeStartPx, edgeFullPx, distanceTex(uv))
effectiveWarp = userStrength * atten
```

`distanceTex` が小さい、すなわち境界近傍では `atten ≈ 0` となるので、境界の雲はほぼ動かず、マスク中心部でのみしっかり動きます。これは単に `mask * strength` とするよりずっと安全です。Euclidean distance transform は image processing の基本手法であり、Apple には `MPSImageEuclideanDistanceTransform` が用意されています。 citeturn4search0turn19search3turn19search20

### 技術ごとの使い分け

**feather / blur** は最終合成の見た目を柔らげるために使います。  
**erosion** は「この内側なら動かしてよい」という安全余白を作るために使います。  
**dilation** は mask holes の補修で使えますが、Living Sky では拡げすぎると危険です。  
**guided filter / bilateral** は境界に沿って mask を整えるために使います。  
**alpha matting** は細い枝・髪・半透明ガラスに効きますが、MVP では重いので optional にすべきです。 citeturn22view1turn20search0turn19search2turn19search15

この中で **MVP に必須**なのは、  
**erosion + light feather + guided filter + distance transform** です。  
**alpha matting** は V2 以降の高難度改善枠です。深い matting 研究は有効ですが、モデル導入・品質検証・処理時間のコストが高いからです。 citeturn19search2turn19search15turn4search1

### SkyMaskProvider との安全な連携方法

これは **事実の列挙ではなく、Living Sky 向けの設計提案**です。

推奨 API 契約は、次のような `SkyMaskBundle` を 1 回だけ作る形です。

```text
SkyMaskBundle
- imageExtentOriginal
- imageExtentWorking
- orientationNormalized
- rawMaskTexture (R8Unorm)
- warpMaskTexture (R8Unorm)
- compositeMaskTexture (R8Unorm)
- distanceTexture (R16Float or R32Float)
- skyCoverageRatio
- validationState
```

ポイントは次の三つです。

まず、**画像とマスクの座標空間を必ず正規化**します。  
EXIF orientation を画像だけ直して mask は未補正、という状態は非常に危険です。画像選択→マスク生成→編集→書き出しのどの段階でも、向き・crop・resize が同じ写像になるよう固定してください。 citeturn15search3turn6search7

次に、**provider を毎フレーム呼ばない**ことです。mask は画像・crop・回転が変わった時だけ生成し、以降は Metal テクスチャとして再利用します。毎フレーム生成は遅いだけでなく、mask のゆらぎで境界ちらつきを生みます。 citeturn15search3turn16search4

最後に、**空領域が小さい、細密境界が多い、confidence が低い**場合は Living Sky を自動的に弱める、または無効化するルールを入れるべきです。これは UX 上も重要です。木の枝だらけの写真や水面反射が多い写真に無理に適用すると、失敗率が急上昇します。これは本調査に基づく提案です。 citeturn19search2turn4search1turn4search0

## プレビューと動画書き出しの設計

### プレビューと書き出しを一致させる設計

Living Sky で最も避けたいのは、**「プレビュー専用シェーダー」と「書き出し専用シェーダー」が別物になること**です。  
これを避けるには、描画 API を次のように統一します。

```text
renderFrame(
  commandBuffer,
  destinationTexture,
  sourceTexture,
  warpMaskTexture,
  compositeMaskTexture,
  distanceTexture,
  renderSettings,
  timeSeconds
)
```

プレビューでは `destinationTexture = currentDrawable.texture`、  
書き出しでは `destinationTexture = textureFromCVPixelBuffer` にするだけです。  
つまり、**違うのは出力先だけ**で、ロジックは同一にします。 `MTKView` は標準の Metal-aware view で、iOS 画面描画に向きます。 `CVMetalTexture` / `CVMetalTextureCache` は pixel buffer を Metal texture として使うための正式 API です。 citeturn15search3turn15search27turn6search3turn1search13

この構成の利点は、結果一致だけではありません。  
レンダラーのテストも簡単になります。1 枚の `MTLTexture` に出すテストさえ作れば、プレビューも export も同じ結果になるからです。GitHub の `MetalOfflineRecording` は、**offscreen rendering + AVFoundation recording** を組み合わせる最小実装の参考として有用です。 citeturn35view1

### 動画書き出しの推奨構成

Apple 公式には `AVAssetWriterInputPixelBufferAdaptor`、`CVPixelBufferPool`、`CVMetalTextureCache` が揃っており、**CVPixelBuffer を再利用しながら Metal で直接描画**する構成が取れます。Living Sky ではこれが最も自然です。GPU から CPU の readback を避けやすく、writer 側にもそのまま渡せるからです。 citeturn1search13turn15search2turn15search26turn6search3

MVP の推奨は次の通りです。

| 項目 | MVP推奨 | 理由 |
|---|---|---|
| コンテナ | MP4 | 要件に合い、扱いやすい |
| コーデック | H.264 | 実装上の想定外を減らしやすい |
| 解像度 | 1080p 上限 | 品質とメモリのバランス |
| FPS | 30 | 空の微細 motion には十分 |
| 色空間 | SDR / BT.709 タグ | プレビュー差異を抑えやすい |
| alpha | 不使用 | 最終動画は通常不要 |
| pixel format | `kCVPixelFormatType_32BGRA` | writer / texture bridge が扱いやすい |

Apple は video settings で color properties を明示でき、特定解像度向け color properties の設定例では **BT.709 の color primary / transfer / matrix** を使っています。MVP ではここに揃えるのが安全です。HEVC も AVFoundation で選択できますが、Living Sky 初版では H.264 で運用を安定させるべきです。 citeturn2search19turn2search22turn2search24

### 色と明るさが変わる問題の対策

前回の「動画書き出し時に色や明るさが変わる」問題は、かなりの確率で **色空間と premultiplication の不一致**です。  
主な原因は次の四つです。

ひとつ目は、**入力画像が Display P3、プレビューは sRGB、書き出しは無タグ BGRA** のように、作業空間が揃っていないこと。Apple は `CGColorSpace` と AVFoundation の color properties を別々に扱うため、ここが曖昧だとズレます。 citeturn2search22turn2search20turn2search26

ふたつ目は、**sRGB / linear のどちらでブレンドするかが統一されていないこと**です。複数サンプルのブレンドと明るさ変化は、できれば線形光空間寄りで扱った方が不自然な暗化を避けやすいです。これは Apple が Living Sky 用に明言しているわけではありませんが、画像合成の一般原則として妥当です。Working color space は **linearized sRGB 系**に固定し、最後に export 用へ変換するのが安全です。関連 API と color space 定義は Apple が提供しています。 citeturn2search20turn18search6turn18search0

みっつ目は、**premultiplied alpha の扱いがバラバラ**なことです。最終動画は alpha 不要でも、中間段階で Core Image や別テクスチャと混ぜると、premultiplied / straight alpha の混在で色縁が変わることがあります。MVP では alpha 付き中間合成を最小限にし、最終 render pass で不透明 BGRA に落とすのが安全です。 citeturn18search0turn18search8

よっつ目は、**プレビューと書き出しで別の露出補正式**を入れてしまうことです。これは設計の問題なので、前述の「同じ renderFrame に統一」で根治します。 citeturn15search3turn1search13

### AVAssetWriter とメモリ安定化

`AVAssetWriter` は、`startWriting()` の失敗時や `finishWriting()` 後の status / error を必ず確認すべきです。Apple も、成功可否は `status` と `error` を見るよう案内しています。Living Sky のような offline export では、**フレームを急ぎすぎるより 1 枚ずつ確実に処理**する方が安定します。 citeturn15search20turn15search0turn15search4

MVP の export ループは、次のように **直列・同期寄り**で十分です。

1. pixel buffer pool から 1 枚取得  
2. `CVMetalTextureCacheCreateTextureFromImage` で destination texture 化  
3. `renderFrame()` を destination へ実行  
4. `commandBuffer.commit()`  
5. `waitUntilCompleted()`  
6. 完了後に adaptor へ append  
7. 次フレームへ

`waitUntilCompleted()` はスループット最適ではありませんが、MVP では **buffer 再利用・GPU/CPU 同期・writer 失敗原因の切り分け**が圧倒的にやりやすくなります。将来は `addCompletedHandler()` と複数 inflight buffer に拡張できます。 citeturn16search14turn16search3

また、Metal の描画ループは `autoreleasepool` に包むべきです。Apple の Best Practices Guide と `CAMetalLayer` ドキュメントは、drawables / rendering loop を `autoreleasepool` で管理することを勧めています。使い終わった pixel buffer は pool に戻り、export 終了時には `CVPixelBufferPoolFlush`、必要なら `CIContext.clearCaches()` を行うと後処理が安定します。 citeturn16search5turn16search13turn15search22turn18search3

## 類似アプリと参考実装

### 類似アプリ調査

以下は **2026年7月時点で取得できた App Store / 公式情報**を基に、Living Sky への関連性が高いものだけを絞った一覧です。内部実装方式は公開されていないため、**UI 挙動からの推測**は明示的にそう書いています。 citeturn29view0turn29view1turn29view2turn29view3turn29view4turn30view0turn30view1turn30view2

| アプリ | 開発元 | 対応OS | 2026年7月提供状況 | 料金 | 空/雲を動かせるか | 一部分だけ動かせるか | 自動/手動マスク | 方向指定 | 固定領域 | ループ | 書き出し | 解像度 | WM | レビュー不満の傾向 | Living Sky に応用できる点 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Motionleap | Lightricks | iPhone/iPad | 提供中 | 無料+IAP | 可能 | 可能 | 手動パス＋空置換あり | 可能 | Freezeあり | 可能 | 複数形式 | 明記なし | 条件付き | サブスク/AI寄りへ拡張した点が賛否の可能性。説明上は空置換・雲アニメ・アンカーが強い。 citeturn29view0turn14search0 | **手動パス・アンカー・空置換 UX** は参考になる |
| VIMAGE | ZipoApps | iPhone/iPad | 提供中 | 無料+IAP | 可能 | 可能 | AI sky + overlays | 一部可能 | 明記弱い | 動画/GIF可 | 動画/GIF | 高品質課金 | あり | watermark除去や高品質出力が課金要素。 citeturn29view1turn33search10 | **空差し替え＋オーバーレイ**。Living Sky では補助レイヤー発想だけ参考 |
| StoryZ | Andor Communications | iPhone/iPad | 提供中 | 無料+IAP | 可能 | 可能 | 手動方向ポインタ＋overlay、AIも強化 | 可能 | 一部可能 | 可能 | GIF/Video | 4K表記あり | 不明 | AI機能追加で用途が広がり、Living Sky 要件とはやや離れている。 citeturn29view2 | **方向ポインタUI** は参考。ただし機能過多 |
| PixaMotion | Imagix AI | iPhone中心 | 提供中 | 無料+IAP | 可能 | 可能 | 手動系中心 | 可能 | 一部可能 | ループ動画可 | ショート動画 | 明記弱い | 不明 | 典型的な motion photo 系。 citeturn29view3 | **MVP の最小機能感**を掴むのに有用 |
| Zoetropic | Zoemach Tecnologia | iPhone/iPad | 提供中 | サブスク系 | 自動空変更あり | 可能 | motion points + stabilize/mask | 可能 | 可能 | 動画化 | video | 不明 | 不明 | 更新履歴が 2021 表示で停滞気味に見える。 citeturn29view4 | **motion points + stabilize** の基本設計が参考 |
| PLOTAVERSE | PLOTAGRAPH | iPhone/iPad/Mac(Apple Silicon) | 提供中 | 無料+IAP/Remove Watermark | 可能 | 可能 | スワイプ系＋素材 | 可能 | 一部可能 | ループ作成志向 | 動画系 | 不明 | あり | 過去レビューでは黒画面・課金・再課金不満。 citeturn30view0turn10search10 | **写真一部アニメの大衆的 UX** の参考 |
| Werble | Horsie in the Hedge | iPhone/iPad/visionOS | 提供中 | 無料+IAP | 主にエフェクトとして可能 | 可能 | レイヤーマスク | 方向というよりエフェクト選択 | 可能 | ループ/GIF強い | GIF/Video | 不明 | 一部あり | エフェクトレイヤー型。公式 tutorial で mask tool を案内。 citeturn32view0turn30view1turn33search13 | **レイヤー合成型のマスク UX** が参考 |
| Cinemagraph Pro | Flixel | iPhone/iPad | 提供中 | 無料+IAP | 直接の空特化ではない | 可能 | Live Masking | 動画由来なので方向指定というより trim | 可能 | repeat / bounce / crossfade | 4K, ProRes など | 4K表記あり | 大きい | 価格・watermark不満が多い。近年は 60fps / upscale / ProRes 追加。 citeturn30view2turn32view3turn32view5turn14search7turn14search3 | **ループ編集 UX と export 機能** は強く参考になる |

ここから分かるのは、既存の人気アプリの多くが **「手動で方向を描く」「アンカーで固定する」「素材/空置換を使う」** という UX を採っていることです。一方、Living Sky は「空マスクが既にあり、空だけを控えめに自然に動かす」ので、彼らよりも **UI はむしろシンプル** にできます。参考にすべきなのは“機能量”ではなく、**方向プリセット・固定思想・ループ可視化**です。 citeturn29view0turn29view1turn29view2turn30view2

### GitHub と技術資料の取捨選択

以下は Living Sky に実際に役立つものだけを残した表です。  
**直接流用向き**と**考え方だけ参考**を分けています。更新時期は、取得できた範囲では主に **最新 release / 公開ページの日付 / 取得時点の page metadata** を使っています。公開ページから直近コミット日が取れない場合は、その旨を明記しています。 citeturn25view0turn25view1turn25view2turn25view4turn35view0turn35view1

| リソース | 種別 | 言語/枠組み | 更新目安 | Stars等 | ライセンス | 商用利用 | iOS | Metal | 直接流用 | 発想参考 | 関連度 | コメント |
|---|---|---|---|---:|---|---|---|---|---|---|---|---|
| MetalPetal | GitHub | Swift / Metal | 最新 release 2023-02-21 | 2.2k | LICENSEあり | 条件次第で可 | 可 | 可 | **高** | 高 | **高** | 実運用向け画像/video framework。CPU/GPU/メモリ効率を明示。 citeturn25view0turn26view0turn34search0 |
| MetalPetal/VideoIO | GitHub | Swift / AVFoundation | 最新 release 2022-02-21 | 190 | MIT | 可 | 可 | 間接的に可 | **中** | 高 | **高** | AVMutableVideoComposition / async handler の実例。export 周辺の参考価値が高い。 citeturn25view4turn26view4 |
| GPUImage3 | GitHub | Swift / Metal | 公開ページで直近 commit 日不明 | 2.9k | BSD-3-Clause | 可 | 可 | 可 | **中** | 高 | 中 | 基盤としては優秀だが Living Sky 専用にはやや大きい。 citeturn25view1 |
| BBMetalImage | GitHub | Swift / Metal | release なし、公開ページで直近日不明 | 1k | MIT | 可 | 可 | 可 | **中** | 高 | 中 | video writer, Metal view など揃う。低メモリ志向の説明あり。 citeturn25view2turn26view2 |
| MetalOfflineRecording | GitHub | Swift / Metal / AVFoundation | 2018 サンプル相当 | 37 | MIT | 可 | 可 | 可 | **中** | 高 | **高** | offscreen Metal → recording の最小実装。古いが考え方は有効。 citeturn35view1 |
| metal-experiments | GitHub | Metal 79% / Swift 21% | 2026-07-05 | 1 | LICENSE表記取得不可 | 不明 | 可 | 可 | 低 | **高** | 中 | domain-warped fbm など effect ごとの読み物として良い。実製品土台には弱い。 citeturn13search17turn35view0 |
| Apple `MPSImageGuidedFilter` | 公式Doc | MPS | 現行API | - | Apple API | 可 | 可 | 可 | **高** | 高 | **高** | mask edge-aware refinement の第一候補。 citeturn4search1 |
| Apple `MPSImageEuclideanDistanceTransform` | 公式Doc | MPS | 現行API | - | Apple API | 可 | 可 | 可 | **高** | 高 | **高** | distance attenuation 実装の中核。 citeturn4search0 |
| Valve flow map SIGGRAPH 2010 | 技術資料 | shader theory | 2010 | - | 発表資料 | 参考のみ | 概念は可 | 可 | 低 | **非常に高い** | **高** | 二重位相ブレンドと pulsing/repetition 対策が Living Sky に直結。 citeturn22view2turn23view2 |
| JCGT tiling simplex / flow noise | 論文 | noise theory | 2022 | - | 論文 | 参考実装可 | 可 | 可 | 中 | **非常に高い** | **高** | periodic noise の数学基盤として最重要。 citeturn24search2 |

結論として、**フレームワーク土台は MetalPetal / VideoIO を読む価値が高い**ですが、Living Sky 自体は既存パイプラインに合わせた **小さな専用レンダラー**で作る方が良いです。  
つまり、**「全部載せのフレームワークを採用」ではなく、必要な設計だけ借りる**のが正解です。 citeturn25view0turn25view4turn35view1

## MVP範囲、失敗診断、実装手順

### 推奨アーキテクチャ

#### 入力

* 元画像
* 空マスク
* ユーザー設定

#### 前処理

* 画像リサイズ  
  * プレビュー用 working size  
  * 書き出し用 target size
* マスク調整  
  * threshold 正規化  
  * guided filter による edge-aware 補正  
  * `warpMask = erode(refinedMask)`  
  * `compositeMask = feather(refinedMask)`
* 距離情報の生成  
  * `distanceTex = EDT(warpMask)`
* 必要な中間テクスチャ  
  * source / warpMask / compositeMask / distanceTex  
  * optional: flow seed texture または procedural constants

前処理は **画像が変わった時だけ**行い、毎フレーム生成してはいけません。特に mask refinement と distance transform は再利用前提です。 citeturn4search0turn4search1turn15search2

#### Metalレンダリング

毎フレーム本体は 1 パス推奨です。

1. 元画像読み込み  
2. 境界距離に応じた変形強度 `atten` を計算  
3. 周期 flow による大域 UV 変形  
4. periodic noise による微小 UV 変形  
5. half-phase 二重サンプリングをブレンド  
6. 空領域だけの微小な光変化  
7. 元画像との安全な合成  
8. 出力テクスチャ生成

**前処理は複数パス、毎フレームは 1 パス**が Living Sky に最も合っています。パスを細かく分けすぎると export と preview のズレ源が増えるからです。 citeturn4search0turn4search1turn35view1

#### プレビュー

* 表示：`MTKView`
* 解像度：画面に合わせた downscaled working resolution
* FPS：30 を基本、余裕があれば 60
* 品質設定：  
  * preview は noise octave 数を 1 段減らしてもよい  
  * ただし shader ロジック自体は同じにする

#### 動画書き出し

* オフスクリーンレンダリング：`CVPixelBuffer -> CVMetalTexture -> destinationTexture`
* 解像度：MVP は 1080p
* FPS：30
* 形式：H.264 / MP4
* 色空間：SDR / BT.709 tag
* フレーム生成：`for frame in 0..<N { t = frame / fps }`

#### キャッシュ

* 再利用すべきもの  
  * `MTLRenderPipelineState`  
  * `MTLSamplerState`  
  * mask textures  
  * distance texture  
  * `CVPixelBufferPool`  
  * `CVMetalTextureCache`
* 毎フレーム生成してはいけないもの  
  * guided filter 結果  
  * EDT 結果  
  * command queue  
  * pipeline states
* 解放  
  * export 完了後に `CVPixelBufferPoolFlush`  
  * Core Image を併用したら `CIContext.clearCaches()`  
  * draw/export loop は `autoreleasepool` で囲む

citeturn15search2turn15search22turn18search3turn16search5turn16search13

### MVPで入れるものと、次版へ回すもの

**MVPに入れるもの**

* 自動空マスクの利用
* 方向プリセット  
  * 右  
  * 左  
  * 右上  
  * 左上
* 強度スライダー 1 本
* ループ時間 3 段階  
  * 3秒  
  * 4.5秒  
  * 6秒
* 微小な光変化 On/Off
* 1080p / 30fps / H.264 / MP4
* 既存編集画面への最小追加
* プレビューと書き出し共通レンダラー

**次版に回すもの**

* 手動マスク修正
* 手動 flow edit
* 雲が少ない写真向け overlay cloud layer
* HEVC
* 4K export
* 高度な alpha matting
* 画像ごとの自動パラメータ最適化
* 反射水面やガラス越し空の特別処理

この切り分けが重要です。MVP の価値は「派手さ」ではなく、**破綻しない自然さ**にあります。 citeturn4search0turn4search1turn1search13turn2search24

### 失敗原因の診断表

以下は、本調査の設計提案を症状別に整理した **実装診断表**です。 citeturn22view1turn23view2turn4search0turn4search1turn15search12

| 症状 | 主な原因 | 確認方法 | 修正方法 |
|---|---|---|---|
| 雲がゴムのように伸びる | `microWarpAmp` が大きすぎる / flow の divergence が強い / 1サンプルだけで大きくワープ | strength を半分以下に落として比較。大域移動を切ると改善するか確認 | 周期ノイズを微小化、flow 主体へ変更、二重サンプルブレンド追加 |
| 建物周辺にハローが出る | 生マスクをそのまま使用 / blur が境界を跨ぐ / `uv'` がマスク外参照 | 境界に false color で `warpMask`, `compositeMask`, `uv' validity` を表示 | erosion 済み `warpMask` 導入、guided filter、safeSample fallback |
| ループ境界で飛ぶ | 非周期ノイズ / 終端で状態不一致 / リセットを隠していない | `t=0` と `t=T` の同一座標差分を見る | `phase=2πt/T` 化、4D periodic noise、half-phase 二重ブレンド |
| 画像端が引き伸ばされる | `clampToEdge` で大きく外を読んでいる / 変位過大 | UV を可視化し、0..1 の外へ出る割合を確認 | 変位削減、画像端距離減衰、必要なら sky 領域だけ事前 pad |
| 雲の輪郭がちらつく | 高周波ノイズ過多 / mask 境界の時間ゆらぎ / サブピクセル揺れ | highFreq 成分をOFFにして比較 | 高周波成分を弱める、preview/export 共通化、mask は毎フレーム再生成しない |
| プレビューと書き出しが違う | 別シェーダー / 別パラメータ / 別色変換 | 同じ時刻 frame を静止画比較 | `renderFrame` を完全共通化、出力先だけ差し替える |
| 動画の色が変わる | color space / transfer / premultiplied alpha 不一致 | プレビューと export frame を histogram 比較 | working space 固定、BT.709 tag 明示、不要 alpha を削減 |
| 書き出しが遅い | 毎フレーム CPU readback / mask 再計算 / 過剰同期 | Time Profiler / Metal System Trace | pixel buffer へ直接描画、前処理キャッシュ、MVP は 1080p 30fps |
| メモリ不足になる | pixel buffer を解放していない / temporary texture を都度生成 | Allocations / memory graph | pixel buffer pool 再利用、cache flush、autoreleasepool |
| AVAssetWriter が失敗する | `startWriting`/`finishWriting` の状態未確認 / append タイミング不正 / buffer 再利用競合 | writer.status / writer.error ログ | 直列 export、`waitUntilCompleted()` 後 append、失敗時に状態を必ず出す |

### 実装担当AIへ渡せる段階的な作業手順

以下は **一度に大改造しない**ための手順です。各段階で「次へ進んでよい条件」を明確にしています。これは Living Sky 向けの実装計画提案です。 citeturn15search3turn4search0turn4search1turn1search13

#### 段階ごとの実装計画

| 段階 | 変更目的 | 変更対象 | 完了条件 | テスト方法 | 起こり得る問題 | 次へ進んでよい判断基準 |
|---|---|---|---|---|---|---|
| 現在表示の確認 | 座標系・向きの土台確認 | 画像表示、maskオーバーレイ | 画像と mask が完全に重なる | 向き違い画像で確認 | EXIFずれ | 1px単位で重なって見える |
| マスク合成のみ実装 | pipeline 差分最小で安全確認 | `mix(src, tintedSky, mask)` | 空だけが色付き、地上は不変 | 境界拡大表示 | 向き・cropずれ | 破綻なく合成できる |
| 一定UV移動 | 最小の motion 実装 | 空中心部のみ `uv + const` | 動くが地上は不変 | strength 0.2%〜0.5% 比較 | スライド感 | mask 中心部のみ安全に動く |
| 境界減衰 | ハロー防止の本命 | erosion + distanceTex | 境界で motion が自然に減る | 境界 false color 可視化 | 減衰不足 | 建物・山ににじまない |
| 周期パラメータ | ループ検証の開始 | `phase = 2πt/T` | `t=0` と `t=T` が一致 | 差分画像比較 | 終端ジャンプ | 数学的に一致する |
| 二重位相ブレンド | リセット視認性の低下 | `uv1/uv2` + weight | 終端の飛びが見えにくい | ループ再生目視 | ghosting | 1 Loop を 5 回見ても違和感が少ない |
| periodic noise 追加 | 雲の微小変形 | 4D periodic noise | 単調さが減る | macro/micro ON/OFF 比較 | ゴム化 | 変化は増えたが破綻なし |
| 光変化追加 | 青空/夕焼け対応 | sky-only luminance gain | 点滅でなく呼吸感 | flicker 検査 | 明滅過大 | ±2% 以内で自然 |
| 前処理パス追加 | 生マスク依存を脱却 | guided filter / EDT | 枝・電線の破綻減少 | 難画像セット評価 | 前処理時間増 | 品質向上が明確 |
| オフスクリーン描画 | export 共有基盤 | destination を texture 化 | preview と同じ関数で描ける | 1 frame export compare | 色差 | 同一 frame が一致 |
| 低解像度 export | writer 安定化 | pixel buffer pool / writer | 720p が安定書き出し | 30秒連続 export | writer failed | 失敗率 0 |
| 1080p 対応 | MVP 到達 | export settings | 1080p/30fps 完走 | 複数画像で実機試験 | メモリ増 | 実用速度で完走 |
| 最適化 | 実用品質へ | cache / pool / sync | UI が滑らか | Instruments | メモリリーク | 連続使用でも安定 |

### 次に実装担当AIへ渡すべき指示

以下は、そのままコピーして使える **実装指示テンプレート**です。

```text
Living Sky 実装指示

目的:
既存の画像選択・SkyMaskProvider・編集画面の流れを維持しつつ、
「空だけを自然に動かすループ動画」を iPhone 上で安定実装する。

最優先:
1. 空以外は動かさない
2. 境界破綻を出さない
3. プレビューと書き出しを同一レンダラーで一致させる
4. MVP は 1080p / 30fps / H.264 / MP4 に限定する

実装方針:
- 前処理:
  - 入力画像と空マスクの orientation / crop / scale を完全一致させる
  - mask を guided filter で edge-aware に整える
  - warpMask = refinedMask を erosion した安全領域
  - compositeMask = refinedMask を軽く feather した合成領域
  - distanceTex = warpMask の Euclidean distance transform
- 毎フレーム描画:
  - renderFrame(destinationTexture, sourceTexture, warpMask, compositeMask, distanceTex, settings, time)
  - phase = 2π * time / duration
  - flow field による弱い大域移動
  - 4D periodic noise による微小UV変形
  - half-phase をずらした 2 サンプルを三角重みでブレンド
  - sky-only の微小 brightness variation を追加
  - final = mix(original, animatedSky, compositeMask)
- 安全条件:
  - 変形後 UV が画像外なら original に fallback
  - 変形後 UV の warpMask 値が閾値未満でも original に fallback
  - distanceTex で境界近傍の変形量を 0 に近づける
- プレビュー:
  - MTKView を使う
  - shader ロジックは export と完全共有
- 書き出し:
  - CVPixelBufferPool + CVMetalTextureCache + AVAssetWriterInputPixelBufferAdaptor
  - pixelBuffer-backed texture に renderFrame を直接描画
  - MVP は serial export とし、各 frame で commandBuffer.waitUntilCompleted() 後に append
- 初期パラメータ:
  - driftAmp = 短辺の 0.8%
  - microWarpAmp = 短辺の 0.25%
  - lightAmp = ±1.2%
  - durations = [3.0, 4.5, 6.0]
- 検証順:
  1. mask overlay 一致確認
  2. static mask compositing
  3. constant UV shift
  4. edge attenuation
  5. exact periodic phase
  6. dual-phase blend
  7. periodic noise
  8. light variation
  9. offscreen render
  10. 720p export
  11. 1080p export
  12. Instruments で最適化

禁止事項:
- 生マスクをそのまま変形用に使わない
- プレビュー専用 shader と export 専用 shader を分けない
- 初期段階で optical flow / 生成AI / 4K / 手動flow編集に進まない
- 境界 fallback なしで warped UV を元画像から直接読む実装にしない

完了条件:
- 難画像（木の枝・電線・山の稜線）でハローが目立たない
- 5回連続ループ再生でもループ境界が大きく気にならない
- preview と export の1フレーム比較で見た目差が実質ない
- 1080p / 30fps / H.264 / MP4 が安定して完走する
```

## 総括

Living Sky に最適なのは、**「空マスク内で写真を大きく歪ませる」ことではなく、「安全領域の中で、ごく弱い大域流れと微小形状変化を足す」こと**です。  
そのための実装上の答えは、**Flow map 的な方向制御 + periodic noise + dual-phase blend + 二重マスク + distance attenuation + 共通 renderer** です。これなら、前回の失敗要因だった「ゴムっぽい変形」「境界ハロー」「ループの飛び」「preview/export 不一致」「writer 不安定」を、すべて個別に潰せます。 citeturn22view2turn23view2turn24search2turn4search0turn4search1turn1search13turn15search12

逆に言うと、Living Sky の成否は shader の派手さでは決まりません。  
決め手は、**マスク境界をどう守るか**、**ループを数学的にどう閉じるか**、**preview と export をどれだけ同一化できるか**です。ここを正しく作れば、MVP でも十分に商品価値のある「控えめで自然な空のアニメーション」に到達できます。 citeturn22view1turn24search2turn15search3turn1search13