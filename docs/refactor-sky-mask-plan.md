# 画像処理基盤 棚卸し & SkyMaskProvider / Sky Replacement 導入計画 ⭐️

作成: 2026-07-10（調査: Explore 3系統並列 / 統合: Fable 5）
ステータス: **S1〜S3.1 実装完了（マスク生成v1.1＋合成エンジン・レビュー済み）・S4 UI接続以降は未着手**

> 進め方の合意事項: 実装は implementer サブエージェントに委譲し、各段階で止まって diff レビューを行う。
> 作業ブランチ: main から新規に切る（例: `機能-空マスク基盤`）。現行の `claude/enhance-gallery-tab-730rwo` では作業しない。

---

## 0. スコープと結論サマリ

- 27ツールは **EditTool enum（UIメタデータ）+ EditRecipe（物理値）+ FilterGraphBuilder（全処理ロジック）** に既に一本化済み。旧 ImageService 側の27ツール重複実装は過去のリファクタで削除済み。
- Metal は **露出/明るさ/コントラスト/彩度の4つだけ**を統合カーネル1本（`exposureContrastSaturation`）で処理する最適化レイヤー。残り23ツールは Core Image。
- **画素単位の空マスクは現状ゼロ**（空検出＝上部60%矩形ヒューリスティック）。`CIBlendWithMask` 使用実績もゼロ。Sky Replacement のマスク合成は完全新規実装。
- ただし `FilterGraphBuilder.buildGraph(recipe:source:)` の呼び出し口は **4箇所に収斂**しており、既存パイプラインを触らずに「編集前の独立ステップ」として Sky Replacement を差し込める構造。
- 重複コードは実在するが、**Sky Replacement の前提として必須なのは1件だけ**（SkyTypeClassifier の CIContext 迂回）。残りは独立した小PRとして任意に消化。

---

## 1. 27ツール棚卸し表

パイプライン適用順。詳細な行番号付きの完全版は調査ログ参照（本表は設計判断に必要な粒度に圧縮）。

