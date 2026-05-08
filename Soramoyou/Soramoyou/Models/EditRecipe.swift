// ⭐️ EditRecipe.swift
// 非破壊編集レシピ（immutable Codable struct）
// EditSettings との後方互換ブリッジを提供
//
//  EditRecipe.swift
//  Soramoyou
//

import Foundation
import CoreImage

/// 非破壊編集レシピ
///
/// 設計方針:
/// - immutable struct: Undo/Redo・状態管理が値コピーで安全に行える
/// - Codable: JSON シリアライズ / Firestore 保存
/// - Equatable: 変更検知・差分更新に使用
/// - `schemaVersion` によるマイグレーション対応
///
/// 値スケール:
/// - 主要フィールドは Core Image フィルターが直接受け取る「物理スケール」で保持
/// - 複合ツールは正規化スケール (-1.0...1.0) で保持し FilterGraphBuilder 内で変換
///
/// 後方互換:
/// - `init(from legacySettings:)` で既存 Firestore データを読み込める
/// - `toEditSettings()` で旧コードへ公開できる
struct EditRecipe: Codable, Equatable {

    // MARK: - メタデータ

    /// JSON スキーマバージョン（破壊的変更時にインクリメント）
    var schemaVersion: Int = 1

    /// レシピフォーマットバージョン（機能追加時に更新）
    var recipeVersion: String = "2026.03"

    // MARK: - 露出・明度系（物理スケール）

    /// 露出調整 EV 値 (-3.0...3.0, default: 0)
    /// CIExposureAdjust.ev に直接渡す
    var exposureEV: Double = 0.0

    /// 明るさ (-0.5...0.5, default: 0)
    /// CIColorControls.brightness に直接渡す
    var brightnessCI: Double = 0.0

    /// コントラスト (0.5...1.5, default: 1.0)
    /// CIColorControls.contrast に直接渡す
    var contrastCI: Double = 1.0

    /// ガンマ/中間調 (0.5...1.5, default: 1.0)
    /// CIGammaAdjust.power に直接渡す（< 1.0 で明るく、> 1.0 で暗く）
    var gamma: Double = 1.0

    // MARK: - ハイライト・シャドウ系（物理スケール）

    /// ハイライト量 (0.0...2.0, default: 1.0)
    /// CIHighlightShadowAdjust.highlightAmount に直接渡す
    var highlights: Double = 1.0

    /// シャドウ量 (0.0...2.0, default: 1.0)
    /// CIHighlightShadowAdjust.shadowAmount に直接渡す
    var shadowAmount: Double = 1.0

    /// ブラックポイント オフセット (-0.15...0.15, default: 0)
    /// CIColorMatrix.biasVector に使用
    var blackPointBias: Double = 0.0

    // MARK: - カラー系（物理スケール）

    /// 彩度 (0.0...2.0, default: 1.0)
    /// CIColorControls.saturation に直接渡す
    var saturationCI: Double = 1.0

    // MARK: - 正規化スケール (-1.0...1.0) の複合ツール

    /// ブリリアンス（正規化）
    var brillianceNorm: Double?

    /// 自然な彩度/ビブランス（正規化）
    var naturalSaturationNorm: Double?

    /// 暖かみ（正規化: 正値→暖色、負値→寒色）
    var warmthNorm: Double?

    /// 色合い/ティント（正規化: 正値→マゼンタ、負値→グリーン）
    var tintNorm: Double?

    /// シャープネス（正規化）
    var sharpnessNorm: Double?

    /// ビネット（正規化）
    var vignetteNorm: Double?

    /// 色温度（正規化）
    var colorTemperatureNorm: Double?

    /// ホワイトバランス（正規化）
    var whiteBalanceNorm: Double?

    /// テクスチャ（正規化）
    var textureNorm: Double?

    /// クラリティ（正規化）
    var clarityNorm: Double?

    /// かすみの除去（正規化）
    var dehazeNorm: Double?

    /// グレイン（正規化）
    var grainNorm: Double?

    /// フェード（正規化）
    var fadeNorm: Double?

    /// ノイズリダクション（正規化）
    var noiseReductionNorm: Double?

    /// カーブ調整（正規化）
    var curvesNorm: Double?

