# 📘 コードレビュー 2026-04-22 — 画像編集パイプライン改善ブランチ

| 項目 | 内容 |
|---|---|
| 対象ブランチ | `機能-画像編集パイプライン改善` |
| base / head | `main` … PR #7 (17 commits, 99 files, +8,371 / −1,264) |
| 主要対象 | `Soramoyou/Rendering/` / `Persistence/PhotoKitAdapter.swift` / `Persistence/RecipeStore.swift` / `ViewModels/EditViewModel.swift` / `ViewModels/EditHistoryManager.swift` / `Views/EditView.swift` / `Views/ToneCurveView.swift` / `Services/ImageService.swift` / `Services/StorageService.swift` + 関連テスト |
| レビュー方針 | アーキテクチャ・正確性・スレッドセーフ・パフォーマンス・テストカバレッジ |

---

## 0. 総評（Executive Summary）

Phase 0〜Phase 2 の一連の改修で、非破壊編集 (`EditRecipe`) とレンダパイプライン (`FilterGraphBuilder` / `PreviewRenderer` / `CIContextPool`) の骨格は明確に整理された。HEIF10 / HDR / ACES トーンマップ / Metal シェーダー / EDR 表示 まで押さえており、MVP としては十分な品質。

一方で **「旧 API（`ImageService.applyEditTool`）と新 API（`FilterGraphBuilder`）が並走し、数値的に乖離している」** という構造的な負債が残っており、放置するとスライダー調整の意図通りの値がテストとプロダクションで食い違う事故につながる。本レビューの最重要指摘は H1 と H2 の 2 件で、この 2 つを解決すると「スライダーで効かないツール問題」の半分も同時に解消する。

サマリカウント:

| Severity | 件数 |
|---|---|
| High   | 3 |
| Medium | 8 |
| Low    | 10 |
| 合計   | 21 |

---

## 1. 指摘一覧（Findings）

### 🔴 High

#### H1. `ImageService.processEditTool` と `FilterGraphBuilder` の挙動が数値レベルで乖離している

| 項目 | 値 |
|---|---|
| 対象 | `Soramoyou/Services/ImageService.swift:208-639`, `Soramoyou/Rendering/FilterGraphBuilder.swift` 全体 |
| 分類 | アーキテクチャ / 正確性 |

`applyEditTool(_:value:to:)` から呼ばれる `processEditTool` は 27 ツール分の完全な独自実装を保持しており、同名ツールで FilterGraphBuilder と係数が別物になっている。主なズレ:

| ツール | `ImageService`（旧） | `FilterGraphBuilder`（新） |
|---|---|---|
| `clarity(+)` | `radius=10.0`, `intensity=v*1.0` | `radius=v*0.8+0.01`, `intensity=v*0.5` |
| `texture(+)` | `radius=2.0`, `intensity=v*1.5` | `radius=v*3.0`, `intensity=v*1.0` |
| `whiteBalance` | `neutral(6500+v*2000, v*30)` | `targetNeutral(6500+v*1000, 0)` |
| `colorTemperature` | `±3000K` | `±1500K` |
| `grain` | `additionCompositing` + R/G/B mono | `overlayBlendMode` + random + midGray（B7 fix） |
| `highlight(+)` | `highlightAmount=1+v`（CI 仕様で 1.0 頭打ち） | `highlightAmount=1+hlNorm`（B1 で正値も効くよう補正） |

**何が問題か**:
- 実機のスライダー編集（プレビュー）は `FilterGraphBuilder` 経路、`ImageServiceTests` は `applyEditTool` 経路を叩いているため、**テストが全部パスしても挙動保証にならない**。
- 将来、別画面（例: バッチ処理・プリセット）で `applyEditTool` を呼ぶコードを書いた瞬間、ユーザーが見た結果と違う値が焼き込まれる。
- さらに `FilterGraphBuilder` 側で `B3〜B6` の修正（負値で `gaussianBlur` にフォールバックする等）を入れたが、旧 `processEditTool` には反映されていない。

**推奨対応**:
1. `ImageService.applyEditTool(_:value:to:)` / `processEditTool` / `applyExposure`〜`applyDoubleExposure` の 27 メソッドを全削除。
2. `applyEditTool` 呼び出し側は `applyEditRecipe(_:to:)` に統一（`EditRecipe(legacy:)` でラップ）。
3. `ImageServiceTests` の `applyEditTool` 依存テスト（約 300 行）を `FilterGraphBuilderTests.swift` に統合。プレビュー挙動とテストが常に同一経路を通るようにする。

