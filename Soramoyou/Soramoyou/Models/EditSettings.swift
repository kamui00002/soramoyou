//
//  EditSettings.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation

/// 編集設定Value Object（全27種類の編集ツールパラメータを保持）
struct EditSettings: Codable, Equatable {
    // MARK: - トーン・露出系（5種類）
    var exposure: Float?
    var brightness: Float?
    var contrast: Float?
    var tone: Float?
    var brilliance: Float?

    // MARK: - ハイライト・シャドウ系（3種類）
    var highlight: Float?
    var shadow: Float?
    var blackPoint: Float?

    // MARK: - カラー・彩度系（4種類）
    var saturation: Float?
    var naturalSaturation: Float?
    var warmth: Float?
    var tint: Float?

    // MARK: - ディテール・鮮明度系（4種類）
    var sharpness: Float?
    var vignette: Float?
    var colorTemperature: Float?
    var whiteBalance: Float?

    // MARK: - テクスチャ・エフェクト系（7種類）
    var texture: Float?
    var clarity: Float?
    var dehaze: Float?
    var grain: Float?
    var fade: Float?
    var noiseReduction: Float?
    var curves: Float?

    // MARK: - アドバンスド系（3種類）
    var hsl: Float?
    var lensCorrection: Float?
    var doubleExposure: Float?
    // cropAndRotate は EditViewModel で個別管理

    // MARK: - フィルター
    var appliedFilter: FilterType?

    init(
        exposure: Float? = nil,
        brightness: Float? = nil,
        contrast: Float? = nil,
        tone: Float? = nil,
        brilliance: Float? = nil,
        highlight: Float? = nil,
        shadow: Float? = nil,
        blackPoint: Float? = nil,
        saturation: Float? = nil,
        naturalSaturation: Float? = nil,
        warmth: Float? = nil,
        tint: Float? = nil,
        sharpness: Float? = nil,
        vignette: Float? = nil,
        colorTemperature: Float? = nil,
        whiteBalance: Float? = nil,
        texture: Float? = nil,
        clarity: Float? = nil,
        dehaze: Float? = nil,
        grain: Float? = nil,
        fade: Float? = nil,
        noiseReduction: Float? = nil,
        curves: Float? = nil,
        hsl: Float? = nil,
        lensCorrection: Float? = nil,
        doubleExposure: Float? = nil,
        appliedFilter: FilterType? = nil
    ) {
        self.exposure = exposure
        self.brightness = brightness
        self.contrast = contrast
        self.tone = tone
        self.brilliance = brilliance
        self.highlight = highlight
        self.shadow = shadow
        self.blackPoint = blackPoint
        self.saturation = saturation
        self.naturalSaturation = naturalSaturation
        self.warmth = warmth
        self.tint = tint
        self.sharpness = sharpness
        self.vignette = vignette
        self.colorTemperature = colorTemperature
        self.whiteBalance = whiteBalance
        self.texture = texture
        self.clarity = clarity
        self.dehaze = dehaze
        self.grain = grain
        self.fade = fade
        self.noiseReduction = noiseReduction
        self.curves = curves
        self.hsl = hsl
        self.lensCorrection = lensCorrection
        self.doubleExposure = doubleExposure
        self.appliedFilter = appliedFilter
    }

    /// 特定の編集ツールの値を取得
    func value(for tool: EditTool) -> Float? {
        switch tool {
        case .exposure: return exposure
        case .brightness: return brightness
        case .contrast: return contrast
        case .tone: return tone
        case .brilliance: return brilliance
        case .highlight: return highlight
        case .shadow: return shadow
        case .blackPoint: return blackPoint
        case .saturation: return saturation
        case .naturalSaturation: return naturalSaturation
        case .warmth: return warmth
        case .tint: return tint
        case .sharpness: return sharpness
        case .vignette: return vignette
        case .colorTemperature: return colorTemperature
        case .whiteBalance: return whiteBalance
        case .texture: return texture
        case .clarity: return clarity
        case .dehaze: return dehaze
        case .grain: return grain
        case .fade: return fade
        case .noiseReduction: return noiseReduction
        case .curves: return curves
        case .hsl: return hsl
        case .lensCorrection: return lensCorrection
        case .doubleExposure: return doubleExposure
        case .cropAndRotate: return nil
        }
    }