| # | ツール | EditRecipe フィールド | 実装方式 | 適用箇所 (FilterGraphBuilder.swift) |
|---|---|---|---|---|
| 1 | 露出 | `exposureEV` (-3...3) | **Metal** 統合カーネル (fallback: CIExposureAdjust) | step2 L42-70 |
| 2 | 明るさ | `brightnessCI` (非対称カーブ変換) | **Metal** 同上 (fallback: CIColorControls) | step2 |
| 3 | コントラスト | `contrastCI` (非対称カーブ変換) | **Metal** 同上 | step2 |
| 4 | 彩度 | `saturationCI` (非対称カーブ変換) | **Metal** 同上 | step2 |
| 5 | トーン | `gamma` | CIGammaAdjust | step4 L353-358 |
| 6 | ブリリアンス | `brillianceNorm` | 複合: CIHighlightShadowAdjust+CIColorControls | step5 L367-381 |
| 7 | ハイライト | `highlights` | **CIToneCurve 5点近似**（GPU負荷対策で置換済） | step6 L474-500（シャドウと一体） |
| 8 | シャドウ | `shadowAmount` | 同上 | step6 |
| 9 | ブラックポイント | `blackPointBias` | CIColorMatrix (bias加算) | step7 L503-513 |
| 10 | 自然な彩度 | `naturalSaturationNorm` | CIVibrance | step8 L516-521 |
| 11 | 暖かみ | `warmthNorm` | CITemperatureAndTint（tintと合成） | step9 L528-541 |
| 12 | 色合い | `tintNorm` | 同上 | step9 |
| 13 | 色温度 | `colorTemperatureNorm` | CITemperatureAndTint（共通ヘルパー scale1500） | step10 L545-558 |
| 14 | ホワイトバランス | `whiteBalanceNorm` | 同上 scale2000 | step11 L565-567 |
| 15 | シャープネス | `sharpnessNorm` | 双方向: CISharpenLuminance / CIGaussianBlur | step12 L573-587 |
| 16 | テクスチャ | `textureNorm` | 双方向: CIUnsharpMask / CIGaussianBlur（幅比例スケール） | step13 L598-615 |
| 17 | クラリティ | `clarityNorm` | 双方向: CIUnsharpMask / CIColorControls | step14 L627-643 |
| 18 | かすみの除去 | `dehazeNorm` | 複合: CIColorControls+CIExposureAdjust | step15 L653-668 |
| 19 | グレイン | `grainNorm` | 複合: CIRandomGenerator+CIColorMatrix+Overlay | step16 L683-709 |
| 20 | フェード | `fadeNorm` | CIColorMatrix | step17 L730-741 |
| 21 | ノイズリダクション | `noiseReductionNorm` (0...1のみ) | CINoiseReduction | step18 L747-754 |
| 22 | カーブ調整 | `toneCurvePoints`（5点）優先 / `curvesNorm` | CIToneCurve（2経路） | step19 L757-779 |
| 23 | HSL調整 | `hslNorm` | CIHueAdjust（※全体色相回転のみ。色域別S/L操作ではない） | step20 L782-787 |
| 24 | ビネット | `vignetteNorm` | CIVignette | step21 L790-796 |
| 25 | レンズ補正 | `lensCorrectionNorm` | CIBumpDistortion（※光学歪み補正ではなくbumpエフェクト） | step22 L802-814 |
| 26 | 二重露光風合成 | `doubleExposureNorm` | 複合: Blur+ScreenBlend+DissolveTransition。**唯一 `source`（元画像）を参照する非線形グラフ** | step23 L817-846 |
| 27 | トリミング・回転 | `cropRectNorm`（クロップのみ）。回転/反転は EditViewModel の @Published（**Recipe外**） | クロップ=CIグラフ / 回転・反転=**UIGraphicsImageRenderer で物理回転**（EditViewModel L1179-1238） | step25 L220-247 |

**27ツール外の同居処理**: 2Dスタイルパッド（step23.5 L399-447）、iOS18+ HDRトーンマッピング（step24 L848-898）。

### パイプライン構造（現状）

```
UIImage（originalImages）
  │  回転・反転: UIGraphicsImageRenderer で物理変換（Core Image 外）
  ▼
CIImage ──→ FilterGraphBuilder.buildGraph(recipe:source:)   ← 呼び出し口は4箇所のみ:
  │           フィルター→Metal ECS→トーン→…→クロップ         ① PreviewRenderer.applyRecipeForPreview
  ▼                                                          ② PreviewRenderer.applyRecipeForExport
CIContextPool.shared.ciContext.createCGImage                 ③ ImageService.generatePreviewFromCIImage
  │  (linear sRGB working / Display P3 output)               ④ ImageService.applyEditRecipe
  ▼
UIImage
```

---

## 2. 重複・類似処理のグルーピング

### A群: 死んだ二重実装（削除・委譲で解消可、リスク小）
- **FilterType 10種プリセット**が `FilterGraphBuilder.applyFilter` (L251-324) と `ImageService.applyClearFilter`〜`applyVividFilter` (L97-204) で**係数まで完全一致の二重実装**。ImageService 側の `applyFilter`/`processFilterSync` は本番コードから未呼出（テスト `ImageServiceTests.testApplyFilter` L94 だけが呼ぶ）。
- ImageService 自身のコメント（L8-17）が「27ツールの同種重複はプレビュー/最終出力の不一致バグの温床だったため削除済み」と明記。**10種フィルターだけが同じ危険を残したまま取り残されている**。

### B群: CIContextPool 迂回（Sky 系の前提整備、リスク小）
- `SkyTypeClassifier` が Pool を使わず独自 CIContext を保持し（L94-96）、さらに `resizeImage` 内で **classify のたびに CIContext を新規生成**（L163）。`CIContextPool.swift:1-3` が「解消済み」と謳うバグパターンの残存。
- 色空間ポリシー（Display P3 / linear sRGB）もアプリ標準と不整合。