---

#### H2. リアルタイムプレビューが `toneCurvePoints` と `targetDynamicRange` を毎操作ごとに破壊している

| 項目 | 値 |
|---|---|
| 対象 | `Soramoyou/ViewModels/EditViewModel.swift`（`editSettings` computed property / `setToolValueRealtime` / `renderFastPreviewOrAsync`）, `Soramoyou/Services/ImageService.swift:694-700` |
| 分類 | 正確性 / UX バグ |

前回のスライダー調査で特定済み「隣接バグ」の本丸。

1. `EditViewModel.editSettings` は `set` 側で `editRecipe = EditRecipe(from: newValue)` と **EditRecipe を全置換**する。
2. `EditSettings` に存在しない `toneCurvePoints` / `targetDynamicRange` が毎回 nil に戻る。
3. `renderFastPreviewOrAsync` は `generatePreviewFromCIImage(lowResCIImage, edits: editSettings)` を叩く。ここでも内部で `EditRecipe(from:)` が再実行され、二重脱落。

**既に用意済みの正しい API を使っていないのが本質**:
`ImageService` には既に `generatePreviewFromCIImage(_:recipe:)` と `applyEditRecipe(_:to:)` が存在する。`EditViewModel` 側でこちらに切り替えるだけでトーンカーブが「他のスライダーを動かした瞬間に消える」バグは消える。

**推奨対応**:
- `EditViewModel.renderFastPreviewOrAsync` の中で `imageService.generatePreviewFromCIImage(lowResCIImage, recipe: editRecipe)` を使うよう差し替え。
- スライダー駆動の内部状態を `EditRecipe` に直接書き込む形にリファクタし、`editSettings` computed property はレガシー互換の read-only に格下げ（書込みは廃止）。
- 回帰テスト: 「ExposureValue 変更 → ToneCurve 編集 → Brightness 変更 → ToneCurve が保たれる」ケースを `EditViewModelTests` に追加。

---

#### H3. 複数ツールがスライダー両端まで振ってもプレビュー上ほぼ変化しない

| 項目 | 値 |
|---|---|
| 対象 | `Soramoyou/Rendering/FilterGraphBuilder.swift` 全域 |
| 分類 | UX バグ / 仕様との乖離 |
| 参照 | 前回レポート（チャット内）で調査済み |

振っても見えないツールの主因は 3 種類:

| 分類 | 具体例 | 根拠 |
|---|---|---|
| 係数が極端に弱い | `clarity(+)`（unsharpMask radius が 0.41px @ v=+0.5, 人間の可視下限以下）, `highlight(+)`（+7.5% lift）, `whiteBalance`（±1000K @ max は白熱灯〜昼光の差より小さい）, `fade`（±5〜10% RGB offset）, `tint`（±100 @ max） | 数値計算根拠は `EditRecipe.init(from:)` 変換係数 + `applyXxx` 内の比率 |
| プレビュー解像度で潰れる | `grain`, `texture(+)`, `noiseReduction(+)` | 750×750 px での 1〜2 px の細密効果は平均化されて消える |
| 仕様で片側 no-op | `noiseReduction(-)` は guard で弾いている | `FilterGraphBuilder.applyNoiseReduction` |

**推奨対応**:
- 各ツールの「意図された振幅」を `docs/ui-spec.md` に明記し、その振幅になるよう係数を見直す（Lightroom 基準で +100 は大体 ±2 stop 相当）。
- プレビュー解像度依存のツール（grain / texture / noiseReduction）はフル解像度への書き出し時のみ強度を上げる段階調整を検討、または「プレビューで効きが弱い」旨のヒントを UI に表示。
- `noiseReduction(-)` は「仕様として無効」なら UI 側でスライダーを 0...1 に制限、「両方向対応」なら負値でボックスフィルタ等の意図的ノイズ付加を入れる。

---

### 🟡 Medium

#### M1. `applyEditSettings` 経路が recipe → settings → recipe の 3 段変換を毎回行っている

| 対象 | `Soramoyou/Services/ImageService.swift:666-674` |
|---|---|

`EditViewModel`（真実は `editRecipe`）→ `editSettings` 変換 → `ImageService.applyEditSettings` → 内部で `EditRecipe(from: settings)` を再構築 → `FilterGraphBuilder`。

