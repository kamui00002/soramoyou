# Living Sky 設計書 ⭐️

静止画の空を Metal でループアニメーション化する機能（雲の流れ＋光のゆらぎ→mp4 書き出し）。
SNS 拡散の武器。地上は一切動かさず、空領域だけを自然に動かす。

> 作成: 2026-07-12（設計: Fable 本体／実装: implementer Sonnet 委譲・段階2以降）
> Done条件: ①空だけが自然に動くループ生成 ②継ぎ目のないループ ③mp4書き出し ④SkyMaskProvider 使用 ⑤プレビューがカクつかない

---

## 1. 全体アーキテクチャ（新規ファイルのみ・既存パイプライン不変更）

```
[編集確定後の写真 CIImage]──┐
                            ├─→ LivingSkyEngine.makeFrame(time:) ──→ CIImage（1フレーム）
[SkyMask（1回だけ生成）]────┘        │ 内部: general CIKernel 1パス
                                     ├─→ プレビュー: MTKView + CIRenderDestination（30fps）
                                     └─→ 書き出し: AVAssetWriter → mp4（ループ1周）
```

| 新規ファイル | 置き場所 | 役割 |
|---|---|---|
| `LivingSky.metal` | `Rendering/Shaders/` | general CIKernel 1個（変位＋シマー＋マスク合成を1パス） |
| `LivingSkyEngine.swift` | `Rendering/LivingSky/` | kernel ロード（MetalShaderPipeline と同イディオム: metallib data→CIKernel、失敗時 nil）・`makeFrame(time:) -> CIImage` |
| `LivingSkyParameters.swift` | `Rendering/LivingSky/` | 風向き・速さ・雲量（変位振幅）・シマー強度・ループ長 T・品質モード |
| `LivingSkyPreviewView.swift` | `Views/` | MTKView（30fps）プレビュー |
| `LivingSkyVideoExporter.swift` | `Rendering/LivingSky/` | AVAssetWriter で mp4 書き出し＋Photos 保存 |

**触らないもの**: `FilterGraphBuilder`／`EditRecipe`／`MetalShaderPipeline`／既存27ツール経路。
metal-shader-dev skill の統合チェックリスト 2〜4（FilterGraphBuilder/EditRecipe/EditViewModel 統合）は
**編集ツール向けなので今回は適用外**。適用するのは 1（kernel ロード。ただし自前 Engine 内）と
5（.metal がビルドフェーズに入るか確認）のみ。

- **入力**は編集確定後の final 画像（既存パイプラインの出力を受け取るだけ）
- **マスク**は `SkyMaskProviderProtocol.makeSkyMask(for:quality:)` を**画像につき1回**生成してキャッシュ
  （フレームごとに再生成しない。プレビュー=`.preview`／書き出し=`.export`）
- **Metal 必須**: kernel ロード失敗時はフォールバックせず機能を非表示（アニメーションに CIFilter 代替は非現実的）

---

## 2. 動きの数式

### 2.1 雲の流れ — フロー変位＋二相クロスフェード（ループの核）

静止画アニメの定石（Plotagraph 系／ゲームの水面フローマップと同方式）。
写真の空部分を風向きに UV 変位させ続けると伸び切ってしまうため、**2つの位相を交互にリセットしながら
クロスフェード**する。

- 位相: `φ1 = frac(t/T)`、`φ2 = frac(t/T + 0.5)`（T = ループ長、既定 8 秒）
- 変位ベクトル: `d(p, φ) = A · m(p)^k · F(p) · φ`
  - `A` = 最大変位（**幅の最大8%/ループ（speed 1.0時）**。旧値「画像幅の0.5〜1.5%」は実装後の
    段階3 vision レビューで「雲が動いていない」と判定された際に判明した知覚下限（約3px/秒）未満で
    不可視だったため改定した。二相クロスフェードの加重平均位相 `phi1·(1-w)+phi2·w` が全時刻で
    0.5 に恒等的に固定される構造のため、知覚できる動きは実質「各位相コピーが A px/秒で滑る」分
    だけに限られ、旧係数は1080px・speed=0.5で約1px/秒相当しかなかった（`LivingSkyParameters.
    maxDisplacementPx` 参照）。これ以上大きくするとゴム状に伸びて破綻する上限は引き続き有効
  - `m(p)` = フェザー済みマスク値（0=地上, 1=空）。`^k`（k≈2）で**境界ほど動きを減衰**→地上を引っ張らない
  - `F(p)` = 風向き単位ベクトル × 速度ゆらぎ `(1 + 0.3·(fbm(p·s) − 0.5))`（一様な流れに有機的ムラを付与）
- 2サンプル: `c1 = photo(p − d(p,φ1))`、`c2 = photo(p − d(p,φ2))`
- 合成: `c = mix(c1, c2, w)`、`w = |2·frac(t/T) − 1|`

