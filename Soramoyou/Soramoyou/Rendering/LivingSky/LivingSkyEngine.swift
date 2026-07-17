// ⭐️ LivingSkyEngine.swift
// Living Sky（空のループアニメーション）の1フレーム生成エンジン
//
//  LivingSkyEngine.swift
//  Soramoyou
//
// 設計書: docs/living-sky-design.md §1（全体アーキテクチャ）§3（Metal シェーダー構成）
//
// 責務:
// - `LivingSky.metal` の `livingSky` general CIKernel をロードする（失敗時は nil・機能非表示）
// - `prepare(image:)` で「編集確定後の写真」を1回だけ縮小・マスク生成・フェザーしてキャッシュする
//   （設計書§1: マスクは画像につき1回生成、フレームごとの再生成はしない）
// - `makeFrame(elapsed:)` で経過時間から位相を計算し、kernel を適用した1フレームの CIImage を返す

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import os

/// `LivingSkyEngine` の処理中に発生しうるエラー
enum LivingSkyEngineError: Error {
    /// UIImage → CIImage 変換に失敗した（cgImage が取得できない等）
    case invalidInput
    /// マスク・スケール後の CIImage 生成に失敗した（フィルタグラフの構築失敗）
    case preparationFailed
}

/// v8: 雲ベールの色（写真の空平均色を明側に寄せた値・0...1 のリニア成分）。
/// 出典: docs/research/living-sky-research-2026-07-part2-synthesis.md「v8（B2案）設計メモ」
/// 「色 = prepare 時に空領域の平均色を計測し、明側に寄せたベール色を kernel へ」。
/// 未 prepare 時の既定値は白（1,1,1）——`veilColRGB` を screen 合成するため、白なら
/// `LivingSkyParameters.veilIntensity` が 0 でなくても実質「無色の明るさ寄せ」になり安全側。
struct LivingSkyVeilColor: Equatable {
    var r: Float = 1
    var g: Float = 1
    var b: Float = 1
}

/// Living Sky の1フレーム生成エンジン。
///
/// `MetalShaderPipeline` と同じイディオムで `default.metallib` から general CIKernel をロードする。
/// ただし `MetalShaderPipeline` と異なり本エンジンは「1枚の写真につき1インスタンス」の
/// 状態（縮小済み photo・フェザー済み mask・パラメータ）を保持するため、シングルトンにはしない。
final class LivingSkyEngine {

    // MARK: - 定数（マジックナンバー回避）

    /// プレビュー用に縮小する長辺の上限px（設計書§4: 「長辺1080に事前縮小」）
    private static let previewMaxLongSide: CGFloat = 1080

    /// 書き出し用に縮小する長辺の上限px（設計書§5: 「解像度: 長辺1920上限」。段階4で追加）
    private static let exportMaxLongSide: CGFloat = 1920

    /// マスクのフェザー半径 = 縮小後短辺 × この係数（設計書「④マスクをフェザー: 半径=縮小後短辺の0.5%程度」）
    private static let featherRadiusFraction: CGFloat = 0.005

    /// マスクの「地上動かし禁止」判定に使う confidence の警告閾値。
    /// この値未満のときは呼び出し側（View）が警告表示を検討する（設計書§7リスク表）。
    static let lowConfidenceThreshold: Double = 0.3

    /// シマー用 fbm の空間スケール（例 0.004）
    private static let shimmerScale: Float = 0.004

    /// シマーの円周サンプリング半径（例 2.0）
    private static let shimmerRadius: Float = 2.0

    /// v8: 空領域の平均色を明側へ寄せる補間係数（`mix(skyAverage, white, veilColorWhiteMix)`）。
    /// 出典: docs/research/living-sky-research-2026-07-part2-synthesis.md「v8（B2案）設計メモ」
    /// 「結果 RGB を明側へ補間（white と 0.55 で mix）」。
    private static let veilColorWhiteMix: CGFloat = 0.55

    /// ROI コールバックの追加余白px。v8 は写真を一切ワープしないため本来は不要だが、
    /// `motionModel=1`（v3 軌道うねり・比較用に不変更のまま残置）は今も `photo.sample(p - d)`
    /// で変位サンプリングするため、v3 のためだけに引き続き必要（下記 `makeFrame` の pad コメント参照）。
    private static let roiPaddingMargin: CGFloat = 2.0

