//
//  SoratomoImageEncoder.swift
//  Soramoyou
//
//  ⭐️ そらとも（友達グループで空を共有）の投稿画像の変換
//  写真の元のバイト列から、表示用とサムネイルの JPEG を、メタデータ無し・正立済みで作る
//  （tasks 11.3・design.md の SoratomoImageEncoder・要件 7.1〜7.5・16.1）。
//
//  ⚠️ 位置情報（GPS）などを友達へ渡さないための部品。次の 3 点を崩さないこと。
//     1. 入力は元のバイト列（Data）。UIImage を経由しない（経由すると向きや色の扱いが変わる）。
//     2. 縮小は ImageIO の「サムネイル生成」で行う（向きを画素に反映しつつ、12MP を全画素で展開しない）。
//     3. JPEG の書き出しに渡す属性は圧縮品質だけ（EXIF・GPS・TIFF・XMP を渡さない）。
//        書き出す元の CGImage は画素と色空間しか持たないので、元の写真のメタデータは出力に載らない。
//
//  ⚠️ CPU を使う同期処理。12MP の写真で数百ミリ秒かかるので、メインアクターの外
//     （`Task.detached` など）から呼ぶこと。計測（SoratomoAnalytics）はここでは呼ばない
//     （画面の ViewModel＝tasks 13.x の責務）。
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 投稿する写真を、送信用の 2 枚の JPEG（表示用とサムネイル）に変換する
enum SoratomoImageEncoder {
    // MARK: - 上限（要件 7.1・7.4）

    /// 表示用画像の長辺の上限（ピクセル）
    static let displayMaxPixel = 2048
    /// サムネイルの長辺の上限（ピクセル）
    static let thumbnailMaxPixel = 512
    /// 表示用画像が容量に収まらないときの、作り直しの長辺（ピクセル）
    static let displayFallbackMaxPixel = 1600
    /// 表示用画像の容量の上限（1.5MB = 1,572,864 バイト）
    static let displayMaxBytes = 1_572_864
    /// サムネイルの容量の上限（200KB = 204,800 バイト）
    static let thumbnailMaxBytes = 204_800

    /// JPEG の圧縮品質を試す順番（0.85 から 0.05 ずつ 0.40 まで）
    ///
    /// 最初の 0.85 で上限に収まれば、そこで止める（ふつうの写真は 1 回で終わる）。
    /// 夜空の高感度ノイズなど、収まらない写真だけが下の品質へ進む。
    /// 整数のパーセントから作るのは、0.05 を足し引きする浮動小数点の誤差を避けるため。
    static let qualityLadder: [CGFloat] = stride(from: 85, through: 40, by: -5).map { CGFloat($0) / 100 }

    // MARK: - 変換

    /// 写真の元のバイト列から、表示用とサムネイルの JPEG を作る
    ///
    /// - Parameter source: 写真の元のバイト列（`PHPicker` の `loadFileRepresentation` で取り出したもの）。
    ///   JPEG・HEIC・PNG など、ImageIO が読める形式
    /// - Returns: メタデータ無し・正立済みの 2 枚。`pixelWidth`・`pixelHeight` は表示用画像の画素数
    ///   （長辺 1600px で作り直した場合は、作り直した後の画素数）
    /// - Throws: `.imageUnreadable`（読めない入力）・`.imageTooLarge`（品質を下げきっても、
    ///   長辺 1600px に作り直しても、容量の上限を超える）
    static func encode(source: Data) throws(SoratomoError) -> SoratomoEncodedImages {
        let opened = try openSource(source)

        // 表示用: 長辺 2048px 以下・1.5MB 以下。収まらなければ長辺 1600px で作り直す
        let display = try encodeOne(
            from: opened,
            maxPixel: displayMaxPixel,
            fallbackMaxPixel: displayFallbackMaxPixel,
            maxBytes: displayMaxBytes
        )
        // サムネイル: 長辺 512px 以下・200KB 以下。作り直しの大きさは無い（512px より小さい作り直しは仕様に無い）
        let thumbnail = try encodeOne(
            from: opened,
            maxPixel: thumbnailMaxPixel,
            fallbackMaxPixel: nil,
            maxBytes: thumbnailMaxBytes
        )

        return SoratomoEncodedImages(
            display: display.data,
            thumbnail: thumbnail.data,
            pixelWidth: display.width,
            pixelHeight: display.height
        )
    }

    // MARK: - 内部の部品（テストから呼べるように private にしていない）

    /// 読み込んだ元の写真
    struct OpenedSource {
        /// ImageIO の画像ソース（元のバイト列は保持するが、全画素の展開はまだしていない）
        let source: CGImageSource
        /// 使う画像の番号（複数の画像を持つ HEIC などでは、代表の画像）
        let index: Int
        /// 元の写真の長辺（ピクセル）。向きに依らない値なので、縮小の上限の計算に使える
        let longEdge: Int
    }

    /// 1 枚分の変換結果
    struct EncodedJPEG {
        /// JPEG のバイト列
        let data: Data
        /// 画素の幅
        let width: Int
        /// 画素の高さ
        let height: Int
        /// 採用した圧縮品質
        let quality: CGFloat
    }