**継ぎ目なしの証明**: φ1 がリセット（1→0 のジャンプ）する瞬間 `frac=0` では `w=1`（c2 側 100%）、
φ2 のリセット瞬間 `frac=0.5` では `w=0`（c1 側 100%）——**各位相はウェイトが 0 の瞬間にだけリセット**
されるため視覚的に不可視。全項が `frac(t/T)` の関数なので `frame(0) ≡ frame(T)`、ループは構造的に保証。

既知のトレードオフ: `w=0.5` 付近でクロスフェードにより微かにソフトになる「呼吸」が出る
→ A を小さく・T を長く（8s）して知覚下に沈める。段階3の vision レビューで確認。

### 2.2 光のゆらぎ — 円周サンプリングによる周期ノイズ

輝度をノイズでゆっくり揺らす。時間項を**ノイズ空間の円周上**に置くことで周期性を構造的に保証する:

- `η(p, t) = fbm(p·s_shimmer + r·(cos(2πt/T), sin(2πt/T)))` — t が一周すると引数が同一点に戻る＝周期的
- 輝度ゲイン: `L(p,t) = 1 + a_shimmer · m(p) · (η(p,t) − 0.5)`（`a_shimmer` ≈ 0.05、ごく控えめ）
- v1 は輝度のみ（色温度シフトは v2 候補）。マスク乗算済みなので地上の明るさは不変

### 2.3 ノイズ実装

シェーダ内 inline の hash ベース value noise + fbm 2〜3 オクターブ（テクスチャ不要・1パス維持）。
乱数テクスチャ持ち込みは v1 ではしない（`Date.now` 等の非決定要素も不要、完全決定的＝テスト可能）。

### 2.4 最終合成（地上静止の保証）

`c_final = mix(photo(p), c_animated·L(p,t), m_feathered(p))`
`m=0`（地上）なら**元画素そのまま**が数式レベルで保証される。

**マスク再マップ（段階3 vision レビュー指摘#3）**: ヒューリスティックマスクは樹冠・樹間に
0.4〜0.6 の中間値を与えることがあり、`m^k`（k=2）減衰だけでは動きが残って地上がゆらいで見える不具合が
あった。マスクをサンプルした直後に `m = smoothstep(0.45, 0.75, m)` で再マップし、0.45 未満の漏れを
完全にゼロへ落とす（コア空域=0.75以上は1.0のまま、境界のグラデーションは0.45〜0.75帯で維持）。
下限は当初0.30で導入したが、樹冠・樹間の0.4〜0.6帯を通過してしまいゴースト状スミアが残存したため
0.45へ引き上げた（地平線ぎわの晴天域は0.7以上のため上限0.75への引き上げの影響はない）。
早期return判定（m<0.001）はこの再マップ後の値で行う。

---

## 3. Metal シェーダ構成

- **general CIKernel 1個**に全処理を入れる（GPU 1パス・グラフ最浅）
  - ⚠️ 既存 `ExposureContrast.metal` は**色カーネル**（`sample_t` 受け取り・1画素完結）。
    Living Sky は変位先の画素を読むため **`coreimage::sampler` を受け取る general kernel**。
    テンプレのコピペ不可。`extern "C" float4 livingSky(coreimage::sampler photo, coreimage::sampler mask, float time01, float2 flowDir, float maxDispPx, float shimmerAmp, float speedJitterScale, coreimage::destination dest)` 形
- **ROI コールバックが最重要レビューポイント**: 変位サンプリングするため
  `roiCallback = { _, rect in rect.insetBy(dx: -(maxDispPx+1), dy: -(maxDispPx+1)) }`。
  ExposureContrast の `{ _, rect in rect }` を流用すると**端に未定義画素が出る**
- コンパイル検証: metal-shader-dev skill の `xcrun metal -c -target air64-apple-ios18.0 -fcikernel ...`
- マスクのフェザー: 生成時に一度だけ CIGaussianBlur（**clamp→blur→crop の定石**・SkyReplacementCompositor
  の feather と同様）でソフト化してから kernel に渡す
- **photo は `clampedToExtent()` してから kernel に渡す（段階3 vision レビュー指摘#2）**: 風上側
  （風向き0°なら画像左端）で `p - flow*φ` が extent 外をサンプルすると sampler が透明を返し、
  黒い滲みが常時出る不具合があった。端の画素を外側へ引き伸ばす clamp の定石を適用して解消する
  （`extent:` に渡す出力範囲自体は元の photo.extent のまま変えない）。

---

## 4. プレビュー（Done⑤: カクつかない）

- `MTKView`（`preferredFramesPerSecond = 30`）＋ `CIRenderDestination` で
  `CIContextPool.shared.ciContext` から直接描画（毎フレームの CGImage/UIImage 変換ゼロ）