    /// 特定の編集ツールの値を設定
    mutating func setValue(_ value: Float?, for tool: EditTool) {
        switch tool {
        case .exposure: self.exposure = value
        case .brightness: self.brightness = value
        case .contrast: self.contrast = value
        case .tone: self.tone = value
        case .brilliance: self.brilliance = value
        case .highlight: self.highlight = value
        case .shadow: self.shadow = value
        case .blackPoint: self.blackPoint = value
        case .saturation: self.saturation = value
        case .naturalSaturation: self.naturalSaturation = value
        case .warmth: self.warmth = value
        case .tint: self.tint = value
        case .sharpness: self.sharpness = value
        case .vignette: self.vignette = value
        case .colorTemperature: self.colorTemperature = value
        case .whiteBalance: self.whiteBalance = value
        case .texture: self.texture = value
        case .clarity: self.clarity = value
        case .dehaze: self.dehaze = value
        case .grain: self.grain = value
        case .fade: self.fade = value
        case .noiseReduction: self.noiseReduction = value
        case .curves: self.curves = value
        case .hsl: self.hsl = value
        case .lensCorrection: self.lensCorrection = value
        case .doubleExposure: self.doubleExposure = value
        case .cropAndRotate: break
        }
    }

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [:]

        if let exposure = exposure { data["exposure"] = exposure }
        if let brightness = brightness { data["brightness"] = brightness }
        if let contrast = contrast { data["contrast"] = contrast }
        if let tone = tone { data["tone"] = tone }
        if let brilliance = brilliance { data["brilliance"] = brilliance }
        if let highlight = highlight { data["highlight"] = highlight }
        if let shadow = shadow { data["shadow"] = shadow }
        if let blackPoint = blackPoint { data["blackPoint"] = blackPoint }
        if let saturation = saturation { data["saturation"] = saturation }
        if let naturalSaturation = naturalSaturation { data["naturalSaturation"] = naturalSaturation }
        if let warmth = warmth { data["warmth"] = warmth }
        if let tint = tint { data["tint"] = tint }
        if let sharpness = sharpness { data["sharpness"] = sharpness }
        if let vignette = vignette { data["vignette"] = vignette }
        if let colorTemperature = colorTemperature { data["colorTemperature"] = colorTemperature }
        if let whiteBalance = whiteBalance { data["whiteBalance"] = whiteBalance }
        if let texture = texture { data["texture"] = texture }
        if let clarity = clarity { data["clarity"] = clarity }
        if let dehaze = dehaze { data["dehaze"] = dehaze }
        if let grain = grain { data["grain"] = grain }
        if let fade = fade { data["fade"] = fade }
        if let noiseReduction = noiseReduction { data["noiseReduction"] = noiseReduction }
        if let curves = curves { data["curves"] = curves }
        if let hsl = hsl { data["hsl"] = hsl }
        if let lensCorrection = lensCorrection { data["lensCorrection"] = lensCorrection }
        if let doubleExposure = doubleExposure { data["doubleExposure"] = doubleExposure }
        if let appliedFilter = appliedFilter { data["appliedFilter"] = appliedFilter.rawValue }

        return data
    }

    /// Firestoreドキュメントデータから初期化
    init?(from documentData: [String: Any]) {
        self.exposure = documentData["exposure"] as? Float
        self.brightness = documentData["brightness"] as? Float
        self.contrast = documentData["contrast"] as? Float
        self.tone = documentData["tone"] as? Float
        self.brilliance = documentData["brilliance"] as? Float
        self.highlight = documentData["highlight"] as? Float
        self.shadow = documentData["shadow"] as? Float
        self.blackPoint = documentData["blackPoint"] as? Float
        self.saturation = documentData["saturation"] as? Float
        self.naturalSaturation = documentData["naturalSaturation"] as? Float
        self.warmth = documentData["warmth"] as? Float
        self.tint = documentData["tint"] as? Float
        self.sharpness = documentData["sharpness"] as? Float
        self.vignette = documentData["vignette"] as? Float
        self.colorTemperature = documentData["colorTemperature"] as? Float
        self.whiteBalance = documentData["whiteBalance"] as? Float
        self.texture = documentData["texture"] as? Float
        self.clarity = documentData["clarity"] as? Float
        self.dehaze = documentData["dehaze"] as? Float
        self.grain = documentData["grain"] as? Float
        self.fade = documentData["fade"] as? Float
        self.noiseReduction = documentData["noiseReduction"] as? Float
        self.curves = documentData["curves"] as? Float
        self.hsl = documentData["hsl"] as? Float
        self.lensCorrection = documentData["lensCorrection"] as? Float
        self.doubleExposure = documentData["doubleExposure"] as? Float

        if let filterString = documentData["appliedFilter"] as? String {
            self.appliedFilter = FilterType(rawValue: filterString)
        }
    }
}