H2 と併せて解消することで経路が `EditRecipe → FilterGraphBuilder` の 1 段になる。恒久対応としては `ImageServiceProtocol` から `applyEditSettings` / `generatePreview(_:edits:)` 系を段階的に `@available(*, deprecated)` 化し、呼び出し元を `applyEditRecipe` 系へ移行。

---

#### M2. `PhotoKitAdapter.saveEdit` 内の書き出しエラーがユーザーに到達しない

| 対象 | `Soramoyou/Persistence/PhotoKitAdapter.swift:136-183` |
|---|---|

```swift
try await PHPhotoLibrary.shared().performChanges {
    ...
    do { try pool.ciContext.writeHEIF10Representation(...) }
    catch {
        logger.error("レンダ済み画像の書き出し失敗: ...")
        return     // ← Swift クロージャから抜けるだけ
    }
    output.adjustmentData = try? adjustmentData(from: recipe)
    let changeRequest = PHAssetChangeRequest(for: asset)
    changeRequest.contentEditingOutput = output
}
```

`return` は `performChanges` の throwing block を終わらせるだけで例外にならない。書き出しに失敗しても `contentEditingOutput` が未設定のまま「成功」として帰り、Photos 側には「編集完了」の通知が出る（実際は何も変わっていない）。

**推奨対応**: `catch` 節で `throw PhotoKitAdapterError.renderFailed` を投げ、上位の `try await` に例外を伝搬させる。

---

#### M3. `CIContextPool` の soft-renderer フォールバックが simulator で致命的に遅い可能性

| 対象 | `Soramoyou/Rendering/CIContextPool.swift:64-74` |
|---|---|

シミュレータでは `MTLCreateSystemDefaultDevice()` が nil になるケースがあり、その場合 `useSoftwareRenderer = true` を設定して CIContext を作る。仕様としては正しいが、4000×3000 の `renderExport` が CPU ソフトレンダで走ると数十秒オーダーで固まり、E2E テストや開発中の動作確認を阻害する。

**推奨対応**: `#if targetEnvironment(simulator)` か、`mtlDevice == nil` の条件下では `PreviewRenderer.previewMaxPixel` を 1024 程度に絞るオーバーロードを用意する（アプリ挙動自体は保たれる）。

---

#### M4. `FilterGraphBuilder.applyDehaze` が `CIFogEffect` の未ドキュメント挙動に依存

| 対象 | `Soramoyou/Rendering/FilterGraphBuilder.swift`（`applyDehaze`） |
|---|---|

`CIFogEffect` は Apple 公式上 *霧を追加する* フィルタで、`inputAmount` に負値を渡して「霧除去」として使う運用は仕様外。iOS バージョンアップで `inputAmount` が 0 以上クランプされると silent に効かなくなる。

**推奨対応**: `ImageService.applyDehaze` のように `CIColorControls`（contrast + saturation）＋軽い exposure 補正の合成で実装し直す（確実に動作する）。互換のため `CIFogEffect` 実装は残して `#if DEBUG` で AB テストできると良い。

---

#### M5. Highlight / Shadow スケールの往復変換が冗長

| 対象 | `Soramoyou/Models/EditRecipe.swift`（`init(from legacy:)`） / `Soramoyou/Rendering/FilterGraphBuilder.swift`（`applyHighlightShadow`） |
|---|---|

```text
legacy(-1..+1) → recipe.highlights(0..2) → hlNorm = highlights - 1.0（-1..+1 に戻す）
```

`EditRecipe` が「物理値（0..2）」で持つのか「正規化（-1..+1）」で持つのかが曖昧。最終的に `CIHighlightShadowAdjust.highlightAmount` は 0..2 を要求するため、正規化で保持するなら FilterGraphBuilder 内で 1 回変換、物理値で保持するなら変換なしで済む。

**推奨対応**: `EditRecipe` 内の数値表現ポリシーを `docs/tech-spec.md` に追記し、フィールドごとにコメント `// normalized -1...+1` or `// CoreImage native 0...2` を付ける。併せて変換重複を排除。

---

#### M6. `FilterGraphBuilder.applyHDRToneMapping` が常時適用されており SDR ソースでも経由する

| 対象 | `Soramoyou/Rendering/FilterGraphBuilder.swift`（ACES filmic curve 部分） |
|---|---|

iOS 18+ の ACES filmic カーブは `recipe.targetDynamicRange == .hdr` のときのみ通すのが本来の意図のはず。現状は SDR 画像にも ACES LUT を通すため、中間グレーがわずかに持ち上がり、ハイライトが抑えられる「フィルム風」効果が常時かかっている疑い。