    /// 元のバイト列を ImageIO で開き、画像の大きさを読む（全画素は展開しない）
    ///
    /// - Throws: `.imageUnreadable` — 空・画像でない・大きさが読めない入力
    static func openSource(_ data: Data) throws(SoratomoError) -> OpenedSource {
        // 展開した画素をソース側にキャッシュさせない（12MP の全画素を抱え込まないため）
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else {
            throw .imageUnreadable
        }

        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            throw .imageUnreadable
        }

        return OpenedSource(source: source, index: index, longEdge: max(width, height))
    }

    /// 向きを画素に反映しながら、長辺が `maxPixel` 以下の画像を作る
    ///
    /// ImageIO のサムネイル生成を使うので、JPEG などは全画素を展開せずに縮小しながら読める。
    /// 戻り値の CGImage は画素と色空間だけを持ち、元の写真のメタデータ（GPS・EXIF など）は持たない。
    ///
    /// - Parameters:
    ///   - opened: 元の写真
    ///   - maxPixel: 長辺の上限。元の長辺より大きくても、元より大きくはしない
    /// - Returns: 作れなければ nil
    static func renderImage(from opened: OpenedSource, maxPixel: Int) -> CGImage? {
        // 元の写真より小さい上限だけを ImageIO に渡す（小さい写真を引き伸ばさない）
        let limit = min(maxPixel, opened.longEdge)
        let options: [CFString: Any] = [
            // 写真に埋め込まれた小さなサムネイルは使わず、必ず本体の画素から作る
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // 向き（EXIF Orientation）を画素に反映する。反映後は、向きのメタデータが無くても正立して見える
            kCGImageSourceCreateThumbnailWithTransform: true,
            // 展開をこの呼び出しの中で済ませる（書き出しのたびに展開し直さない）
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        return CGImageSourceCreateThumbnailAtIndex(opened.source, opened.index, options as CFDictionary)
    }

    /// CGImage を、圧縮品質だけを指定した JPEG に書き出す
    ///
    /// ⚠️ 渡す属性は圧縮品質だけ。GPS・EXIF・TIFF・XMP などを足さないこと（要件 7.2）。
    ///
    /// - Returns: JPEG のバイト列。書き出せなければ nil
    static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let attributes: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, attributes as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    /// 品質を `qualityLadder` の順に下げながら、`maxBytes` 以下に収まる最初の JPEG を返す
    ///
    /// - Returns: 収まった JPEG と、その圧縮品質。下げきっても収まらなければ nil
    /// - Throws: `.imageUnreadable` — JPEG に書き出せなかった（容量超過とは区別する）
    static func encodeWithinLimit(
        _ image: CGImage,
        maxBytes: Int
    ) throws(SoratomoError) -> (data: Data, quality: CGFloat)? {
        for quality in qualityLadder {
            guard let data = encodeJPEG(image, quality: quality) else {
                throw .imageUnreadable
            }
            if data.count <= maxBytes {
                return (data, quality)
            }
        }
        return nil
    }

    /// 1 枚分（表示用またはサムネイル）の変換
    ///
    /// 1. 長辺 `maxPixel` 以下に縮小し、品質 0.85 から下げながら `maxBytes` に収める
    /// 2. 下げきっても超え、`fallbackMaxPixel` があるときは、その長辺で作り直して同じ手順を 1 回だけやり直す
    /// 3. それでも超えれば失敗する
    ///
    /// - Parameters:
    ///   - opened: 元の写真
    ///   - maxPixel: 長辺の上限
    ///   - fallbackMaxPixel: 作り直しの長辺。nil なら作り直さない
    ///   - maxBytes: 容量の上限（バイト）
    /// - Throws: `.imageUnreadable`（画素を作れない・書き出せない）・`.imageTooLarge`（どうしても収まらない）
    static func encodeOne(
        from opened: OpenedSource,
        maxPixel: Int,
        fallbackMaxPixel: Int?,
        maxBytes: Int
    ) throws(SoratomoError) -> EncodedJPEG {
        guard let image = renderImage(from: opened, maxPixel: maxPixel) else {
            throw .imageUnreadable
        }
        if let fitted = try encodeWithinLimit(image, maxBytes: maxBytes) {
            return EncodedJPEG(data: fitted.data, width: image.width, height: image.height, quality: fitted.quality)
        }

        // ここへ来たのは、品質を下げきっても収まらなかったとき。
        // 作り直しの長辺が、いまの長辺以上なら、同じ大きさを作り直すだけで無駄なので諦める
        guard let fallbackMaxPixel, min(maxPixel, opened.longEdge) > fallbackMaxPixel else {
            throw .imageTooLarge
        }
        guard let smaller = renderImage(from: opened, maxPixel: fallbackMaxPixel) else {
            throw .imageUnreadable
        }
        guard let fitted = try encodeWithinLimit(smaller, maxBytes: maxBytes) else {
            throw .imageTooLarge
        }
        return EncodedJPEG(data: fitted.data, width: smaller.width, height: smaller.height, quality: fitted.quality)
    }
}