### C群: マジックナンバー・ユーティリティ散在（機械的集約、リスク小〜中）
- ナイーブリサイズが3箇所コピペ: `ImageService.resizeImage` L341-383 / `StorageService.resizeImageForThumbnail` L272-315 / `SkyTypeClassifier.resizeImage` L144-167
- `2048`px が4箇所、`5*1024*1024` が4箇所、quality `0.85` が2箇所に個別ハードコード
- アップロード前検証ロジックが `ImagePickerService.validateSelectedImages` と `PostViewModel.validateAndNormalizeSelectedImages` でほぼ同一
- `WidgetCacheWriter.cgOrientation(from:)` L208-220 が既存 `CGImagePropertyOrientation.init(_:)` 拡張（UIImage+NormalizedOrientation.swift L77-89）と同一ロジックを再実装

### D群: FilterGraphBuilder 内部ボイラープレート（利得小・触る面積大 → 凍結推奨）
- `f.outputImage ?? image` パターン20回以上 / 閾値 `0.01` 散在 / `clampedToExtent().cropped()` 3回 / `imageScale = width/750` 2回
- 全て動作中の本番パスであり、共通化の見返り（行数）に対して回帰リスクとレビュー負荷が大きい。**今回は触らない**。

### E群: 触ってはいけない意図的重複（共通化禁止）
- `ImageCompositor` ↔ `SkyCollageCompositor` の `flip`/`rasterizeOverlay`/`composite`/`systemFont` 重複は **`SkyCollageCompositor.swift:18-19` に「この重複は意図的。後で『共通化』と称して触らないこと」と明記**。P3 パイプライン回帰リスク回避のため。本計画でも触らない。

### F群: 名称と実装の乖離（記録のみ・機能変更になるため本計画対象外）
- `.hsl` = 全体色相回転のみ / `.lensCorrection` = bump distortion エフェクト。直すなら仕様変更として別案件。

### G群: JPEG エンコーダの色空間二系統（別案件として起票推奨）
- CIContext ベース（P3保持）: StorageService / PhotoKitAdapter / WidgetCacheWriter
- `UIImage.jpegData` ベース（sRGB固定）: ImageService.compressImage / ImagePickerService / PostViewModel
- 過去に実バグを起こした系統の残存だが、アップロードのハッピーパス全体に波及するため Sky 系と混ぜない。

### 空解析の二重系統（SkyMaskProvider の統合対象）
- 空タイプ判定が **2系統**: `SkyTypeClassifier.classify`（スコアリング方式）と `ImageService.detectSkyType`（if-else 方式、L574-603）
- `CIAreaAverage`→1x1レンダリング→CPU読み出しパターンが **4系統**に重複（SkyTypeClassifier×2 / ImageService×2）
- `import Vision` は存在するが VN* API の使用はゼロ（デッドimport）

---

## 3. SkyMaskProvider に乗り換えられるもの

SkyMaskProvider =「1枚の写真 → 空領域のグレースケールマスク（CIImage）」を一元供給する層。

| 消費者 | 現状 | マスク導入後 | 移行フェーズ |
|---|---|---|---|
| **Sky Replacement（新機能）** | なし | マスクで空だけ差し替え（主目的） | S3 |
| `SkyTypeClassifier.extractSkyRegion` | 上部60%矩形クロップ | マスク加重の色統計（精度向上） | S6（オプトイン） |
| `ImageService.extractColors`（skyColors 保存値） | 画像全体から抽出 | 空領域限定抽出 | **保留**（保存データの意味が変わる＝既存投稿と非互換。切替はプロダクト判断） |
| `ImageService.calculateColorTemperature` | 画像全体平均 | 空領域加重平均 | 同上・保留 |
| 空選択的編集（空だけ彩度UP等） | なし | 将来の拡張候補 | 対象外（Phase 3以降の構想） |