    /// HSL 調整/色相シフト（正規化）
    var hslNorm: Double?

    /// レンズ補正（正規化）
    var lensCorrectionNorm: Double?

    /// 二重露光風合成（正規化）
    var doubleExposureNorm: Double?

    // MARK: - 2D スタイルパッド（iPhone 写真スタイル風 複合ツール）

    /// 2D スタイルパッド Y 軸: トーン（正規化 -1.0...1.0）
    ///
    /// 正値: コントラスト強化 + シャドウ持ち上げ + ハイライト微抑制（iPhone「リッチコントラスト」風）
    /// 負値: コントラスト緩和 + フラット化（フェード風）
    /// nil または 0.0 のとき FilterGraphBuilder はスキップする。
    var style2DToneNorm: Double?

    /// 2D スタイルパッド X 軸: カラー（正規化 -1.0...1.0）
    ///
    /// 正値: 暖色寄り（色温度↑ + 色合いをマゼンタ寄りへ微調整）
    /// 負値: 寒色寄り
    /// nil または 0.0 のとき FilterGraphBuilder はスキップする。
    var style2DColorNorm: Double?

    // MARK: - トーンカーブ

    /// トーンカーブ制御点（5点ベジェ）
    ///
    /// nil のとき FilterGraphBuilder は curvesNorm を使用する。
    /// ToneCurveView で設定されると nil ではなくなる。
    var toneCurvePoints: ToneCurvePoints?

    // MARK: - クロップ

    /// クロップ領域（正規化 0.0〜1.0 の矩形、左上原点）
    ///
    /// - `nil` または `CGRect(0,0,1,1)` の場合はクロップなし
    /// - 回転・反転適用後の画像に対して、この割合で切り出す
    var cropRectNorm: CGRect?

    // MARK: - フィルター

    /// 適用済みフィルター
    var appliedFilter: FilterType?

    // MARK: - ダイナミックレンジ（Phase 2 追加）

    /// 書き出し時のダイナミックレンジ指定
    ///
    /// - `.sdr`（default）: 従来どおり 8bit JPEG / 10bit HEIF（SDR トーンマップ後の表示域）
    /// - `.hdr`: iOS 17+ で `writeHEIF10Representation` + 作業色空間を拡張ガマットで書き出す
    ///
    /// 旧レシピ互換のため Optional。nil は `.sdr` 相当として扱う。
    var targetDynamicRange: DynamicRange?

    // MARK: - タイムスタンプ

    var createdAt: Date?
    var lastModifiedAt: Date?

    // MARK: - デフォルト初期化

    init() {}

    // MARK: - EditSettings からの変換（後方互換）

    /// 非対称パワー曲線でのフォワードマッピング
    ///
    /// 結果 = sign(n) × |n|^p × scale (正/負で異なる p, scale を使用可能)
    ///
    /// パワー指数 p:
    /// - p > 1.0: 0 付近の傾きを抑え、緩やかな立ち上がり（中間域でやさしい効き）
    /// - p < 1.0: 0 付近の傾きを強め、立ち上がりを punchy に（小スライダー操作でも効く）
    /// - p = 1.0: 線形（スケールのみ適用）
    ///
    /// 用途:
    /// - コントラスト負側: pNeg = 2.0 で「白化が急激」現象を緩和
    /// - 明るさ負側: pNeg = 1.5 で暗化の急変を抑制
    /// - 彩度正側: pPos = 0.7 で「+ の効きが緩やか」現象を解消
    private static func asymmetricForward(
        _ n: Double,
        pNeg: Double, scaleNeg: Double,
        pPos: Double, scalePos: Double
    ) -> Double {
        if n > 0 {
            return scalePos * pow(n, pPos)
        } else if n < 0 {
            return -scaleNeg * pow(-n, pNeg)
        } else {
            return 0
        }
    }

    /// `asymmetricForward` の逆関数（物理スケール → 正規化スライダー値）
    private static func asymmetricInverse(
        _ d: Double,
        pNeg: Double, scaleNeg: Double,
        pPos: Double, scalePos: Double
    ) -> Double {
        if d > 0 {
            return pow(d / scalePos, 1.0 / pPos)
        } else if d < 0 {
            return -pow(-d / scaleNeg, 1.0 / pNeg)
        } else {
            return 0
        }
    }

