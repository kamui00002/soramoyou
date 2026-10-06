//
//  SoratomoImageEncoderTests.swift
//  SoramoyouTests
//
//  ⭐️ そらともの画像の変換（SoratomoImageEncoder・tasks 11.3）のテスト
//  - 出力の 2 枚に、GPS・撮影日時（EXIF）・機種（TIFF）などが残らないこと
//  - 向き 6（右 90 度）の入力が、正立して出ること（縦横が入れ替わり、目印の色の位置が正しい）
//  - 長辺と容量の上限を守ること（品質を下げる段階・長辺 1600px への作り直し・「大きすぎる」の失敗を含む）
//  - 読めない入力が「使えない写真」で失敗すること
//
//  ⚠️ 上限の値（2048・512・1,572,864・204,800）は、本番の定数を参照せず、リテラルで書いている。
//     定数を書き換えても、テストが一緒に動いて通ってしまうことを避けるため。
//  ⚠️ ImageIO の出力の大きさは機種・OS で変わるので、段階の確認は「同じ画像を同じ関数で書き出した実測値」
//     から上限を決めて行う（固定のバイト数を仮定しない）。
//

import CoreGraphics
import ImageIO
@testable import Soramoyou
import UniformTypeIdentifiers
import XCTest

// MARK: - テスト用の部品（このファイルの中だけで使う）

/// 画素の色（4 隅の目印と、色の判定に使う）
private enum SoratomoImageEncoderTestColor: CaseIterable {
    case red
    case green
    case blue
    case yellow

    /// 色の RGB（どれも、JPEG の劣化があっても互いに見分けられる、はっきりした色）
    var rgb: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .red: (r: 255, g: 0, b: 0)
        case .green: (r: 0, g: 255, b: 0)
        case .blue: (r: 0, g: 0, b: 255)
        case .yellow: (r: 255, g: 255, b: 0)
        }
    }
}

/// CGImage を RGBA8（sRGB）の画素として読み出したもの。色の判定に使う
private struct SoratomoImageEncoderPixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            // 恒等の変換で描くと、画像の上の行がメモリの先頭に来る（上から下へ並ぶ）
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(drawn, "画素を読み出す CGContext を作れなかった")
        bytes = buffer
    }

    /// 指定した位置に最も近い目印の色
    func nearestColor(x: Int, y: Int) -> SoratomoImageEncoderTestColor {
        let offset = (y * width + x) * 4
        let r = Int(bytes[offset])
        let g = Int(bytes[offset + 1])
        let b = Int(bytes[offset + 2])

        var best = SoratomoImageEncoderTestColor.red
        var bestDistance = Int.max
        for candidate in SoratomoImageEncoderTestColor.allCases {
            let rgb = candidate.rgb
            let dr = r - Int(rgb.r)
            let dg = g - Int(rgb.g)
            let db = b - Int(rgb.b)
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }
}

/// 入力の画像を作る・出力を読み戻す部品
private enum SoratomoImageEncoderTestSupport {
    /// 入力に書き込む「友達へ渡したくない情報」の目印の文字列。
    /// EXIF・TIFF の文字列は JPEG の中にそのままの文字で入るので、バイト列の検索で残っていないことを確かめられる
    static let privateTokens = [
        "SoratomoTestMake",
        "SoratomoTestModel",
        "SoratomoTestLens",
        "2026:10:04 12:34:56",
    ]