**マスクを使わないもの**: 27ツール本体は全画面均一処理なので乗り換え対象外。`doubleExposure` も同一画像内合成であり無関係。

---

## 4. リファクタ計画（リスクの低い順・各フェーズ=1PR=1レビュー）

### 共通ルール
- 1フェーズ = 1ブランチ = 1PR（squash マージ）。**ロールバック = 該当 squash コミットの `git revert` 1発**で成立する粒度を守る。
- 破壊的一括置換はしない。旧経路を残してデフォルト旧動作のまま新経路をオプトイン追加 → 検証後に切替、の段階移行。
- 各フェーズ完了条件: ビルド緑 + 既存テスト green + フェーズ固有の検証項目。

### 【R系: 独立クリーンアップ（S系と並行可能）】

**R1. FilterType 10種の一本化** — リスク: 低
- 内容: `ImageService.applyFilter` の中身を `FilterGraphBuilder`（`EditRecipe(appliedFilter:)` 経由）への委譲に置換し、`applyClearFilter`〜`applyVividFilter` と `processFilter`/`processFilterSync` を削除。public API シグネチャは不変。
- 影響範囲: `ImageService.swift` のみ（+ テスト1件の期待値確認）
- 検証: `ImageServiceTests.testApplyFilter` green + 10フィルターのプレビュー目視1巡
- ロールバック: revert 1発

**R2. SkyTypeClassifier を CIContextPool に乗せ替え** — リスク: 低（ただし要出力確認）
- 内容: 独自 CIContext（L94-96, L163）を `CIContextPool.shared.ciContext` に統一。per-call 生成を排除。
- ⚠️ 注意: Pool は linear sRGB working space のため、**平均色統計の数値が微妙に変わり分類結果がズレる可能性**。実写サンプル数枚で classify 前後の SkyType 一致を確認してからマージ。ズレる場合は「Pool の Metal デバイスだけ共有し、色空間設定は現行踏襲の専用 Context を Pool に追加」へ縮退。
- 影響範囲: `SkyTypeClassifier.swift` のみ
- 位置づけ: **S6（classifier のマスク移行）の前提**。S1-S5 だけなら必須ではないが、同ファイルを二度触らないため先行推奨。

**R3. 画像制約定数の一元化** — リスク: 低〜中
- 内容: `ImageConstraints` 定数（maxDimension 2048 / maxBytes 5MB / compressionQuality 0.85）を新設し、`ImagePickerService` / `PostViewModel`（4箇所） / `ImageService` / `StorageService` の該当リテラルを置換。**値は一切変えない**。検証ロジック本体の統合（ImagePickerService↔PostViewModel）は第2段として分離可。
- 影響範囲: 4ファイル（数値リテラル置換のみ）
- 検証: 既存テスト green + 投稿ハッピーパス1回

**R4.（任意・小粒）WidgetCacheWriter の orientation 変換重複除去** — リスク: 最小。既存拡張への差し替え1箇所。R3 に同乗可。

**凍結（やらないと決めたもの）**: D群（FilterGraphBuilder 内部整形）/ E群（意図的重複）/ F群（名称乖離）/ G群（JPEG色空間 → 別Issueとして起票のみ）

### 【S系: SkyMaskProvider / Sky Replacement 本線】

**S1. SkyMaskProvider インターフェース設計** ← 今ここ（§5 参照・承認待ち）
- 成果物: 型定義と呼び出し規約の合意。コードなし。

**S2. SkyMaskProvider v1 実装（純追加・既存ファイル変更ゼロ）** — リスク: 低
- 内容: `Rendering/SkyMask/` 新設。`SkyMaskProviding` protocol + `HeuristicSkyMaskProvider`（Core Image ベース）+ ユニットテスト（合成テスト画像: 上半分空色グラデ/下半分地面色 → マスク上下の平均輝度を検証。`FilterGraphBuilderTests.makeGraySource`/`sampleCenterRGB` のパターンを流用）。
- 既存コードへの影響: **ゼロ**（どこからも呼ばれない新規モジュール）
- ロールバック: ディレクトリ削除