**推奨対応**: `if recipe.targetDynamicRange == .hdr { applyACESFilmicToneMap(image) } else { image }` のガードを入れる。もしくは「SDR にも効かせる」意図があるなら `docs/ui-spec.md` に明文化。

---

#### M7. `EditViewModel.setToolValueRealtime` の cancellation が効いていない可能性

| 対象 | `Soramoyou/ViewModels/EditViewModel.swift`（`renderFastPreviewOrAsync`） |
|---|---|

- 走行中の `fastPreviewTask?.cancel()` は呼ばれるが、`ImageService.generatePreviewFast` / `applyEditSettings` の中に `try Task.checkCancellation()` が無い。
- `requestId` による結果破棄は効くものの、**計算リソースは走り続ける**ため、指を素早く往復させると古い計算が終わるまで GPU / CPU を占有する。

**推奨対応**: `applyEditSettings` / `applyEditRecipe` の `withCheckedThrowingContinuation` 内、`FilterGraphBuilder.buildGraph` の直前で `try Task.checkCancellation()` を入れる。Metal / CIContext 呼び出しはアトミックなのでキャンセル粒度は合計数フィルタ単位で十分。

---

#### M8. `StorageService.uploadImage` が UIKit の `jpegData` を使っているため、`PhotoKitAdapter` の ImageIO 経路と色空間が微妙に違う

| 対象 | `Soramoyou/Services/StorageService.swift:46` |
|---|---|

`UIImage.jpegData(compressionQuality:)` は sRGB 固定の UIKit エンコーダ。`PhotoKitAdapter.saveEdit` は `CIContext.writeJPEGRepresentation` を使い Display P3 まで扱える。同じ画像でも投稿 JPEG（StorageService）と写真保存 JPEG（PhotoKitAdapter）で広色域ピクセルの扱いが違う。

Phase0RegressionTests #E にも「ImageIO 経由で揃える」旨の TODO が残っている（skip 状態）。

**推奨対応**: `StorageService.uploadImage` 内でも `CIContext.writeJPEGRepresentation(of: recipe が適用済みの CIImage, colorSpace: pool.outputColorSpace, options: [...: 0.95])` を使う経路に揃える。`UIImage → JPEG` は禁止パターンとして `docs/tech-spec.md` に明記。

---

### 🟢 Low

#### L1. `ExposureContrast.metal` の brightness / contrast は linear sRGB 空間で動作することをコメントで明示

| 対象 | `Soramoyou/Rendering/Shaders/ExposureContrast.metal:42-46` |
|---|---|

working color space が linear sRGB（CIContextPool）なので「`+ brightness` は linear での加算」「`(x - 0.5) * contrast + 0.5` の 0.5 は linear mid-gray」。意図は正しいが、Lightroom 等 sRGB gamma 空間で調整するツールと微妙に違う結果になるため、引継ぎ用コメントで明記しておきたい。

---

#### L2. `PreviewRenderer.renderPreview(from url:)` の path と `renderPreview(from image:)` の path で EXIF 回転の扱いが統一されていない

| 対象 | `Soramoyou/Rendering/PreviewRenderer.swift:48-116` |
|---|---|

- `from url:` は `kCGImageSourceCreateThumbnailWithTransform: true` で回転済み CGImage を得てから `CIImage(cgImage:)`。OK。
- `from image: UIImage` は `cgImage` から `CIImage` を作るため、**UIImage.imageOrientation が `.up` 以外だと回転前の画像で処理が走る**。最後の `UIImage(cgImage:, orientation: image.imageOrientation)` で表示は揃うが、フィルタチェーン内で向きが違うことが問題になるケース（方向性ビネット等）あり得る。

**推奨対応**: `CGImage` を得る前に `image.fixedOrientation()` のようなユーティリティで `.up` 正規化する。

---

#### L3. `RecipeStore.allIDs` はメインスレッドで走るとブロック

| 対象 | `Soramoyou/Persistence/RecipeStore.swift:84-92` |
|---|---|

`FileManager.default.contentsOfDirectory` は同期 I/O。レシピ数が 1,000 件を超える設計にならないので実害は薄いが、将来の保険として async 化するかキャッシュ化を検討。

---

#### L4. `ToneCurveView.updatePoint` で両端 (x=0, x=1) の x が動かないことが「UI 上呼ばれないから」に依存している

| 対象 | `Soramoyou/Views/ToneCurveView.swift:200-214` |
|---|---|