- ソースは**長辺 1080 に事前縮小した CIImage**（マスクも同スケール・1回生成でキャッシュ）
- パラメータ変更（風向き・速さ等）は uniform 変更のみ＝マスク再生成なし
- 予算感: 1080p・1パスカーネル・fbm 3オクターブ ×2（フロー用+シマー用）は A15 以降で余裕。
  実測は段階5で（Instruments / FPS 表示）

## 5. 動画書き出し（Done③）

- `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`、H.264 / mp4 / 30fps / 音声なし
- 長さ = **ループちょうど1周（T=8s, 240フレーム）**→ プレイヤーのループ再生で無限に繋がる
- 解像度: 長辺 1920 上限（SNS 向けサイズ・処理時間バランス。元がそれ以下なら原寸）
- 各フレーム `makeFrame(time:)` → `ciContext.render(_, to: pixelBuffer)`（CVPixelBufferPool 再利用）
- マスクは `.export` 品質で再生成（書き出し時のみ・1回）
- 保存先: Photos（`NSPhotoLibraryAddUsageDescription` 取得済み）。共有シートは v2
- 品質2モード: `preview`（1080/リアルタイム）／`export`（1920/オフライン全フレーム）
  — `SkyMaskQuality` の preview/export と1対1対応

**段階4-5 実測（2026-07-12・iPhone 17 Pro シミュレータ）**:
- 書き出し実測: 1920×1440・240フレーム・8.000秒ちょうど・12.5MB・キーフレーム1個（=ループ1周間隔が効いている）。書き出し所要 約20秒以内（シミュレータ。実機GPUではさらに速い見込み）
- ループ継ぎ目: 最終→先頭フレームの平均差 1.0/255（隣接フレーム基準の約2.8倍だが絶対値は知覚不能。
  差分の内訳は動きではなく **H.264 の P フレーム誤差蓄積がキーフレームで戻る「GOPドリフト」**。
  気になる場合はビットレート増 or GOP を半分（キーフレーム2個）にするトレードオフで調整可能）
- プレビュー: シミュレータで 30fps 動作・破綻なし（実機 Instruments 計測は実機テスト時の宿題）

## 6. パラメータ（v1 のユーザー可変項目）

| パラメータ | 既定 | 範囲 | 備考 |
|---|---|---|---|
| 風向き | 右（0°） | 8方位 or 自由角 | UI は段階2で最小限（スライダー/ダイヤル） |
| 速さ | 0.5 | 0.1〜1.0 | 「自然さ最優先」= 既定はゆっくり |
| 雲量（変位振幅A） | 4%幅/ループ（speed 0.5時） | 〜8%幅/ループ（speed 1.0時） | §2.1 の改定に追従（speed 連動・独立スライダーは v2 検討） |
| 光のゆらぎ | 0.05 | 0〜0.10 | 0 で無効 |
| ループ長 T | 8s | 6〜10s | 長いほど継ぎ目・呼吸が目立たない |

## 7. リスクと対策

| リスク | 対策 |
|---|---|
| 変位が大きいと空がゴム状に伸びる | A 上限 8%幅/ループ・既定ゆっくり。段階3 vision レビューで許容確認済み |
| クロスフェードの周期的ソフト化（呼吸） | T 8s で知覚下。目立てば 3 相化を検討（v2） |
| ヒューリスティックマスクの誤判定（地上がゆらぐ） | 変位のマスク減衰 `m^k`＋フェザー＋smoothstep(0.45,0.75)再マップ（§2.4）。⚠️**既知の限界**: 樹冠まわりに微細なゴーストが残る（マスク値0.5〜0.65帯）。根治は CoreML マスク（`SkyMaskProviderProtocol` の差し替えで対応可能）。`SkyMask.confidence` 低時は警告表示 |
| ROI 設定ミスで端にゴミ | 段階2レビューの最重点項目（§3） |
| 夕焼けグラデーションで変位が色ズレに見える | A 小で許容想定。段階3で夕焼け実写を必ず含めて確認 |
| 動画の再エンコードで継ぎ目が滲む | 書き出しはキーフレーム間隔をループ長に合わせる（実装時調整） |

## 8. 段階計画（ユーザー指定に対応）

| 段階 | 内容 | 担当 |
|---|---|---|
| 1 | 本設計書 → **承認待ち** | Fable |
| 2 | シェーダ＋Engine＋簡易プレビューのプロトタイプ（空だけ動く） | implementer(Sonnet) 実装 → Fable diff レビュー |
| 3 | プレビュー出力を Fable が vision で確認（境界にじみ・速度・光の破綻）→ 修正委譲 | Fable 目視 → Sonnet 修正 |
| 4 | ループ継ぎ目の実機確認＋mp4 書き出し実装 | Sonnet → Fable レビュー |
| 5 | 性能実測・品質2モード仕上げ | Sonnet → Fable レビュー |