**S3. Sky Replacement コア（合成エンジン）** — リスク: 低〜中
- 内容: `SkyReplacementCompositor` 新設。`CIBlendWithMask`（background=新しい空 / inputImage=元写真 / mask=フェザリング済みマスク）+ 境界なじませ（マスクへの CIGaussianBlur フェザー幅=画像幅比例 + 前景/新空の露出・色温度の簡易マッチング）。出力規約は ImageCompositor と同じ seam（向き正規化済み `.up` UIImage、P3、CIContextPool 経由）。
- 既存コードへの影響: ゼロ（新規モジュール + テスト）
- ⚠️ FilterGraphBuilder / EditRecipe は**変更しない**。合成は「編集前の独立ステップ」であり、合成済み画像が通常の27ツールパイプラインに入る（SkyStitcher と同じ合流方式）。

**S4. UI: 最小プレビュー画面** — リスク: 中（UI配線のみ）
- 内容: `SkyReplacementView`（ビフォー/アフター切替 + 空プリセット数枚 + 適用ボタン）+ ViewModel。投稿フローへの入口1箇所。vision（スクショ確認）で目標と照合。
- 計装: `sky_replacement_applied` 等を LoggingService ファサード経由で追加（analytics 5原則）。

**S5. 回帰確認 + リリース整備** — リスク: 低
- 既存主要フロー（投稿/編集27ツール/フィルター/コラージュ/広角合成）の回帰確認、`docs/pre-release-checklist.md` 通し、What's New 更新（ユーザー可視の新機能のため必須）。

**S6.（S5 の後・任意）SkyTypeClassifier のマスク移行** — リスク: 中
- 内容: `extractSkyRegion`（上部60%矩形）をマスク加重統計に**オプトイン注入**で置換（デフォルト旧動作、DI で切替）。実写サンプルで新旧の SkyType 一致率を確認してから切替。
- skyColors / colorTemperature の空領域限定化は**保存データ互換の問題があるため本計画では実施しない**（プロダクト判断待ち）。

### 推奨実行順

```
S1(設計承認) → S2 → S3 → S4 → S5 →（リリース）→ S6
R1, R3+R4 は独立 PR としていつでも並行可。R2 のみ S6 の前までに。
```

---

## 5. 段階1: SkyMaskProvider インターフェース設計案（承認待ち）

### 型定義（案）

```swift
// Rendering/SkyMask/SkyMaskProviding.swift（新規）

/// マスク生成の品質モード
enum SkyMaskQuality {
    case preview   // 長辺 ~768px に縮小して高速生成（UI プレビュー用）
    case export    // 入力解像度のまま生成（書き出し用）
}

/// 生成された空マスクと付帯情報
struct SkyMask {
    /// グレースケール CIImage。1.0=空 / 0.0=非空 / 中間値=境界ソフトエッジ。
    /// extent は入力 CIImage と同一（quality=.preview でも最終的に入力サイズへスケール）。
    let mask: CIImage
    /// 空が画面に占める割合 0...1（「空が写っていない写真」の UI 出し分けに使用）
    let skyCoverage: Double
    /// マスクの自己申告信頼度 0...1（低信頼時は Sky Replacement ボタンを無効化等）
    let confidence: Double
}

enum SkyMaskError: Error {
    case invalidInput          // extent 空・CGImage 化不能など
    case generationFailed      // フィルタグラフ構築失敗
}

/// 空マスクの一元供給層。バックエンド（ヒューリスティック / 将来の CoreML）を差し替え可能。
protocol SkyMaskProviding {
    /// - Parameter image: 向き正規化済み（.up 焼き込み済み）の CIImage
    func makeSkyMask(for image: CIImage, quality: SkyMaskQuality) async throws -> SkyMask
}

/// v1 実装: Core Image ヒューリスティック（依存ゼロ・端末内完結）
final class HeuristicSkyMaskProvider: SkyMaskProviding { ... }
```