    /// 画素ごとの色を決める関数から、不透明な 8bit RGB の CGImage を作る
    static func makeBitmap(
        width: Int,
        height: Int,
        pixel: (_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8)
    ) throws -> CGImage {
        // 4 バイト目（A）は 255 のまま使わない（noneSkipLast）
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let color = pixel(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = color.r
                bytes[offset + 1] = color.g
                bytes[offset + 2] = color.b
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    /// なめらかなグラデーション（ふつうの写真のように、品質 0.85 で容量に収まる画像）
    static func makeGradientBitmap(width: Int, height: Int) throws -> CGImage {
        try makeBitmap(width: width, height: height) { x, y in
            (r: UInt8(x * 255 / width), g: UInt8(y * 255 / height), b: 160)
        }
    }

    /// 乱数のノイズ（JPEG に圧縮しにくい画像。夜空の高感度ノイズの代わり）。毎回同じ画素になる
    static func makeNoiseBitmap(width: Int, height: Int) throws -> CGImage {
        var state: UInt32 = 12345
        return try makeBitmap(width: width, height: height) { _, _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            let r = UInt8(truncatingIfNeeded: state >> 24)
            state = state &* 1_664_525 &+ 1_013_904_223
            let g = UInt8(truncatingIfNeeded: state >> 24)
            state = state &* 1_664_525 &+ 1_013_904_223
            let b = UInt8(truncatingIfNeeded: state >> 24)
            return (r: r, g: g, b: b)
        }
    }

    /// 4 隅の目印の色（左上=赤・右上=緑・左下=青・右下=黄）
    static func quadrantColor(isTop: Bool, isLeft: Bool) -> SoratomoImageEncoderTestColor {
        switch (isTop, isLeft) {
        case (true, true): .red
        case (true, false): .green
        case (false, true): .blue
        case (false, false): .yellow
        }
    }

    /// GPS・撮影日時・機種・レンズを持たせて JPEG に書き出すための属性
    static func metadataProperties() -> [CFString: Any] {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 35.6586,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 139.7454,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2026:10:04 12:34:56",
            kCGImagePropertyExifLensModel: "SoratomoTestLens",
        ]
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "SoratomoTestMake",
            kCGImagePropertyTIFFModel: "SoratomoTestModel",
        ]
        return [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyGPSDictionary: gps,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
        ]
    }

    /// CGImage を、指定した属性つきの JPEG のバイト列に書き出す（テストの入力を作る）
    static func jpegData(from image: CGImage, properties: [CFString: Any]) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "テスト用の JPEG を書き出せなかった")
        return output as Data
    }

    /// バイト列を、向きを反映せずに画素のまま読み戻す（`CGImageSourceCreateImageAtIndex` は向きを反映しない）
    static func decodeRaw(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// バイト列に入っているメタデータの辞書を読む
    static func properties(of data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    /// バイト列に、ASCII の文字列がそのまま入っているか
    static func contains(_ data: Data, ascii: String) -> Bool {
        data.range(of: Data(ascii.utf8)) != nil
    }

    /// 出力の JPEG に、GPS・撮影日時・機種・レンズ・XMP が無いこと
    static func assertNoPrivateMetadata(
        in data: Data,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // JPEG の先頭は FF D8
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "\(label): JPEG ではない", file: file, line: line)

        let props = try properties(of: data)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "\(label): GPS が残っている", file: file, line: line)
        XCTAssertNil(props[kCGImagePropertyIPTCDictionary], "\(label): IPTC が残っている", file: file, line: line)
        XCTAssertNil(props[kCGImagePropertyMakerAppleDictionary], "\(label): メーカー独自の情報が残っている", file: file, line: line)

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal], "\(label): EXIF の撮影日時が残っている", file: file, line: line)
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeDigitized], "\(label): EXIF のデジタル化日時が残っている", file: file, line: line)
        XCTAssertNil(exif?[kCGImagePropertyExifLensModel], "\(label): EXIF のレンズ機種が残っている", file: file, line: line)
        XCTAssertNil(exif?[kCGImagePropertyExifLensMake], "\(label): EXIF のレンズメーカーが残っている", file: file, line: line)

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake], "\(label): TIFF のメーカーが残っている", file: file, line: line)
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel], "\(label): TIFF の機種が残っている", file: file, line: line)
        XCTAssertNil(tiff?[kCGImagePropertyTIFFDateTime], "\(label): TIFF の日時が残っている", file: file, line: line)

        // 辞書として読めない形で残っていないかを、バイト列そのものでも確かめる
        for token in privateTokens {
            XCTAssertFalse(contains(data, ascii: token), "\(label): バイト列に「\(token)」が残っている", file: file, line: line)
        }
        XCTAssertFalse(contains(data, ascii: "<x:xmpmeta"), "\(label): XMP が残っている", file: file, line: line)
        XCTAssertFalse(contains(data, ascii: "ns.adobe.com/xap"), "\(label): XMP が残っている", file: file, line: line)
    }
}

