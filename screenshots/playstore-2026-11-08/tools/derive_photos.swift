// ⭐️ Play のスクリーンショット用に、利用者が撮った空の写真から、アプリが Storage に上げるのと同じ形の JPEG を作る台本
// 使い方: derive_photos <元の写真のフォルダ> <出力のフォルダ>
// - 元の写真（NN.jpg）はリポジトリに入れない。出力もリポジトリの外（手元の git の対象外の場所）に置く
// - 形はアプリの JpegSpec（android/.../data/image/ImagePipeline.kt）に合わせる：
//     本体 = 長辺 2048px 以下・品質 90（POST_BODY）／サムネイル = 長辺 512px 以下・品質 80（POST_THUMBNAIL）
//     アイコン = 真ん中を正方形に切り、1024px・品質 90（ICON は長辺 1024 以下。正方形にするのはアイコンの丸に収めるため）
// - 向き（EXIF の Orientation）は画素に焼き込んで正立にする。撮影情報（EXIF・GPS など）は一切書き出さない
//   （CGImageSourceCreateThumbnailAtIndex が返す画像は画素だけを持ち、書き出しで渡すのは画質の値だけ）
// - 本体の画素の寸法を manifest.json に書く（投稿の images[].width・height にそのまま書くため。アプリの要件 7.11 と同じ）
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("使い方: derive_photos <元の写真のフォルダ> <出力のフォルダ>\n".data(using: .utf8)!)
    exit(2)
}

let inDir = URL(fileURLWithPath: args[1], isDirectory: true)
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// 止める（理由を標準エラーに出す）
func fail(_ message: String) -> Never {
    FileHandle.standardError.write("❌ \(message)\n".data(using: .utf8)!)
    exit(1)
}

/// 元の写真を、向きを直して長辺 maxEdge 以下に縮めた画像にする（大きくはしない）
func upright(_ src: CGImageSource, maxEdge: Int) -> CGImage {
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true, // 埋め込みの小さなサムネイルでなく、元の画素から作る
        kCGImageSourceCreateThumbnailWithTransform: true, // EXIF の向きを画素に焼き込む
        kCGImageSourceThumbnailMaxPixelSize: maxEdge,
    ]
    guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { fail("縮小できない") }
    return img
}

/// 画素だけを JPEG に書く（撮影情報は渡さない）
func writeJpeg(_ img: CGImage, quality: Double, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        fail("書き出し先を作れない: \(url.path)")
    }
    let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fail("書き出せない: \(url.path)") }
}

/// 真ん中を正方形に切って size×size に縮める（アイコン用）
func squareIcon(_ img: CGImage, size: Int) -> CGImage {
    let side = min(img.width, img.height)
    let crop = CGRect(x: (img.width - side) / 2, y: (img.height - side) / 2, width: side, height: side)
    guard let square = img.cropping(to: crop),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { fail("アイコンを作れない") }
    ctx.interpolationQuality = .high
    ctx.draw(square, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let out = ctx.makeImage() else { fail("アイコンを作れない") }
    return out
}

let names = try FileManager.default.contentsOfDirectory(atPath: inDir.path)
    .filter { $0.hasSuffix(".jpg") }
    .sorted()
guard !names.isEmpty else { fail("元の写真（*.jpg）が無い: \(inDir.path)") }

var manifest: [String: [String: Int]] = [:]
for name in names {
    let stem = String(name.dropLast(4))
    guard let src = CGImageSourceCreateWithURL(inDir.appendingPathComponent(name) as CFURL, nil) else {
        fail("読めない: \(name)")
    }
    let body = upright(src, maxEdge: 2048)
    let thumb = upright(src, maxEdge: 512)
    writeJpeg(body, quality: 0.90, to: outDir.appendingPathComponent("\(stem)-body.jpg"))
    writeJpeg(thumb, quality: 0.80, to: outDir.appendingPathComponent("\(stem)-thumb.jpg"))
    writeJpeg(squareIcon(body, size: 1024), quality: 0.90, to: outDir.appendingPathComponent("\(stem)-icon.jpg"))
    manifest[stem] = ["width": body.width, "height": body.height, "thumbWidth": thumb.width, "thumbHeight": thumb.height]
    print("\(stem): 本体 \(body.width)×\(body.height)・サムネイル \(thumb.width)×\(thumb.height)")
}

let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("manifest.json"))
print("✅ \(names.count) 枚を \(outDir.path) に書いた（manifest.json に本体の寸法）")
