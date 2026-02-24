//
//  ColorMatching.swift
//  Soramoyou
//
//  色マッチングユーティリティ
//  FirestoreServiceから分離された色距離計算・フィルタリングロジック
//

import Foundation

/// 色マッチング処理を提供するユーティリティ
/// 16進数カラーコードの変換、RGB距離計算、投稿の色フィルタリングを担当
struct ColorMatching {

    // MARK: - RGB型

    /// RGB色空間の各成分（0.0〜1.0）
    typealias RGB = (r: Double, g: Double, b: Double)

    // MARK: - カラー変換

    /// 16進数カラーコード（例: "#FF0000" または "FF0000"）をRGBタプルに変換する
    /// - Parameter hex: 16進数カラーコード文字列
    /// - Returns: RGB値のタプル（各成分は0.0〜1.0）。無効な入力の場合はnil
    static func hexToRGB(_ hex: String) -> RGB? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else {
            return nil
        }

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        return (r: r, g: g, b: b)
    }

    // MARK: - 距離計算

    /// 2つのRGB色間のユークリッド距離を計算する
    /// - Parameters:
    ///   - color1: 1つ目のRGB色
    ///   - color2: 2つ目のRGB色
    /// - Returns: ユークリッド距離（0.0〜sqrt(3.0)の範囲）
    static func calculateRGBDistance(_ color1: RGB, _ color2: RGB) -> Double {
        let dr = color1.r - color2.r
        let dg = color1.g - color2.g
        let db = color1.b - color2.b

        return sqrt(dr * dr + dg * dg + db * db)
    }

    // MARK: - 投稿フィルタリング

    /// 投稿リストをターゲット色との距離でフィルタリングする
    /// 投稿のskyColors内のいずれかの色が閾値以内であれば、その投稿を結果に含める
    /// - Parameters:
    ///   - posts: フィルタリング対象の投稿リスト
    ///   - targetColor: ターゲットの16進数カラーコード
    ///   - threshold: 許容する最大RGB距離
    /// - Returns: 条件を満たす投稿のリスト
    static func filterPostsByColorDistance(posts: [Post], targetColor: String, threshold: Double) -> [Post] {
        guard let targetRGB = hexToRGB(targetColor) else {
            return posts
        }

        return posts.filter { post in
            guard let skyColors = post.skyColors else {
                return false
            }

            // 投稿の色のいずれかが閾値以内の距離にあるかチェック
            return skyColors.contains { color in
                guard let colorRGB = hexToRGB(color) else {
                    return false
                }

                let distance = calculateRGBDistance(targetRGB, colorRGB)
                return distance <= threshold
            }
        }
    }
}