    /// 既存の EditSettings（Firestore 旧データ）から EditRecipe を生成
    ///
    /// 値スケール変換:
    /// - EditSettings: 正規化値 -1.0...1.0
    /// - EditRecipe: Core Image フィルターの物理スケール
    ///
    /// 体感調整 (2026-05 ユーザーフィードバック):
    /// - コントラスト負側を power 2.0 で緩やかに（白化が急激な体感を解消）
    /// - 明るさ負側を power 1.5 で緩やかに（暗化の急変を抑制）
    /// - 彩度正側を power 0.7 + scale 1.5 で punchy に（+ の効きが緩やか問題を解消）
    /// - **既存保存データの見た目は変わらない** (round-trip 保証):
    ///   physical 値 → 新マッピングの逆変換 → スライダー位置 → 新マッピングのフォワード = 同じ physical 値
    init(from legacySettings: EditSettings) {
        // 露出: EV = normalized * 2.0
        self.exposureEV = Double(legacySettings.exposure ?? 0) * 2.0

        // 明るさ: 負側のみ power 1.5 で緩やかに（最大値は ±0.5 据え置き）
        self.brightnessCI = Self.asymmetricForward(
            Double(legacySettings.brightness ?? 0),
            pNeg: 1.5, scaleNeg: 0.5,
            pPos: 1.0, scalePos: 0.5
        )

        // コントラスト: 負側のみ power 2.0 で大きく緩やかに（白化が急激な対策）
        // 最大効き 0.5..1.5 は据え置き、0 付近の傾きだけを抑える
        self.contrastCI = 1.0 + Self.asymmetricForward(
            Double(legacySettings.contrast ?? 0),
            pNeg: 2.0, scaleNeg: 0.5,
            pPos: 1.0, scalePos: 0.5
        )

        // ガンマ: power = 1.0 - normalized * 0.5 (正値→明るく, 負値→暗く)
        self.gamma = 1.0 - Double(legacySettings.tone ?? 0) * 0.5

        // ハイライト: 1.0 + normalized
        self.highlights = 1.0 + Double(legacySettings.highlight ?? 0)

        // シャドウ: 1.0 + normalized
        self.shadowAmount = 1.0 + Double(legacySettings.shadow ?? 0)

        // ブラックポイント: normalized * 0.15
        self.blackPointBias = Double(legacySettings.blackPoint ?? 0) * 0.15

        // 彩度: 正側を power 0.7 + scale 1.5 で punchy に（最大値 2.5 まで拡張）
        // 負側は線形 (scale 1.0) で従来通り
        self.saturationCI = 1.0 + Self.asymmetricForward(
            Double(legacySettings.saturation ?? 0),
            pNeg: 1.0, scaleNeg: 1.0,
            pPos: 0.7, scalePos: 1.5
        )

        // 複合ツール（正規化スケールのまま保持）
        if let v = legacySettings.brilliance   { self.brillianceNorm       = Double(v) }
        if let v = legacySettings.naturalSaturation { self.naturalSaturationNorm = Double(v) }
        if let v = legacySettings.warmth       { self.warmthNorm           = Double(v) }
        if let v = legacySettings.tint         { self.tintNorm             = Double(v) }
        if let v = legacySettings.sharpness    { self.sharpnessNorm        = Double(v) }
        if let v = legacySettings.vignette     { self.vignetteNorm         = Double(v) }
        if let v = legacySettings.colorTemperature { self.colorTemperatureNorm = Double(v) }
        if let v = legacySettings.whiteBalance { self.whiteBalanceNorm     = Double(v) }
        if let v = legacySettings.texture      { self.textureNorm          = Double(v) }
        if let v = legacySettings.clarity      { self.clarityNorm          = Double(v) }
        if let v = legacySettings.dehaze       { self.dehazeNorm           = Double(v) }
        if let v = legacySettings.grain        { self.grainNorm            = Double(v) }
        if let v = legacySettings.fade         { self.fadeNorm             = Double(v) }
        if let v = legacySettings.noiseReduction { self.noiseReductionNorm = Double(v) }
        if let v = legacySettings.curves       { self.curvesNorm           = Double(v) }
        if let v = legacySettings.hsl          { self.hslNorm              = Double(v) }
        if let v = legacySettings.lensCorrection { self.lensCorrectionNorm = Double(v) }
        if let v = legacySettings.doubleExposure { self.doubleExposureNorm = Double(v) }

        self.appliedFilter = legacySettings.appliedFilter
        self.createdAt = Date()
        self.lastModifiedAt = Date()
    }