    // MARK: - Properties

    /// `livingSky` カーネル（ロード失敗時は nil）
    private let kernel: CIKernel?

    /// 空マスク生成の実装（差し替え可能。テストでは軽量な実装を注入できる）
    private let maskProvider: SkyMaskProviderProtocol

    /// `prepare` 済みの写真（長辺1080以下に縮小済み）。未 prepare なら nil。
    private(set) var preparedPhoto: CIImage?

    /// `prepare` 済みのフェザー済みマスク（合成用マスク compositeMask）。未 prepare なら nil。
    private(set) var preparedMask: CIImage?

    /// v8: `prepare` 済みの雲ベール色（写真の空平均色を明側に寄せた値）。未 prepare なら既定の白。
    /// 出典: docs/research/living-sky-research-2026-07-part2-synthesis.md「v8（B2案）設計メモ」。
    private(set) var preparedVeilColor = LivingSkyVeilColor()

    /// 直近の `prepare` で得たマスクの信頼度 0...1（`SkyMask.confidence` をそのまま保持）。
    /// 設計書§7: 低confidence時に呼び出し側が警告表示 or シマー自動減を検討する材料。
    private(set) var maskConfidence: Double = 0

    /// ユーザー可変パラメータ（風向き・速さ・光のゆらぎ・ループ長）
    var parameters = LivingSkyParameters()

    // Phase: os.Logger に統一（MetalShaderPipeline と同じ subsystem でフィルタ可能にする）
    private static let logger = Logger(
        subsystem: "com.soramoyou.photo-editor",
        category: "LivingSkyEngine"
    )

    // MARK: - Init

    /// - Parameter maskProvider: 空マスク生成の実装。差し替え可能（テスト用に軽量実装を注入できる）。
    init(maskProvider: SkyMaskProviderProtocol = HeuristicSkyMaskProvider()) {
        self.maskProvider = maskProvider

        // MetalShaderPipeline と同イディオム: default.metallib から CIKernel をロードし、
        // 失敗時は nil を保持して呼び出し側（LivingSkySheet）が機能を非表示にできるようにする。
        // ⚠️ 設計書§1: 「Metal 必須: kernel ロード失敗時はフォールバックせず機能を非表示」
        //    （アニメーションに CIFilter 代替は非現実的なため CPU フォールバックは用意しない）。
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let data = try? Data(contentsOf: url) {
            self.kernel = try? CIKernel(functionName: "livingSky", fromMetalLibraryData: data)
            if kernel == nil {
                Self.logger.error("CIKernel 初期化失敗 — livingSky。Living Sky 機能を非表示にする")
            } else {
                Self.logger.info("CIKernel 初期化成功 — livingSky")
            }
        } else {
            self.kernel = nil
            Self.logger.error("default.metallib が Bundle に存在しません。Living Sky 機能を非表示にする")
        }
    }

    /// Metal カーネルが使用可能かどうか。false の場合は `prepare`/`makeFrame` を呼ばず、
    /// 呼び出し側（View）で機能そのものを非表示にすること（設計書§1）。
    var isAvailable: Bool { kernel != nil }

    /// Metal カーネルが利用可能かどうかを一度だけ判定してキャッシュした static 値。
    ///
    /// `EditView` はプレビューボタンの表示可否をこの値で判定するが、SwiftUI の `body` は
    /// 再描画のたびに再評価されるため、毎回ここで新しい `LivingSkyEngine()` を生成して
    /// `default.metallib` からの kernel ロードを走らせるのは無駄なコストになる。
    /// `static let` の初期化クロージャは Swift ランタイムにより初回アクセス時に一度だけ・
    /// スレッドセーフに評価される（lazy static 相当）ため、これを利用して1回だけエンジンを
    /// 生成し `isAvailable` を評価した結果をキャッシュする。
    static let isSupported: Bool = {
        LivingSkyEngine().isAvailable
    }()

    // MARK: - Public: 準備（画像につき1回）