private typealias Support = SoratomoImageEncoderTestSupport

// MARK: - テスト本体

final class SoratomoImageEncoderTests: XCTestCase {
    // MARK: - メタデータの除去（要件 7.2）

    func testOutputsCarryNoPrivateMetadata() throws {
        let image = try Support.makeGradientBitmap(width: 800, height: 600)
        let input = try Support.jpegData(from: image, properties: Support.metadataProperties())

        // 陽性対照: 入力には、本当に GPS・撮影日時・機種が入っている。
        // 入っていなければ、下の「出力に無い」は何も証明しない（テストの前提が崩れている）
        let inputProps = try Support.properties(of: input)
        XCTAssertNotNil(inputProps[kCGImagePropertyGPSDictionary], "入力に GPS を書けていない")
        let inputExif = inputProps[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(inputExif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:10:04 12:34:56")
        let inputTiff = inputProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(inputTiff?[kCGImagePropertyTIFFMake] as? String, "SoratomoTestMake")
        XCTAssertEqual(inputTiff?[kCGImagePropertyTIFFModel] as? String, "SoratomoTestModel")
        for token in Support.privateTokens {
            XCTAssertTrue(Support.contains(input, ascii: token), "入力のバイト列に「\(token)」が無い（検索が効かない）")
        }

        let output = try SoratomoImageEncoder.encode(source: input)

        try Support.assertNoPrivateMetadata(in: output.display, label: "表示用")
        try Support.assertNoPrivateMetadata(in: output.thumbnail, label: "サムネイル")
    }

    // MARK: - 向き（要件 7.3）

    func testRightOrientedInputComesOutUpright() throws {
        // 横長 1000x600 の 4 隅に色を置き、向き 6（右 90 度）を付けて入れる。
        // 正しく表示すると、時計回りに 90 度回った 600x1000 の縦長になる
        let raw = try Support.makeBitmap(width: 1000, height: 600) { x, y in
            Support.quadrantColor(isTop: y < 300, isLeft: x < 500).rgb
        }
        let input = try Support.jpegData(
            from: raw,
            properties: [
                kCGImagePropertyOrientation: 6,
                kCGImageDestinationLossyCompressionQuality: 0.95,
            ]
        )

        // 陽性対照: 入力は、画素が横長のまま、向き 6 が付いている（向きを直さないと横向きに見える）
        let inputRaw = try Support.decodeRaw(input)
        XCTAssertEqual(inputRaw.width, 1000)
        XCTAssertEqual(inputRaw.height, 600)
        let inputProps = try Support.properties(of: input)
        XCTAssertEqual(inputProps[kCGImagePropertyOrientation] as? Int, 6, "入力に向き 6 を書けていない")

        let output = try SoratomoImageEncoder.encode(source: input)

        // 表示用: 長辺 1000 は 2048 以下なので縮小されず、縦横だけが入れ替わる
        XCTAssertEqual(output.pixelWidth, 600)
        XCTAssertEqual(output.pixelHeight, 1000)
        let display = try assertUpright(output.display, label: "表示用")
        XCTAssertEqual(display.width, 600)
        XCTAssertEqual(display.height, 1000)

        // サムネイル: 長辺 512 に縮み、縦長（幅 < 高さ）で、縦横比が 0.6 のまま
        let thumbnail = try assertUpright(output.thumbnail, label: "サムネイル")
        XCTAssertEqual(max(thumbnail.width, thumbnail.height), 512)
        XCTAssertLessThan(thumbnail.width, thumbnail.height)
        XCTAssertEqual(Double(thumbnail.width) / Double(thumbnail.height), 0.6, accuracy: 0.02)
    }

    /// 出力が正立していること（向きのメタデータが無く、4 隅の色が回転後の位置にある）を確かめ、読み戻した画素を返す
    private func assertUpright(_ data: Data, label: String) throws -> CGImage {
        // 向きのメタデータが残っていると、画素が回転済みなので二重に回って見える
        let props = try Support.properties(of: data)
        let orientation = props[kCGImagePropertyOrientation] as? Int
        XCTAssertTrue(orientation == nil || orientation == 1, "\(label): 向きのメタデータが残っている（\(String(describing: orientation))）")

        let image = try Support.decodeRaw(data)
        let pixels = try SoratomoImageEncoderPixels(image)
        let w = pixels.width
        let h = pixels.height
        // 元の左上（赤）は右上へ、右上（緑）は右下へ、右下（黄）は左下へ、左下（青）は左上へ動く
        XCTAssertEqual(pixels.nearestColor(x: w / 4, y: h / 4), .blue, "\(label): 左上は青のはず")
        XCTAssertEqual(pixels.nearestColor(x: w * 3 / 4, y: h / 4), .red, "\(label): 右上は赤のはず")
        XCTAssertEqual(pixels.nearestColor(x: w * 3 / 4, y: h * 3 / 4), .green, "\(label): 右下は緑のはず")
        XCTAssertEqual(pixels.nearestColor(x: w / 4, y: h * 3 / 4), .yellow, "\(label): 左下は黄のはず")
        return image
    }

    // MARK: - 長辺と容量（要件 7.1・7.4）

    func testLargeInputRespectsLongEdgeAndByteLimits() throws {
        let image = try Support.makeGradientBitmap(width: 3000, height: 2000)
        let input = try Support.jpegData(from: image, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])

        let output = try SoratomoImageEncoder.encode(source: input)

        let display = try Support.decodeRaw(output.display)
        let thumbnail = try Support.decodeRaw(output.thumbnail)
        let displayLongEdge = max(display.width, display.height)
        let thumbnailLongEdge = max(thumbnail.width, thumbnail.height)

        // 長辺は上限以下で、上限に近い大きさで作られている（縮小しすぎていない）
        XCTAssertLessThanOrEqual(displayLongEdge, 2048)
        XCTAssertGreaterThan(displayLongEdge, 2000)
        XCTAssertLessThanOrEqual(thumbnailLongEdge, 512)
        XCTAssertGreaterThan(thumbnailLongEdge, 480)
        // 縦横比は保たれる（3000:2000 = 1.5）
        XCTAssertEqual(Double(display.width) / Double(display.height), 1.5, accuracy: 0.01)
        XCTAssertEqual(Double(thumbnail.width) / Double(thumbnail.height), 1.5, accuracy: 0.02)
        // 容量は上限以下
        XCTAssertLessThanOrEqual(output.display.count, 1_572_864)
        XCTAssertLessThanOrEqual(output.thumbnail.count, 204_800)
        // 返す画素数は、表示用画像の実際の画素数
        XCTAssertEqual(output.pixelWidth, display.width)
        XCTAssertEqual(output.pixelHeight, display.height)
    }

    func testSmallInputIsNotUpscaled() throws {
        let image = try Support.makeGradientBitmap(width: 300, height: 200)
        let input = try Support.jpegData(from: image, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])

        let output = try SoratomoImageEncoder.encode(source: input)

        // 上限（2048・512）より小さい写真は、引き伸ばさない
        let display = try Support.decodeRaw(output.display)
        let thumbnail = try Support.decodeRaw(output.thumbnail)
        XCTAssertEqual(display.width, 300)
        XCTAssertEqual(display.height, 200)
        XCTAssertEqual(thumbnail.width, 300)
        XCTAssertEqual(thumbnail.height, 200)
    }

