//
//  WidgetSupport.swift
//  SoramoyouWidget
//
//  ウィジェット拡張だけが使う道具一式（本体には入れない）。
//  - WidgetCacheReader : App Group のインデックス（本体が書いたもの）を読むだけ。
//  - WidgetImageLoader : 描画直前に ImageIO でダウンサンプル（メモリ30MB上限対策。Entry に UIImage を積まない）。
//  - SkyGradient       : SkyPhase → 空のグラデ色（Mode C / 写真が無い時のフォールバック）。
//  - WidgetLocation    : 太陽計算用の座標（暫定は東京。位置の dual-write は本体側の後続ステップ）。
//  - WidgetDeepLink    : タップ時に開くアプリ内リンク。
//

import Foundation
import ImageIO
import SwiftUI
import UIKit

// MARK: - キャッシュ読み取り（読むだけ）

enum WidgetCacheReader {
    /// 本体が書いた widget_index.json を読む。無ければ空。
    static func loadIndex() -> WidgetIndex {
        guard let url = AppGroup.indexFileURL,
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(WidgetIndex.self, from: data) else {
            return .empty
        }
        return index
    }

    /// エントリの相対ファイル名を App Group 内の絶対 URL に解決する。
    static func imageURL(for entry: WidgetIndex.Entry) -> URL? {
        AppGroup.imagesDirectoryURL?.appendingPathComponent(entry.imageFileName, isDirectory: false)
    }
}

// MARK: - 画像ローダー（描画直前にダウンサンプル）

enum WidgetImageLoader {
    /// 指定 URL の JPEG を、長辺 `maxPixel` のサムネイルにダウンサンプルして読む。
    /// - Note: 元画像を丸ごと UIImage 化せず ImageIO のサムネイル生成を使う＝メモリピークを抑える
    ///   （ウィジェットは ~30MB で Jetsam されるため必須）。
    static func downsampled(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - 空グラデーション（Mode C / フォールバック）

enum SkyGradient {
    /// 局面ごとの空のグラデ色（上 → 下）。
    static func colors(for phase: SkyPhase) -> [Color] {
        switch phase {
        case .night:
            return [Color(red: 0.04, green: 0.06, blue: 0.16), Color(red: 0.10, green: 0.13, blue: 0.28)]
        case .dawn:
            return [Color(red: 0.20, green: 0.20, blue: 0.38), Color(red: 0.92, green: 0.62, blue: 0.52)]
        case .morning:
            return [Color(red: 0.42, green: 0.68, blue: 0.93), Color(red: 0.83, green: 0.92, blue: 0.99)]
        case .day:
            return [Color(red: 0.22, green: 0.54, blue: 0.92), Color(red: 0.72, green: 0.87, blue: 0.99)]
        case .goldenHour:
            return [Color(red: 0.99, green: 0.72, blue: 0.36), Color(red: 0.96, green: 0.46, blue: 0.40)]
        case .dusk:
            return [Color(red: 0.28, green: 0.24, blue: 0.46), Color(red: 0.78, green: 0.42, blue: 0.48)]
        }
    }

    /// 局面のグラデを SwiftUI の LinearGradient として返す（上 → 下）。
    static func linearGradient(for phase: SkyPhase) -> LinearGradient {
        LinearGradient(colors: colors(for: phase), startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - 位置（太陽計算用・暫定）

enum WidgetLocation {
    /// 東京（フォールバック既定）。
    static let tokyo = (latitude: 35.6762, longitude: 139.6503)

    /// 太陽計算に使う座標。
    /// - 本体がゴールデンアワー通知で取得した粗い現在地を App Group に dual-write していれば、それを読む（Decision 5）。
    /// - 未取得（通知 OFF など）の場合は東京フォールバック。日本国内では局面判定の誤差は小さい（経度差で±数十分）。
    static func current() -> (latitude: Double, longitude: Double) {
        if let record = WidgetLocationStore.read() {
            return (record.latitude, record.longitude)
        }
        return tokyo
    }
}

// MARK: - ディープリンク

enum WidgetDeepLink {
    /// 投稿詳細を開くアプリ内リンク（soramoyou://post/{id}）。
    static func post(_ postId: String?) -> URL? {
        guard let postId, !postId.isEmpty else { return nil }
        return URL(string: "soramoyou://post/\(postId)")
    }
}
