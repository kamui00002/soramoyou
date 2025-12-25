//
//  EditSettings.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation

/// 編集設定Value Object
struct EditSettings: Codable, Equatable {
    var brightness: Float?
    var contrast: Float?
    var saturation: Float?
    var exposure: Float?
    var highlight: Float?
    var shadow: Float?
    var warmth: Float?
    var sharpness: Float?
    var vignette: Float?
    var appliedFilter: FilterType?
    
    // 27種類の編集ツールのパラメータを保持
    // 必要に応じて追加のプロパティを定義
    
    init(
        brightness: Float? = nil,
        contrast: Float? = nil,
        saturation: Float? = nil,
        exposure: Float? = nil,
        highlight: Float? = nil,
        shadow: Float? = nil,
        warmth: Float? = nil,
        sharpness: Float? = nil,
        vignette: Float? = nil,
        appliedFilter: FilterType? = nil
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.exposure = exposure
        self.highlight = highlight
        self.shadow = shadow
        self.warmth = warmth
        self.sharpness = sharpness
        self.vignette = vignette
        self.appliedFilter = appliedFilter
    }
    
    /// 特定の編集ツールの値を取得
    func value(for tool: EditTool) -> Float? {
        switch tool {
        case .brightness: return brightness
        case .contrast: return contrast
        case .saturation: return saturation
        case .exposure: return exposure
        case .highlight: return highlight
        case .shadow: return shadow
        case .warmth: return warmth
        case .sharpness: return sharpness
        case .vignette: return vignette
        default: return nil
        }
    }
    
    /// 特定の編集ツールの値を設定
    mutating func setValue(_ value: Float?, for tool: EditTool) {
        switch tool {
        case .brightness: self.brightness = value
        case .contrast: self.contrast = value
        case .saturation: self.saturation = value
        case .exposure: self.exposure = value
        case .highlight: self.highlight = value
        case .shadow: self.shadow = value
        case .warmth: self.warmth = value
        case .sharpness: self.sharpness = value
        case .vignette: self.vignette = value
        default: break
        }
    }
    
    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [:]
        
        if let brightness = brightness {
            data["brightness"] = brightness
        }
        if let contrast = contrast {
            data["contrast"] = contrast
        }
        if let saturation = saturation {
            data["saturation"] = saturation
        }
        if let exposure = exposure {
            data["exposure"] = exposure
        }
        if let highlight = highlight {
            data["highlight"] = highlight
        }
        if let shadow = shadow {
            data["shadow"] = shadow
        }
        if let warmth = warmth {
            data["warmth"] = warmth
        }
        if let sharpness = sharpness {
            data["sharpness"] = sharpness
        }
        if let vignette = vignette {
            data["vignette"] = vignette
        }
        if let appliedFilter = appliedFilter {
            data["appliedFilter"] = appliedFilter.rawValue
        }
        
        return data
    }
    
    /// Firestoreドキュメントデータから初期化
    init?(from documentData: [String: Any]) {
        self.brightness = documentData["brightness"] as? Float
        self.contrast = documentData["contrast"] as? Float
        self.saturation = documentData["saturation"] as? Float
        self.exposure = documentData["exposure"] as? Float
        self.highlight = documentData["highlight"] as? Float
        self.shadow = documentData["shadow"] as? Float
        self.warmth = documentData["warmth"] as? Float
        self.sharpness = documentData["sharpness"] as? Float
        self.vignette = documentData["vignette"] as? Float
        
        if let filterString = documentData["appliedFilter"] as? String {
            self.appliedFilter = FilterType(rawValue: filterString)
        }
    }
}