    /// 編集確定後の写真から「縮小済み photo」と「フェザー済み mask」を1回だけ生成してキャッシュする。
    ///
    /// - Note: 重い処理本体（向き正規化の再描画・マスク生成）は `Task.detached` にオフロードし、
    ///   呼び出し元のアクター（多くは MainActor）をブロックしないようにする。
    ///   コードベースの確立慣習（`SkyReplacementCompositor.replaceSky` 等）と同じパターン。
    /// - Parameters:
    ///   - image: 編集確定後の写真（EditViewModel の表示用プレビュー、または元画像）
    ///   - quality: 段階4で追加。`.preview`（既定・長辺1080）はリアルタイムプレビュー用、
    ///     `.export`（長辺1920）は動画書き出し用（設計書§5「品質2モード」）。
    ///     既存呼び出し側（`LivingSkyController`）は既定値のため無変更で動作する。
    func prepare(image: UIImage, quality: SkyMaskQuality = .preview) async throws {
        let workTask = Task.detached(priority: .userInitiated) { () async throws -> (CIImage, CIImage, LivingSkyVeilColor, Double) in
            try await self.prepareAsync(image: image, quality: quality)
        }
        let (photo, mask, veilColor, confidence) = try await workTask.value
        self.preparedPhoto = photo
        self.preparedMask = mask
        self.preparedVeilColor = veilColor
        self.maskConfidence = confidence
    }

    /// `prepare` の処理本体（手順①〜④・Task.detached からオフロードして呼ばれる）
    ///
    /// `maskProvider.makeSkyMask` が async throws のため、この本体も async throws にして
    /// 素直に `await` する（SkyReplacementCompositor.replaceSkySync と同型のパターン）。
    private func prepareAsync(
        image: UIImage,
        quality: SkyMaskQuality
    ) async throws -> (photo: CIImage, mask: CIImage, veilColor: LivingSkyVeilColor, confidence: Double) {
        // 手順①: 向き正規化（EXIF orientation をピクセルへ焼き込む）。
        // `UIImage+NormalizedOrientation` を使用（既存の焼き込み契約に合わせる）。
        let normalized = image.withNormalizedOrientation()
        guard let cgImage = normalized.cgImage else {
            throw LivingSkyEngineError.invalidInput
        }
        let rawCIImage = CIImage(cgImage: cgImage)
        guard !rawCIImage.extent.isEmpty, !rawCIImage.extent.isInfinite else {
            throw LivingSkyEngineError.invalidInput
        }

        // 手順②: 長辺を上限px以下に縮小（プレビューのカクつき防止。設計書§4/§5）。
        // quality により上限を切り替える（.preview=1080 / .export=1920）。
        // 既に上限以下の場合は縮小しない（拡大しない）。
        let maxLongSide = quality == .export ? Self.exportMaxLongSide : Self.previewMaxLongSide
        let longSide = max(rawCIImage.extent.width, rawCIImage.extent.height)
        let photo: CIImage
        if longSide > maxLongSide {
            let scale = maxLongSide / longSide
            let scaleFilter = CIFilter.lanczosScaleTransform()
            scaleFilter.inputImage = rawCIImage
            scaleFilter.scale = Float(scale)
            scaleFilter.aspectRatio = 1
            guard let scaledRaw = scaleFilter.outputImage else {
                throw LivingSkyEngineError.preparationFailed
            }
            // origin をゼロ基準に正規化（HeuristicSkyMaskProvider 手順a'と同じ理由:
            // 縮小後の extent.origin が非ゼロだと、後続のマスク生成・kernel の座標計算がずれる）
            photo = scaledRaw.transformed(
                by: CGAffineTransform(translationX: -scaledRaw.extent.minX, y: -scaledRaw.extent.minY)
            )
        } else {
            photo = rawCIImage
        }

        // 手順③: 空マスクを quality 品質で1回だけ生成する（フレームごとの再生成はしない）。
        // `makeSkyMask` は内部で Task.detached を持つが、既に detached 文脈から素直に await
        // しているだけなので害はない（SkyReplacementCompositor.replaceSkySync も同様のネスト構造）。
        let skyMask = try await maskProvider.makeSkyMask(for: photo, quality: quality)

        // 手順④: マスクをフェザー（クランプ→ブラー→クロップの定石。SkyReplacementCompositor.feather と同順序）。
        // ⚠️ 旧順序（blur 後に clamp）は縁のマスク値を下げ「画像の縁の細い帯」の原因になる（SKY-002 の教訓）。
        let shortSide = min(photo.extent.width, photo.extent.height)
        let featherRadius = max(1.0, shortSide * Self.featherRadiusFraction)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = skyMask.mask.clampedToExtent()
        blur.radius = Float(featherRadius)
        let featheredMask = blur.outputImage?.cropped(to: photo.extent) ?? skyMask.mask

        // 手順④': v8 雲ベール色を計測する。
        // 出典: docs/research/living-sky-research-2026-07-part2-synthesis.md「v8（B2案）設計メモ」
        // 「色 = prepare 時に空領域の平均色を計測し、明側に寄せたベール色を kernel へ（写真
        // パレット転写）」。
        let veilColor = computeVeilColor(photo: photo, mask: skyMask.mask)

        return (photo, featheredMask, veilColor, skyMask.confidence)
    }