    // MARK: - EditSettings への変換（後方互換）

    /// 後方互換用: EditRecipe を既存の EditSettings 形式に変換
    ///
    /// EditViewModel の `editSettings` computed property から呼び出す。
    /// View 側のコードを変更せずに EditRecipe へ移行できる。
    func toEditSettings() -> EditSettings {
        // 物理スケール → 正規化スケールへ逆変換
        // 明るさ・コントラスト・彩度は init(from:) と同じ非対称パワー曲線の逆関数を使う
        let exposureNorm   = Float(exposureEV / 2.0)
        let brightnessNorm = Float(Self.asymmetricInverse(
            brightnessCI,
            pNeg: 1.5, scaleNeg: 0.5,
            pPos: 1.0, scalePos: 0.5
        ))
        let contrastNorm   = Float(Self.asymmetricInverse(
            contrastCI - 1.0,
            pNeg: 2.0, scaleNeg: 0.5,
            pPos: 1.0, scalePos: 0.5
        ))
        let toneNorm       = Float((1.0 - gamma) / 0.5)
        let highlightNorm  = Float(highlights - 1.0)
        let shadowNorm     = Float(shadowAmount - 1.0)
        let blackPointNorm = Float(blackPointBias / 0.15)
        let saturationNorm = Float(Self.asymmetricInverse(
            saturationCI - 1.0,
            pNeg: 1.0, scaleNeg: 1.0,
            pPos: 0.7, scalePos: 1.5
        ))

        return EditSettings(
            exposure:          exposureNorm   != 0 ? exposureNorm   : nil,
            brightness:        brightnessNorm != 0 ? brightnessNorm : nil,
            contrast:          contrastNorm   != 0 ? contrastNorm   : nil,
            tone:              toneNorm       != 0 ? toneNorm       : nil,
            brilliance:        brillianceNorm.map       { Float($0) },
            highlight:         highlightNorm  != 0 ? highlightNorm  : nil,
            shadow:            shadowNorm     != 0 ? shadowNorm     : nil,
            blackPoint:        blackPointNorm != 0 ? blackPointNorm : nil,
            saturation:        saturationNorm != 0 ? saturationNorm : nil,
            naturalSaturation: naturalSaturationNorm.map { Float($0) },
            warmth:            warmthNorm.map            { Float($0) },
            tint:              tintNorm.map              { Float($0) },
            sharpness:         sharpnessNorm.map         { Float($0) },
            vignette:          vignetteNorm.map          { Float($0) },
            colorTemperature:  colorTemperatureNorm.map  { Float($0) },
            whiteBalance:      whiteBalanceNorm.map      { Float($0) },
            texture:           textureNorm.map           { Float($0) },
            clarity:           clarityNorm.map           { Float($0) },
            dehaze:            dehazeNorm.map            { Float($0) },
            grain:             grainNorm.map             { Float($0) },
            fade:              fadeNorm.map              { Float($0) },
            noiseReduction:    noiseReductionNorm.map    { Float($0) },
            curves:            curvesNorm.map            { Float($0) },
            hsl:               hslNorm.map               { Float($0) },
            lensCorrection:    lensCorrectionNorm.map    { Float($0) },
            doubleExposure:    doubleExposureNorm.map    { Float($0) },
            appliedFilter:     appliedFilter
        )
    }

    // MARK: - Firestore 保存用辞書変換