`originalX = point(at: index).x` で x は固定されているが、`updatePoint` の `normalized.x` はそもそも使われない。`ToneCurvePoints` の両端 x が `0.0` / `1.0` から動く経路は現在無いが、**防御的に**両端インデックス(0, 4)で x を強制固定するコメント or assertion を入れておくと安全。

---

#### L5. `EditHistoryManager.maxSize = 50` は値コピーなのでメモリ上は問題なし、ただし将来拡張時の注意点をコメントに

| 対象 | `Soramoyou/ViewModels/EditHistoryManager.swift:45` |
|---|---|

現状 `EditorSnapshot` は数 KB 程度。将来 `toneCurvePoints` を 16 点に拡張したり、`cropRectNormalized: CGRect` などを追加すると 50 件で 100 KB 級になり得る。CLAUDE.md のメモリ制約には抵触しないが、「maxSize 拡大時は画像参照を入れない」注意書きを追加。

---

#### L6. `MetalShaderPipeline` の error log は初期化失敗時のみだが、実行時の失敗ルートがない

| 対象 | `Soramoyou/Rendering/MetalShaderPipeline.swift` |
|---|---|

`CIKernel.apply(extent:arguments:)` が nil を返すケース（GPU メモリ不足等）のフォールバックが無い。実用上稀だが、万一失敗した場合 `exposureContrast` が画像に何も反映されず silent に元画像が返る。`os_signpost` でトレースを入れるか、`return nil` 時は CI ベースの fallback パスを呼ぶ設計にしておくと堅い。

---

#### L7. `Phase0RegressionTests.test_D_saveEdit_createCGImage_calledOnce` と `test_E_uploadImage_usesJPEGQuality_0_95` が `XCTSkip` のまま

| 対象 | `Soramoyou/SoramoyouTests/Phase0RegressionTests.swift:247, 277` |
|---|---|

二重ラスタライズの検出と JPEG 0.95 の ImageIO 経路化は Phase 0 ゴールに含まれていたが、DI 設計の変更が必要でテストだけ保留になっている。M8 とセットで対応すると skip を解消できる。

---

#### L8. `ImageService` が 1,234 行の God Object 化している

| 対象 | `Soramoyou/Services/ImageService.swift` |
|---|---|

責務: フィルター / 27 ツール / プレビュー / リサイズ / 圧縮 / 色抽出 / 色温度推定 / SkyType 推定 / EXIF 抽出。H1 で 27 ツール（約 430 行）を削除した上で、色解析を `ImageAnalysisService` に分離する SRP 整理を推奨。

---

#### L9. `SkyType` 判定や `extractDominantColors` の閾値がマジックナンバーのまま

| 対象 | `Soramoyou/Services/ImageService.swift:903-959` / `determineSkyType` |
|---|---|

`gridSize = 5`, `colorTemperature < 4500` などの閾値がハードコード。ColorMatchingTests に具体的な境界テストがあるか確認。MVP としては OK。

---

#### L10. `RecipeStore.save` の `outputFormatting = [.prettyPrinted, .sortedKeys]` は可読性重視だがサイズが倍になる

| 対象 | `Soramoyou/Persistence/RecipeStore.swift:48` |
|---|---|

ローカル Documents/ に JSON で置くだけなら問題なし。ただし将来 PHAdjustmentData に乗せる経路で共有する際、PhotoKitAdapter 側では `outputFormatting = .prettyPrinted` のみ、RecipeStore 側では `sortedKeys` 付きで**バイト比較が一致しない**ため、同一 recipe でも `data` が違う。冪等性テストを書くなら揃える。

---

## 2. 修正 TODO リスト（優先度付き）

作業順としては **H1 → H2 → M1** を 1 つの「リアルタイム経路統一」PR にまとめるのが最も安全で投資対効果が高い。

### 🔴 P0（必ず着手）

- [ ] **TODO-01**（H1）`ImageService.processEditTool` と `applyEditTool` / `applyXxx(27 個)` を削除し、`applyEditRecipe` に統一
  - [ ] `ImageServiceProtocol.applyEditTool` を deprecated マーク → 次コミットで削除
  - [ ] 呼び出し元（`EditViewModel` 等）の追従
  - [ ] `ImageServiceTests` の `applyEditTool` 依存テストを `FilterGraphBuilderTests` に移管
