//
//  EditTool.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation

/// 編集ツールの種類（27種類）
enum EditTool: String, Codable, CaseIterable {
    case exposure = "exposure"
    case brightness = "brightness"
    case contrast = "contrast"
    case tone = "tone"
    case brilliance = "brilliance"
    case highlight = "highlight"
    case shadow = "shadow"
    case blackPoint = "blackPoint"
    case saturation = "saturation"
    case naturalSaturation = "naturalSaturation"
    case warmth = "warmth"
    case tint = "tint"
    case sharpness = "sharpness"
    case vignette = "vignette"
    case colorTemperature = "colorTemperature"
    case whiteBalance = "whiteBalance"
    case texture = "texture"
    case clarity = "clarity"
    case dehaze = "dehaze"
    case grain = "grain"
    case fade = "fade"
    case noiseReduction = "noiseReduction"
    case curves = "curves"
    case hsl = "hsl"
    case lensCorrection = "lensCorrection"
    case doubleExposure = "doubleExposure"
    case cropAndRotate = "cropAndRotate"
    
    /// 表示名
    var displayName: String {
        switch self {
        case .exposure: return "露出"
        case .brightness: return "明るさ"
        case .contrast: return "コントラスト"
        case .tone: return "トーン"
        case .brilliance: return "ブリリアンス"
        case .highlight: return "ハイライト"
        case .shadow: return "シャドウ"
        case .blackPoint: return "ブラックポイント"
        case .saturation: return "彩度"
        case .naturalSaturation: return "自然な彩度"
        case .warmth: return "暖かみ"
        case .tint: return "色合い"
        case .sharpness: return "シャープネス"
        case .vignette: return "ビネット"
        case .colorTemperature: return "色温度"
        case .whiteBalance: return "ホワイトバランス"
        case .texture: return "テクスチャ"
        case .clarity: return "クラリティ"
        case .dehaze: return "かすみの除去"
        case .grain: return "グレイン"
        case .fade: return "フェード"
        case .noiseReduction: return "ノイズリダクション"
        case .curves: return "カーブ調整"
        case .hsl: return "HSL調整"
        case .lensCorrection: return "レンズ補正"
        case .doubleExposure: return "二重露光風合成"
        case .cropAndRotate: return "トリミング・回転"
        }
    }

    /// アイコン名（SF Symbols）
    var iconName: String {
        switch self {
        case .exposure: return "sun.max"
        case .brightness: return "light.max"
        case .contrast: return "circle.lefthalf.filled"
        case .tone: return "waveform.path"
        case .brilliance: return "sparkles"
        case .highlight: return "sun.and.horizon"
        case .shadow: return "moon"
        case .blackPoint: return "circle.bottomhalf.filled"
        case .saturation: return "paintpalette"
        case .naturalSaturation: return "paintpalette.fill"
        case .warmth: return "flame"
        case .tint: return "drop"
        case .sharpness: return "sparkle.magnifyingglass"
        case .vignette: return "circle.dashed"
        case .colorTemperature: return "thermometer"
        case .whiteBalance: return "circle.grid.cross"
        case .texture: return "square.grid.3x3"
        case .clarity: return "eye"
        case .dehaze: return "wind"
        case .grain: return "circle.grid.2x2"
        case .fade: return "circle.lefthalf.striped.horizontal"
        case .noiseReduction: return "waveform.path.ecg"
        case .curves: return "chart.line.uptrend.xyaxis"
        case .hsl: return "slider.horizontal.3"
        case .lensCorrection: return "camera.filters"
        case .doubleExposure: return "square.on.square"
        case .cropAndRotate: return "crop.rotate"
        }
    }
}