    // MARK: - Private: v8 雲ベール色の計測

    /// マスク重み付きの空平均色を計測し、明側へ補間して雲ベール色を作る。
    ///
    /// 方式: `photo × mask` の `CIAreaAverage` ÷ `mask` の `CIAreaAverage`（= Σ(photo×mask)/Σ(mask)、
    /// マスク値を重みとした加重平均）。`mask>0.5` 領域の単純平均という簡易方式も選択肢として
    /// 挙げられていたが（実装容易性優先）、既存コードベースに全く同じ加重平均パターンが
    /// 確立している（`SkyReplacementCompositor.toneMatched`/`areaAverageColor`）ため、それを
    /// 踏襲するほうが実装コストは変わらず精度も高い（フェザー済みマスクの境界グラデーションを
    /// 重みとしてそのまま活かせる）。
    ///
    /// - Note: `CIAreaAverage` は sRGB 表示値ベースで平均するため、厳密なリニア light 空間での
    ///   加重平均ではない（ガンマ不整合）。`mix` で white 0.55 に大きく寄せるため実用上の影響は
    ///   小さいと判断したが、雲ベールの色味が想定と異なる場合はここが原因になりうる
    ///   （vision レビューでの較正対象。実装レポート「迷った点」参照）。
    private func computeVeilColor(photo: CIImage, mask: CIImage) -> LivingSkyVeilColor {
        let extent = photo.extent
        guard !extent.isEmpty, !extent.isInfinite else {
            return LivingSkyVeilColor()
        }

        let multiply = CIFilter.multiplyCompositing()
        multiply.inputImage = photo
        multiply.backgroundImage = mask
        guard let maskedPhoto = multiply.outputImage,
              let maskedAverage = try? areaAverageColor(of: maskedPhoto, extent: extent),
              let maskAverage = try? areaAverageColor(of: mask, extent: extent) else {
            return LivingSkyVeilColor()
        }

        // ゼロ割回避（mask がほぼ全面0＝空が写っていない写真）。SkyReplacementCompositor と
        // 同じ閾値 0.001 を踏襲する。
        let denominator = max(maskAverage.r, 0.001)
        let skyAverage = (
            r: maskedAverage.r / denominator,
            g: maskedAverage.g / denominator,
            b: maskedAverage.b / denominator
        )

        // 明側へ補間: mix(skyAverage, white, veilColorWhiteMix)。
        let mixFactor = Self.veilColorWhiteMix
        return LivingSkyVeilColor(
            r: Float(skyAverage.r * (1 - mixFactor) + mixFactor),
            g: Float(skyAverage.g * (1 - mixFactor) + mixFactor),
            b: Float(skyAverage.b * (1 - mixFactor) + mixFactor)
        )
    }