    /// Firestore の `editRecipeV1` フィールドに保存するための辞書
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "schemaVersion": schemaVersion,
            "recipeVersion": recipeVersion,
            "exposureEV":    exposureEV,
            "brightnessCI":  brightnessCI,
            "contrastCI":    contrastCI,
            "gamma":         gamma,
            "highlights":    highlights,
            "shadowAmount":  shadowAmount,
            "blackPointBias": blackPointBias,
            "saturationCI":  saturationCI
        ]

        // Optional フィールド
        if let v = brillianceNorm        { data["brillianceNorm"]        = v }
        if let v = naturalSaturationNorm { data["naturalSaturationNorm"] = v }
        if let v = warmthNorm            { data["warmthNorm"]            = v }
        if let v = tintNorm              { data["tintNorm"]              = v }
        if let v = sharpnessNorm         { data["sharpnessNorm"]         = v }
        if let v = vignetteNorm          { data["vignetteNorm"]          = v }
        if let v = colorTemperatureNorm  { data["colorTemperatureNorm"]  = v }
        if let v = whiteBalanceNorm      { data["whiteBalanceNorm"]      = v }
        if let v = textureNorm           { data["textureNorm"]           = v }
        if let v = clarityNorm           { data["clarityNorm"]           = v }
        if let v = dehazeNorm            { data["dehazeNorm"]            = v }
        if let v = grainNorm             { data["grainNorm"]             = v }
        if let v = fadeNorm              { data["fadeNorm"]              = v }
        if let v = noiseReductionNorm    { data["noiseReductionNorm"]    = v }
        if let v = curvesNorm            { data["curvesNorm"]            = v }
        if let v = hslNorm               { data["hslNorm"]               = v }
        if let v = lensCorrectionNorm    { data["lensCorrectionNorm"]    = v }
        if let v = doubleExposureNorm    { data["doubleExposureNorm"]    = v }
        if let v = style2DToneNorm       { data["style2DToneNorm"]       = v }
        if let v = style2DColorNorm      { data["style2DColorNorm"]      = v }
        if let f = appliedFilter         { data["appliedFilter"]         = f.rawValue }
        if let tp = toneCurvePoints      { data["toneCurvePoints"]       = tp.toFirestoreData() }
        if let dr = targetDynamicRange   { data["targetDynamicRange"]    = dr.rawValue }
        if let cr = cropRectNorm {
            data["cropRectNorm"] = [
                "x": cr.origin.x,
                "y": cr.origin.y,
                "w": cr.size.width,
                "h": cr.size.height
            ]
        }

        return data
    }

    /// Firestore の `editRecipeV1` フィールドから復元
    init?(from firestoreData: [String: Any]) {
        guard let sv = firestoreData["schemaVersion"] as? Int else { return nil }
        self.schemaVersion  = sv
        self.recipeVersion  = firestoreData["recipeVersion"]  as? String ?? "2026.03"
        self.exposureEV     = firestoreData["exposureEV"]     as? Double ?? 0.0
        self.brightnessCI   = firestoreData["brightnessCI"]   as? Double ?? 0.0
        self.contrastCI     = firestoreData["contrastCI"]     as? Double ?? 1.0
        self.gamma          = firestoreData["gamma"]          as? Double ?? 1.0
        self.highlights     = firestoreData["highlights"]     as? Double ?? 1.0
        self.shadowAmount   = firestoreData["shadowAmount"]   as? Double ?? 1.0
        self.blackPointBias = firestoreData["blackPointBias"] as? Double ?? 0.0
        self.saturationCI   = firestoreData["saturationCI"]   as? Double ?? 1.0

        self.brillianceNorm        = firestoreData["brillianceNorm"]        as? Double
        self.naturalSaturationNorm = firestoreData["naturalSaturationNorm"] as? Double
        self.warmthNorm            = firestoreData["warmthNorm"]            as? Double
        self.tintNorm              = firestoreData["tintNorm"]              as? Double
        self.sharpnessNorm         = firestoreData["sharpnessNorm"]         as? Double
        self.vignetteNorm          = firestoreData["vignetteNorm"]          as? Double
        self.colorTemperatureNorm  = firestoreData["colorTemperatureNorm"]  as? Double
        self.whiteBalanceNorm      = firestoreData["whiteBalanceNorm"]      as? Double
        self.textureNorm           = firestoreData["textureNorm"]           as? Double
        self.clarityNorm           = firestoreData["clarityNorm"]           as? Double
        self.dehazeNorm            = firestoreData["dehazeNorm"]            as? Double
        self.grainNorm             = firestoreData["grainNorm"]             as? Double
        self.fadeNorm              = firestoreData["fadeNorm"]              as? Double
        self.noiseReductionNorm    = firestoreData["noiseReductionNorm"]    as? Double
        self.curvesNorm            = firestoreData["curvesNorm"]            as? Double
        self.hslNorm               = firestoreData["hslNorm"]               as? Double
        self.lensCorrectionNorm    = firestoreData["lensCorrectionNorm"]    as? Double
        self.doubleExposureNorm    = firestoreData["doubleExposureNorm"]    as? Double
        self.style2DToneNorm       = firestoreData["style2DToneNorm"]       as? Double
        self.style2DColorNorm      = firestoreData["style2DColorNorm"]      as? Double

        if let filterString = firestoreData["appliedFilter"] as? String {
            self.appliedFilter = FilterType(rawValue: filterString)
        }

        // トーンカーブ制御点（Phase 3 追加フィールド）
        if let ptData = firestoreData["toneCurvePoints"] as? [String: Any] {
            self.toneCurvePoints = ToneCurvePoints(from: ptData)
        }

        // ダイナミックレンジ（Phase 2 追加フィールド）
        if let dr = firestoreData["targetDynamicRange"] as? String {
            self.targetDynamicRange = DynamicRange(rawValue: dr)
        }

        // クロップ矩形
        if let cr = firestoreData["cropRectNorm"] as? [String: Any],
           let x = cr["x"] as? Double,
           let y = cr["y"] as? Double,
           let w = cr["w"] as? Double,
           let h = cr["h"] as? Double {
            self.cropRectNorm = CGRect(x: x, y: y, width: w, height: h)
        }
    }
}