### 設計判断とその理由

| 判断 | 理由 |
|---|---|
| 入出力とも **CIImage**（UIImage でない） | 既存パイプラインの通貨が CIImage。マスクは `CIBlendWithMask` にそのまま挿せる。UIImage 変換は呼び出し側の seam（ImageCompositor 方式）に任せる |
| **向き正規化済みを前提**（provider 内で orientation を扱わない) | orientation 処理は現状4系統に分裂しており、5系統目を作らない。呼び出し側で既存の `UIImage+NormalizedOrientation` を使う |
| **provider はステートレス**、キャッシュは呼び出し側 | EditViewModel が既に「画像index+変換キー」でキャッシュを持つ流儀。二重キャッシュ層を作らない |
| **async throws** | v1 ヒューリスティックは高速だが、将来の CoreML バックエンドは重い。API を先に非同期にしておけば差し替え時にシグネチャ不変 |
| skyCoverage / confidence を返す | 「空がほぼ写っていない写真」で Sky Replacement を出さない UI ガードに必須 |
| CIContext は **CIContextPool.shared** を使用 | アプリ標準（新たな迂回を作らない） |

### v1 ヒューリスティックの中身（S2 で実装するもの・概要）

1. 縮小（quality に応じ Lanczos）
2. 画素ごとの「空らしさスコア」= 色相（青〜シアン帯 + 朝夕の暖色帯）× 彩度・輝度条件 × **縦位置の事前確率**（上ほど空らしい）。CIColorKernel 1本（既存 MetalShaderPipeline と同じ metallib ロード基盤に相乗り）または CIFilter 合成で実装
3. CIGaussianBlur による平滑化 + smoothstep 閾値でソフトエッジ化
4. `CIAreaAverage` で skyCoverage 算出
- 限界の明示: 電線・木の枝など細部の抜けは v1 では粗い。護りは confidence / skyCoverage による UI ガードと、プリセット空がフェザーで馴染む設計。精度が必要になったら CoreML バックエンドを **同じ protocol の別実装**として追加（呼び出し側変更ゼロ）。

### Sky Replacement（S3）の合成規約（先出し）

```
新しい空画像（aspect-fill でリサイズ&クロップ）──┐
                                                ├─ CIBlendWithMask ─→ 露出/色温度 簡易マッチ ─→ UIImage(.up, P3)
元写真（向き正規化済み）─────────────────────────┤                                             │
SkyMask.mask（フェザリング済み）─────────────────┘                          通常の編集フロー（27ツール）へ合流
```

- **EditRecipe / FilterGraphBuilder / Firestore スキーマは無変更**。合成済み1枚が通常フローに入る（広角合成 SkyStitcher と同じ合流点・同じ seam 契約）。
- 将来「レシピとして空差し替えを保存したい」となったら別途設計（本計画では扱わない）。

---

## 6. 承認が必要な決定事項

1. **マスク生成 v1 バックエンド**: (a) Core Image ヒューリスティック（推奨・依存ゼロ・上記設計） / (b) CoreML セグメンテーションモデル同梱（高精度だがモデル選定+数十MB+ライセンス確認） / (c) OpenCV GrabCut（ブリッジ拡張が必要・非決定性の前科あり）
2. **Sky Replacement の統合位置**: (a) 編集前の独立ステップ（推奨・既存パイプライン無変更） / (b) EditRecipe 組み込み（再編集可能になるが Firestore/永続化に波及・高リスク）
3. **R系クリーンアップの扱い**: S系と並行して R1/R3 を進めるか、S系完了後にまとめるか
4. postKind の扱い: Sky Replacement 済み投稿に `postKind` 新値（例 `skyReplaced`）を付けるか、通常投稿扱いにするか（Firestore スキーマ・「合成写真」の透明性表示に関わるプロダクト判断）