    /// `CIAreaAverage` で指定領域の平均色を読み取る。
    /// `SkyReplacementCompositor.areaAverageColor` と同型のパターン（1x1 に縮約した画像を
    /// CGContext へ描画してバイト列を読み出す）をここでも踏襲する。
    private func areaAverageColor(of image: CIImage, extent: CGRect) throws -> (r: Double, g: Double, b: Double) {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = extent

        guard let output = filter.outputImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LivingSkyEngineError.preparationFailed
        }
        guard let cgImage = CIContextPool.shared.ciContext.createCGImage(
            output,
            from: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw LivingSkyEngineError.preparationFailed
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let bitmapContext = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw LivingSkyEngineError.preparationFailed
        }
        bitmapContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return (Double(pixel[0]) / 255.0, Double(pixel[1]) / 255.0, Double(pixel[2]) / 255.0)
    }

    // MARK: - テスト用シーム

    /// テスト専用: `prepare` を経由せず photo/mask を直接セットする。
    ///
    /// `LivingSkyEngineTests` でループ保証（`makeFrame(elapsed: 0)` と `makeFrame(elapsed: T)` の
    /// 一致）を検証する際、`prepare` が行う実写真の向き正規化・ヒューリスティックマスク生成を
    /// 経由せずに、決定的なテスト用 photo/mask（例: 単色 CIImage）を直接注入できるようにする。
    /// - Parameters:
    ///   - photo: テスト用の写真 CIImage
    ///   - mask: テスト用のマスク CIImage（extent は photo と一致させること）
    ///   - veilColor: v8 で追加。テスト用の雲ベール色（省略時は既定の白 (1,1,1)——既存テスト
    ///     呼び出し `setPreparedStateForTesting(photo:mask:)` を壊さない後方互換デフォルト）
    ///   - confidence: `maskConfidence` に設定する値（既定 1.0 = 高信頼扱い）
    func setPreparedStateForTesting(
        photo: CIImage,
        mask: CIImage,
        veilColor: LivingSkyVeilColor = LivingSkyVeilColor(),
        confidence: Double = 1.0
    ) {
        self.preparedPhoto = photo
        self.preparedMask = mask
        self.preparedVeilColor = veilColor
        self.maskConfidence = confidence
    }

    // MARK: - Public: フレーム生成

    /// 経過時間からループ位相を計算し、1フレーム分の CIImage を返す。
    ///
    /// - Important: `prepare(image:)` が成功済みであること。未 prepare または kernel 未ロードなら nil。
    /// - Parameter elapsed: プレビュー開始からの経過秒（負値・非有限値は 0 として扱う）
    /// - Returns: 1フレーム分の CIImage。生成不可時は nil。
    func makeFrame(elapsed: TimeInterval) -> CIImage? {
        guard let kernel = kernel, let photo = preparedPhoto, let mask = preparedMask else {
            return nil
        }

        // ループ長 T（秒）。0以下・非有限だとゼロ除算になるため下限をクランプする。
        let loopDuration = max(parameters.loopDuration, 0.001)
        let safeElapsed = (elapsed.isFinite && elapsed >= 0) ? elapsed : 0
        // 設計書§2.1: time01 = frac(t/T)。truncatingRemainder は負値だと符号付きの余りを返すが、
        // safeElapsed を 0 以上に丸めているため常に 0...loopDuration の範囲になる。
        // ⚠️ v8 ループ整合の前提: elapsed=0 と elapsed=loopDuration のどちらも time01=0 になる
        //   （truncatingRemainder(dividingBy:) は elapsed==loopDuration のとき余り0を返す）。
        //   LivingSky.metal 側の scrollUnit = fract(time01)*kVeilPeriod*speedPeriods はこの
        //   time01=0 一致を土台にしている。
        let time01 = Float(safeElapsed.truncatingRemainder(dividingBy: loopDuration) / loopDuration)

        // 風向き（度数）→ ワーキング座標系の単位ベクトル。0°=右向き、反時計回り。
        let angleRad = parameters.windAngleDegrees * .pi / 180
        let dirX = CGFloat(cos(angleRad))
        let dirY = CGFloat(sin(angleRad))

        // ドリフト振幅px = 縮小後短辺 × 0.008 × (speed / 0.5)（LivingSkyParameters.
        // driftAmplitudePx 参照）。「短辺」は prepare 済み photo extent の min(width,height)。
        // ⚠️ v8 は flowDirPx の「大きさ」自体は使わない（下記 LivingSky.metal 側で
        //   windDir=normalize(flowDirPx) と方向だけ取り出す）。それでも driftPx を使って
        //   flowDirPx を作り続けるのは、motionModel=1（v3軌道うねり・比較用に不変更）が
        //   `length(flowDirPx)` を軌道半径の基準にするため（LivingSkyParameters.driftAmplitudePx
        //   のdocコメント参照）。
        let shortSide = min(photo.extent.width, photo.extent.height)
        let driftPx = parameters.driftAmplitudePx(shortSide: shortSide)
        // ⚠️ 段階3 vision レビュー指摘#1: CIVector として float2 を渡すと Metal general CIKernel の
        // 引数マーシャリングで (0,0) になり「フロー変位が実質ゼロ」になる不具合が実証された。
        // スカラー float（time01/shimmerAmp 等）は正しくマーシャリングされるため、
        // flowDirPx を2つの Float スカラーに分解して渡す（LivingSky.metal 側で float2 に再構成）。
        let flowDirPxX = Float(dirX * driftPx)
        let flowDirPxY = Float(dirY * driftPx)

        // v8: 雲ベールの強度（「雲の量」スライダー）。0...1 にクランプする。
        let veilIntensity = Float(min(max(parameters.veilIntensity, 0), 1))
        let veilColor = preparedVeilColor

        // v8: 速さスライダー（0.1〜1.0）→ 1ループあたりのタイル周期数 speedPeriods（整数 k∈{1,2,3}）
        // へ量子化する。出典: docs/research/living-sky-research-2026-07-part2-synthesis.md
        // 「速さスライダー → k∈{1,2,3} に量子化（連続速度はループ整合と非両立）」。
        // ⚠️ LivingSky.metal は speedPeriods が整数値である前提でループ整合の証明を組んでいる
        //   （scrollUnit = fract(time01)*kVeilPeriod*speedPeriods が1ループでkVeilPeriodの
        //   整数倍だけ進む必要がある）ため、量子化を崩さないこと。
        let speedPeriods: Float
        if parameters.speed < 0.4 {
            speedPeriods = 1
        } else if parameters.speed < 0.7 {
            speedPeriods = 2
        } else {
            speedPeriods = 3
        }

        let shimmerAmp = Float(min(max(parameters.shimmerAmount, 0), 0.1))

        // ⚠️ 設計書§3「ROI コールバックが最重要レビューポイント」:
        // v8（motionModel=0・既定）は写真を一切ワープしない（`photo.sample` は常に p のまま）ため
        // 本来 ROI パディングは不要——ただし `motionModel=1`（v3 軌道うねり・比較用に DEBUG ビルド
        // Picker から選択可能・不変更のまま残置）は今も `photo.sample(photo.transform(p - d))` で
        // 変位サンプリングするため、roiCallback は「両分岐のどちらが実行されるか分からない」
        // 契約上、v3 の最大変位を包含する余白が引き続き必要。
        // v3 の軌道半径の最大値は `driftPx × kOrbitRadiusRatio(0.5) × 1.0`（fbm の変動幅が
        // 最大の場合）で常に `driftPx * 0.5` 以下（LivingSky.metal 側コメント参照）のため、
        // `driftPx * 0.5 + roiPaddingMargin` で安全に包含する。
        let pad = driftPx * 0.5 + Self.roiPaddingMargin

        return kernel.apply(
            extent: photo.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -pad, dy: -pad) },
            arguments: [
                // 段階3 vision レビュー指摘#2: 風上側エッジの黒滲み対策（extent外=透明の混入防止）。
                // v3 の変位サンプリング（p − d）が extent 外に及ぶと sampler は透明を返すため、
                // 端の画素を外側へ引き伸ばす clampedToExtent() を適用する（clamp の定石）。
                // extent: は元の photo.extent のまま（出力範囲は変えない）。
                photo.clampedToExtent(),
                mask,
                time01,
                flowDirPxX,
                flowDirPxY,
                // 動きモデル切替（0=v8タイル化ノイズ雲ベール[既定]／1=v3軌道うねり[比較用]）。
                // LivingSky.metal の引数順（flowDirPxY の直後・veilIntensity の直前）と厳密一致させる。
                Float(parameters.motionModel),
                veilIntensity,
                veilColor.r,
                veilColor.g,
                veilColor.b,
                speedPeriods,
                shimmerAmp,
                Self.shimmerScale,
                Self.shimmerRadius
            ]
        )
    }
}