// MARK: - DynamicRange

/// 書き出し時のダイナミックレンジ
///
/// Phase 2 で投稿用（SDR JPEG 8bit）と写真保存用（HDR HEIF 10bit）の動線分離に使用する。
enum DynamicRange: String, Codable, Equatable {
    /// Standard Dynamic Range（8bit JPEG / 10bit HEIF の SDR トーン範囲）
    case sdr
    /// High Dynamic Range（iOS 17+ の `writeHEIF10Representation` を使用）
    case hdr
}

// MARK: - CurvePoint

/// トーンカーブ制御点（x: 入力輝度、y: 出力輝度、各 0.0...1.0）
struct CurvePoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

// MARK: - ToneCurvePoints

/// CIToneCurve に渡す 5 点の制御点セット
///
/// デフォルト値はリニア（恒等変換）。
/// `isIdentity` が true のとき FilterGraphBuilder はトーンカーブ処理をスキップできる。
struct ToneCurvePoints: Codable, Equatable {
    var point0: CurvePoint = CurvePoint(x: 0.0,  y: 0.0)
    var point1: CurvePoint = CurvePoint(x: 0.25, y: 0.25)
    var point2: CurvePoint = CurvePoint(x: 0.5,  y: 0.5)
    var point3: CurvePoint = CurvePoint(x: 0.75, y: 0.75)
    var point4: CurvePoint = CurvePoint(x: 1.0,  y: 1.0)

    static let identity = ToneCurvePoints()

    /// すべての点がリニアカーブ（恒等変換）かどうか
    var isIdentity: Bool { self == .identity }

    // MARK: - Firestore 変換

    func toFirestoreData() -> [String: Any] {
        func pt(_ p: CurvePoint) -> [String: Double] { ["x": p.x, "y": p.y] }
        return [
            "point0": pt(point0),
            "point1": pt(point1),
            "point2": pt(point2),
            "point3": pt(point3),
            "point4": pt(point4)
        ]
    }

    init?(from data: [String: Any]) {
        func parse(_ key: String) -> CurvePoint? {
            guard let d = data[key] as? [String: Any],
                  let x = d["x"] as? Double,
                  let y = d["y"] as? Double else { return nil }
            return CurvePoint(x: x, y: y)
        }
        guard let p0 = parse("point0"),
              let p1 = parse("point1"),
              let p2 = parse("point2"),
              let p3 = parse("point3"),
              let p4 = parse("point4") else { return nil }
        self.point0 = p0
        self.point1 = p1
        self.point2 = p2
        self.point3 = p3
        self.point4 = p4
    }

    init() {}
}