- [ ] **TODO-02**（H2）`EditViewModel.renderFastPreviewOrAsync` を `generatePreviewFromCIImage(_:recipe:)` 経路に差し替え、`toneCurvePoints` / `targetDynamicRange` が保全されることを確認
  - [ ] 回帰テスト追加: 「Exposure 変更 → ToneCurve 編集 → Brightness 変更 → ToneCurve 保持」
  - [ ] `setToolValueRealtime` 内部を `editRecipe` 直接更新へリファクタ
- [ ] **TODO-03**（H3）係数再設計と UI への反映
  - [ ] 各ツールの「-100 / 0 / +100 でどの強度」表を `docs/ui-spec.md` に追記
  - [ ] `clarity(+)`, `highlight(+)`, `whiteBalance`, `fade`, `tint` の係数を Lightroom 基準で引き上げ
  - [ ] `noiseReduction(-)` を UI で 0...1 に制限（仕様として負値廃止）
  - [ ] `grain` / `texture(+)` は preview とフル解像度で強度分岐するか、プレビュー時に強度ブーストを入れる

### 🟡 P1（次スプリントで着手）

- [ ] **TODO-04**（M1）`ImageServiceProtocol` から `applyEditSettings` / `generatePreview(_:edits:)` を deprecated 化し、呼び出し元を Recipe 直系に差し替え
- [ ] **TODO-05**（M2）`PhotoKitAdapter.saveEdit` の `catch` ブロックで `throw` し、書き出し失敗をユーザーに通知
- [ ] **TODO-06**（M4）`FilterGraphBuilder.applyDehaze` を `CIColorControls` ベースの実装に差し替え、CIFogEffect 依存を解消
- [ ] **TODO-07**（M6）`applyHDRToneMapping` を `recipe.targetDynamicRange == .hdr` でガード
- [ ] **TODO-08**（M8）`StorageService.uploadImage` を `CIContext.writeJPEGRepresentation` 経路に変更し、`UIImage.jpegData` を禁止化
- [ ] **TODO-09**（M7）`FilterGraphBuilder.buildGraph` 主要ステップ間で `Task.checkCancellation()` を挟み、指を動かしている間の無駄な計算を削減
- [ ] **TODO-10**（M5）`EditRecipe` の「正規化値 / 物理値」ポリシーを `docs/tech-spec.md` に明記し、冗長変換を除去

### 🟢 P2（余裕があれば）

- [ ] **TODO-11**（M3）Simulator 環境下で `previewMaxPixel` を 1024 に絞るフォールバックを追加
- [ ] **TODO-12**（L1）`ExposureContrast.metal` にカラー空間コメントを追加
- [ ] **TODO-13**（L2）`PreviewRenderer.renderPreview(from image:)` で UIImage.orientation を `.up` に正規化
- [ ] **TODO-14**（L6）`MetalShaderPipeline.apply` が nil を返した際の CI fallback ルートを追加
- [ ] **TODO-15**（L7 + M8）`Phase0RegressionTests` の skip テスト 2 件を本有効化
- [ ] **TODO-16**（L8）`ImageService` から `extractColors` / `calculateColorTemperature` / `detectSkyType` / `extractEXIFData` を `ImageAnalysisService` に分離
- [ ] **TODO-17**（L10）`RecipeStore` と `PhotoKitAdapter` で JSONEncoder 設定を揃える
- [ ] **TODO-18**（L4）`ToneCurveView.updatePoint` に「両端 x は不変」の assertion コメント追加
- [ ] **TODO-19**（L5）`EditHistoryManager` 拡張時の注意書きをクラスコメントに追加
- [ ] **TODO-20**（L3）`RecipeStore.allIDs` を `async` 化 or キャッシュ化
- [ ] **TODO-21**（L9）`determineSkyType` の閾値を `SkyTypeConfig` に集約し、境界テストを追加

---

## 3. レビュー対象外の観察メモ

- `screenshots/screenshot-gen`（Next.js プロジェクト）は別レビュー範囲。`page.tsx` の `canvasWidth`/`canvasHeight` 修正は妥当。
- `CLAUDE.md` の「`git add .` を避ける」書換えは適切。CI で `.cursor/` や `*.log` の混入を防ぐ lint を追加してもよい。
- `docs/` 配下の 5 ファイルは `CLAUDE.md` からの参照どおりに整備されており矛盾なし。
- PR #7 の 17 コミットは文脈が追えるよう粒度細かく分かれており、squash merge せず通常マージ推奨。

---

最終更新: 2026-04-22 / レビュア: Claude