    func testNoisyInputNeverYieldsAnOversizedImage() throws {
        // ノイズの多い写真は、品質を下げても収まらないことがある。どちらになっても、
        // 上限を超える画像を返さず、収まらなければ「大きすぎる」で失敗すること
        let noise = try Support.makeNoiseBitmap(width: 2200, height: 1500)
        let input = try Support.jpegData(from: noise, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])

        var encoded: SoratomoEncodedImages?
        do {
            encoded = try SoratomoImageEncoder.encode(source: input)
        } catch {
            XCTAssertEqual(error, .imageTooLarge)
        }
        // 「大きすぎる」で失敗した場合は、上の確認で終わり
        guard let output = encoded else { return }

        XCTAssertLessThanOrEqual(output.display.count, 1_572_864)
        XCTAssertLessThanOrEqual(output.thumbnail.count, 204_800)
        let display = try Support.decodeRaw(output.display)
        let thumbnail = try Support.decodeRaw(output.thumbnail)
        XCTAssertLessThanOrEqual(max(display.width, display.height), 2048)
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 512)
    }

    // MARK: - 品質を下げる段階（要件 7.4）

    func testQualityIsLoweredStepByStepUntilItFits() throws {
        let image = try Support.makeNoiseBitmap(width: 512, height: 512)
        let ladder = SoratomoImageEncoder.qualityLadder
        let firstQuality = try XCTUnwrap(ladder.first)
        let floorQuality = try XCTUnwrap(ladder.last)

        // 同じ画像を、最初の品質と最後の品質で書き出した実測値から、上限を決める
        let atFirst = try XCTUnwrap(SoratomoImageEncoder.encodeJPEG(image, quality: firstQuality))
        let atFloor = try XCTUnwrap(SoratomoImageEncoder.encodeJPEG(image, quality: floorQuality))
        XCTAssertGreaterThan(atFirst.count, atFloor.count, "前提: 品質を下げると小さくなる画像")

        // 最初の品質で収まる上限 → 最初の品質（0.85）のまま
        let unchanged = try XCTUnwrap(try SoratomoImageEncoder.encodeWithinLimit(image, maxBytes: atFirst.count))
        XCTAssertEqual(unchanged.quality, 0.85, accuracy: 0.0001)
        XCTAssertEqual(unchanged.data, atFirst)

        // 最初の品質では収まらず、最後の品質なら収まる上限 → 品質が下がり、上限以下になる
        let middleLimit = (atFirst.count + atFloor.count) / 2
        let lowered = try XCTUnwrap(try SoratomoImageEncoder.encodeWithinLimit(image, maxBytes: middleLimit))
        XCTAssertLessThan(lowered.quality, 0.85)
        XCTAssertGreaterThanOrEqual(lowered.quality, floorQuality)
        XCTAssertLessThanOrEqual(lowered.data.count, middleLimit)

        // 最後の品質でも収まらない上限 → 収まる品質が無い（nil）
        let impossible = try SoratomoImageEncoder.encodeWithinLimit(image, maxBytes: atFloor.count - 1)
        XCTAssertNil(impossible)
    }

    // MARK: - 長辺 1600px への作り直しと「大きすぎる」（要件 7.4）

    /// 小さな大きさで、作り直しの動きを確かめるための入力（長辺 600px のノイズ）を開く
    private func openNoiseSource() throws -> SoratomoImageEncoder.OpenedSource {
        let noise = try Support.makeNoiseBitmap(width: 600, height: 400)
        let data = try Support.jpegData(from: noise, properties: [kCGImageDestinationLossyCompressionQuality: 0.95])
        return try SoratomoImageEncoder.openSource(data)
    }

    /// 下げきった品質で、長辺 400px と 300px に作ったときの JPEG の容量（上限を決める実測値）
    private func floorSizes(of opened: SoratomoImageEncoder.OpenedSource) throws -> (big: Int, small: Int) {
        let floorQuality = try XCTUnwrap(SoratomoImageEncoder.qualityLadder.last)
        let big = try XCTUnwrap(SoratomoImageEncoder.renderImage(from: opened, maxPixel: 400))
        let small = try XCTUnwrap(SoratomoImageEncoder.renderImage(from: opened, maxPixel: 300))
        let bigData = try XCTUnwrap(SoratomoImageEncoder.encodeJPEG(big, quality: floorQuality))
        let smallData = try XCTUnwrap(SoratomoImageEncoder.encodeJPEG(small, quality: floorQuality))
        return (bigData.count, smallData.count)
    }

    func testFallsBackToSmallerLongEdgeWhenQualityIsExhausted() throws {
        let opened = try openNoiseSource()
        let sizes = try floorSizes(of: opened)
        XCTAssertGreaterThan(sizes.big, sizes.small, "前提: 小さく作ると容量も小さくなる")

        // 長辺 400px では下げきっても収まらず、長辺 300px なら収まる上限
        let limit = (sizes.big + sizes.small) / 2

        // 作り直しの長辺（300px）を渡すと、作り直して収まる
        let result = try SoratomoImageEncoder.encodeOne(from: opened, maxPixel: 400, fallbackMaxPixel: 300, maxBytes: limit)
        XCTAssertLessThanOrEqual(max(result.width, result.height), 300)
        XCTAssertGreaterThan(max(result.width, result.height), 290)
        XCTAssertLessThanOrEqual(result.data.count, limit)

        // 陽性対照: 同じ上限でも、作り直しの長辺が無ければ「大きすぎる」で失敗する
        // （収まったのが、作り直しのおかげだと分かる）
        do {
            _ = try SoratomoImageEncoder.encodeOne(from: opened, maxPixel: 400, fallbackMaxPixel: nil, maxBytes: limit)
            XCTFail("作り直さなければ、収まらないはず")
        } catch {
            XCTAssertEqual(error, .imageTooLarge)
        }
    }

    func testThrowsImageTooLargeWhenEvenTheFallbackDoesNotFit() throws {
        let opened = try openNoiseSource()
        let sizes = try floorSizes(of: opened)

        // 作り直した長辺 300px でも、下げきった品質で 1 バイト足りない上限
        do {
            _ = try SoratomoImageEncoder.encodeOne(from: opened, maxPixel: 400, fallbackMaxPixel: 300, maxBytes: sizes.small - 1)
            XCTFail("作り直しても収まらないはず")
        } catch {
            XCTAssertEqual(error, .imageTooLarge)
        }
    }

    // MARK: - 読めない入力（要件 7.5）

    /// 変換して、失敗の種類を返す（成功したら nil）
    private func encodeFailure(of source: Data) -> SoratomoError? {
        do {
            _ = try SoratomoImageEncoder.encode(source: source)
            return nil
        } catch {
            return error
        }
    }

    func testUnreadableInputThrowsImageUnreadable() throws {
        // 空
        XCTAssertEqual(encodeFailure(of: Data()), .imageUnreadable)
        // 画像でない文字列
        XCTAssertEqual(encodeFailure(of: Data("これは画像ではありません".utf8)), .imageUnreadable)
        // 画像の形式の目印を持たないバイト列
        XCTAssertEqual(encodeFailure(of: Data((0 ..< 256).map { UInt8($0) })), .imageUnreadable)

        // 陽性対照: 壊していない元の画像は、読める
        let image = try Support.makeGradientBitmap(width: 200, height: 100)
        let valid = try Support.jpegData(from: image, properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
        XCTAssertNil(encodeFailure(of: valid), "壊していない JPEG は変換できるはず")
        // 先頭の 20 バイトだけに切った JPEG（画像の大きさも画素も無い）
        XCTAssertEqual(encodeFailure(of: Data(valid.prefix(20))), .imageUnreadable)
    }

    // MARK: - 上限の値

    func testLimitsMatchTheSpecification() {
        XCTAssertEqual(SoratomoImageEncoder.displayMaxPixel, 2048)
        XCTAssertEqual(SoratomoImageEncoder.thumbnailMaxPixel, 512)
        XCTAssertEqual(SoratomoImageEncoder.displayFallbackMaxPixel, 1600)
        XCTAssertEqual(SoratomoImageEncoder.displayMaxBytes, 1_572_864)
        XCTAssertEqual(SoratomoImageEncoder.thumbnailMaxBytes, 204_800)

        // 品質は 0.85 から始まり、単調に下がる
        let ladder = SoratomoImageEncoder.qualityLadder
        XCTAssertEqual(ladder.first ?? 0, 0.85, accuracy: 0.0001)
        XCTAssertGreaterThan(ladder.count, 1)
        XCTAssertEqual(ladder, ladder.sorted(by: >))
    }
}
