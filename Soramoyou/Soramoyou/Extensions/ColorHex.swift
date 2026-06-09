// ⭐️ ColorHex.swift
// Color / UIColor ⇄ 16進数文字列 の相互変換
//
//  Created on 2026-06-09.
//
//  機能1（気分フレーム）でユーザーがフレーム文字色を自由に選べるようにするため、
//  ColorPicker の `Color` を Firestore 保存用の "#RRGGBB" 文字列へ往復変換する。
//  保存値は後方互換のため文字列。解析不可（旧データ・破損）は nil を返し、呼び出し側で
//  「おまかせ（自動色）」へフォールバックさせる。
//

import SwiftUI
import UIKit

extension UIColor {
    /// "#RRGGBB" / "RRGGBB"（任意で 8 桁 "RRGGBBAA"）から生成する。解析不可なら nil。
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((value & 0xFF0000) >> 16) / 255
            g = CGFloat((value & 0x00FF00) >> 8) / 255
            b = CGFloat(value & 0x0000FF) / 255
            a = 1
        } else {
            r = CGFloat((value & 0xFF000000) >> 24) / 255
            g = CGFloat((value & 0x00FF0000) >> 16) / 255
            b = CGFloat((value & 0x0000FF00) >> 8) / 255
            a = CGFloat(value & 0x000000FF) / 255
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    /// "#RRGGBB" 形式を返す（広色域は sRGB 相当へクランプ）。アルファは無視。
    func toHexString() -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let clamp: (CGFloat) -> Int = { v in max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}

extension Color {
    /// "#RRGGBB" から生成。解析不可なら nil。
    init?(hex: String) {
        guard let ui = UIColor(hex: hex) else { return nil }
        self.init(uiColor: ui)
    }

    /// "#RRGGBB" 形式を返す。
    func toHexString() -> String {
        UIColor(self).toHexString()
    }
}
