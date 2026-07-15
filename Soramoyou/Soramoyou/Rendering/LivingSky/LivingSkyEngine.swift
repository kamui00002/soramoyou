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

    /// フロー速度ムラの強さ（設計書§2.1: 既定 0.3）。
    /// v2: 0.3 → 0.5 に強化。速度ムラを強めることで、方向乱流（LivingSky.metal 側）と
    /// 合わせてクロスフェードコピー間の「モーフ感」を補強し、分身の知覚を下げる狙い。
    ///
    /// ⚠️ kernel 引数として渡すだけでなく、下の ROI パディング計算（`pad`）とも連動している。
    ///    シェーダの速度ムラ `flow = turnedDir * (1.0 + speedJitter * (j - 0.5) * 2.0)` は
    ///    fbm(j) の値域（3オクターブ fbm の実質上限 ≈0.875）により実変位を最大
    ///    `(1 + 0.75 * speedJitter) × maxDispPx` まで伸ばすため、この値を変更する場合は
    ///    ROI パディングの計算式も合わせて見直すこと。
    private static let speedJitter: Float = 0.5

    /// フロー速度ムラ用 fbm の空間スケール（設計書§3のシェーダ引数コメント: 例 0.008）
    private static let noiseScale: Float = 0.008

    /// シマー用 fbm の空間スケール（例 0.004）
    private static let shimmerScale: Float = 0.004

    /// シマーの円周サンプリング半径（例 2.0）
    private static let shimmerRadius: Float = 2.0

    /// ROI コールバックの追加余白px（変位量ちょうどだと補間の境界で画素が欠けるため +2 の安全マージン）
    private static let roiPaddingMargin: CGFloat = 2.0

    // MARK: - Properties

    /// `livingSky` カーネル（ロード失敗時は nil）
    private let kernel: CIKernel?

    /// 空マスク生成の実装（差し替え可能。テストでは軽量な実装を注入できる）
    private let maskProvider: SkyMaskProviderProtocol

    /// `prepare` 済みの写真（長辺1080以下に縮小済み）。未 prepare なら nil。
    private(set) var preparedPhoto: CIImage?

    /// `prepare` 済みのフェザー済みマスク。未 prepare なら nil。
    private(set) var preparedMask: CIImage?

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
        let workTask = Task.detached(priority: .userInitiated) { () async throws -> (CIImage, CIImage, Double) in
            try await self.prepareAsync(image: image, quality: quality)
        }
        let (photo, mask, confidence) = try await workTask.value
        self.preparedPhoto = photo
        self.preparedMask = mask
        self.maskConfidence = confidence
    }

    /// `prepare` の処理本体（手順①〜④・Task.detached からオフロードして呼ばれる）
    ///
    /// `maskProvider.makeSkyMask` が async throws のため、この本体も async throws にして
    /// 素直に `await` する（SkyReplacementCompositor.replaceSkySync と同型のパターン）。
    private func prepareAsync(
        image: UIImage,
        quality: SkyMaskQuality
    ) async throws -> (photo: CIImage, mask: CIImage, confidence: Double) {
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

        return (photo, featheredMask, skyMask.confidence)
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
    ///   - confidence: `maskConfidence` に設定する値（既定 1.0 = 高信頼扱い）
    func setPreparedStateForTesting(photo: CIImage, mask: CIImage, confidence: Double = 1.0) {
        self.preparedPhoto = photo
        self.preparedMask = mask
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
        let time01 = Float(safeElapsed.truncatingRemainder(dividingBy: loopDuration) / loopDuration)

        // 風向き（度数）→ ワーキング座標系の単位ベクトル。0°=右向き、反時計回り。
        let angleRad = parameters.windAngleDegrees * .pi / 180
        let dirX = CGFloat(cos(angleRad))
        let dirY = CGFloat(sin(angleRad))

        // 最大変位px = 画像幅 × 0.015 × speed（LivingSkyParameters.maxDisplacementPx 参照）
        let maxDispPx = parameters.maxDisplacementPx(imageWidth: photo.extent.width)
        // ⚠️ 段階3 vision レビュー指摘#1: CIVector として float2 を渡すと Metal general CIKernel の
        // 引数マーシャリングで (0,0) になり「フロー変位が実質ゼロ」になる不具合が実証された。
        // スカラー float（time01/shimmerAmp 等）は正しくマーシャリングされるため、
        // flowDirPx を2つの Float スカラーに分解して渡す（LivingSky.metal 側で float2 に再構成）。
        let flowDirPxX = Float(dirX * maxDispPx)
        let flowDirPxY = Float(dirY * maxDispPx)

        let shimmerAmp = Float(min(max(parameters.shimmerAmount, 0), 0.1))

        // ⚠️ 設計書§3「ROI コールバックが最重要レビューポイント」:
        // 変位サンプリング（p − flow）を行うため、kernel が要求する出力矩形より広い範囲を
        // 入力からサンプルする必要がある。ExposureContrast の `{ _, rect in rect }`
        // （ROI=出力矩形そのまま）をそのまま流用すると、変位でずれた分だけ端に未定義画素
        // （黒 or 透明）が出てしまう。
        //
        // pad は `maxDispPx` そのものではなく `maxDispPx × (1 + speedJitter)` を基準にする:
        // LivingSky.metal の速度ムラ `flow = turnedDir * (1.0 + speedJitter * (j - 0.5) * 2.0)`
        // は fbm(j) の実質上限（3オクターブ fbm ≈0.875）により、実変位を最大
        // `(1 + 0.75 × speedJitter) × maxDispPx`（speedJitter=0.5 なら約1.375倍）まで
        // 伸ばすため、`maxDispPx` ちょうどを基準にすると ROI が実変位を包含しきれない
        // （CoreImage の ROI 契約違反になりうる）。`(1 + speedJitter)`（同条件で1.5倍）は
        // 真の最大倍率 1.375倍を保守的に上回るため安全マージンとして採用する。
        // v3（軌道うねり）でも変更不要: 軌道半径の最大値は `maxDispPx × kOrbitRadiusRatio(0.5) × 1.0`
        // （fbm の変動幅が最大の場合）で常に `maxDispPx` 以下のため、この pad がそのまま包含する。
        let pad = maxDispPx * (1 + CGFloat(Self.speedJitter)) + Self.roiPaddingMargin

        return kernel.apply(
            extent: photo.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -pad, dy: -pad) },
            arguments: [
                // 段階3 vision レビュー指摘#2: 風上側エッジの黒滲み対策（extent外=透明の混入防止）。
                // 変位サンプリング（p − flow）が extent 外に及ぶと sampler は透明を返すため、
                // 端の画素を外側へ引き伸ばす clampedToExtent() を適用する（clamp の定石）。
                // extent: は元の photo.extent のまま（出力範囲は変えない）。
                photo.clampedToExtent(),
                mask,
                time01,
                flowDirPxX,
                flowDirPxY,
                // 動きモデル切替（0=v4窓クロスフェード・ドリフト[既定]／1=v3軌道うねり[比較用]）。
                // LivingSky.metal の引数順（flowDirPxY の直後・shimmerAmp の直前）と厳密一致させる。
                Float(parameters.motionModel),
                shimmerAmp,
                Self.speedJitter,
                Self.noiseScale,
                Self.shimmerScale,
                Self.shimmerRadius
            ]
        )
    }
}
