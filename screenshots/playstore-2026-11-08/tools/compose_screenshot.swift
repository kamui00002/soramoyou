// ⭐️ Play のスマートフォンのスクリーンショット（1080×1920・透明なし）を、AVD で撮った画面と見出しから組む台本
// 使い方: compose_screenshot <撮った画面の PNG> <下から切る px> <見出し> <出力の PNG>
//   見出しの「|」は改行（2 行まで）
// - ブラウザはサンドボックスの中で動かないので、CoreGraphics（図形）と CoreText（文字）で描く（利用者の決定・11/08）
// - Play のヘルプ（answer/9866151・入力表 docs/play-console-listing.md のグラフィックの節）に合わせる：
//   ①24 ビット PNG（アルファなし） ②見出しは画像の 20% まで（文字の箱の高さを測り、超えたら描かずに止める）
//   ③テスト広告を写さない：検証用ビルドの下端の広告の帯（と、その下のナビゲーションバー）を「下から切る px」で切り落とす。
//     切る量は撮った画面の実物で測って渡す（dp からの計算に頼らない）
// - 背景はフィーチャー グラフィックと同じ空のグラデーション（上が濃い青・下が明るい水色）
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 5, let cropBottom = Int(args[2]), cropBottom >= 0 else {
    FileHandle.standardError.write("使い方: compose_screenshot <画面の PNG> <下から切る px> <見出し> <出力>\n".data(using: .utf8)!)
    exit(2)
}

/// 止める（理由を標準エラーに出す）
func fail(_ message: String) -> Never {
    FileHandle.standardError.write("❌ \(message)\n".data(using: .utf8)!)
    exit(1)
}

let W = 1080.0, H = 1920.0
let headlineLimit = H * 0.20 // 見出しの文字の箱の高さの上限（ヘルプの「画像の 20% まで」）

// 1. 撮った画面を読み、下端（広告の帯とナビゲーションバー）を切る
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let raw = CGImageSourceCreateImageAtIndex(src, 0, nil)
else { fail("画面を読めない: \(args[1])") }
guard cropBottom < raw.height / 2 else { fail("切る量が大きすぎる: \(cropBottom)px（画面の高さ \(raw.height)px）") }
// CGImage の cropping は左上が原点。上から (高さ − 切る量) だけ残す
guard let screen = raw.cropping(to: CGRect(x: 0, y: 0, width: raw.width, height: raw.height - cropBottom)) else {
    fail("画面を切れない")
}

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      // noneSkipLast＝透明の層を持たない形（Play の要件「24 ビット PNG（アルファなし）」）
      let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fail("描く場所を作れない") }

/// sRGB の色を作る小さな道具
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// 2. 背景：上が濃い青・下が明るい水色（CoreGraphics は左下が原点なので、上＝y が大きい）
let sky = CGGradient(colorsSpace: space,
                     colors: [rgb(0.10, 0.34, 0.80), rgb(0.33, 0.60, 0.93), rgb(0.68, 0.86, 1.0)] as CFArray,
                     locations: [0, 0.55, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
// 左上の光のにじみ（フィーチャー グラフィックと同じ飾り）
let glow = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.45), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 60, y: H - 40), startRadius: 0,
                       endCenter: CGPoint(x: 60, y: H - 40), endRadius: 520, options: [])

// 3. 見出し（1〜2 行・真ん中寄せ）
/// 文字の 1 行を作る
func line(_ text: String, _ size: Double) -> CTLine {
    let font = CTFontCreateWithName("HiraginoSans-W7" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(1, 1, 1),
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
}

/// 行の幅・上の高さ（ascent）・下の高さ（descent）を測る
func metrics(_ l: CTLine) -> (width: Double, ascent: Double, descent: Double) {
    var a: CGFloat = 0, d: CGFloat = 0, lead: CGFloat = 0
    let w = CTLineGetTypographicBounds(l, &a, &d, &lead)
    return (w, Double(a), Double(d))
}

let texts = args[3].split(separator: "|").map(String.init)
guard (1 ... 2).contains(texts.count) else { fail("見出しは 1〜2 行: \(texts.count) 行") }
let fontSize = 66.0, lineGap = 18.0, topMargin = 120.0, sideMargin = 60.0
let lines = texts.map { line($0, fontSize) }
let ms = lines.map(metrics)
for (t, m) in zip(texts, ms) where m.width > W - sideMargin * 2 {
    fail("見出しの行が横にはみ出す: 「\(t)」\(Int(m.width))px")
}

let textHeight = ms.reduce(0) { $0 + $1.ascent + $1.descent } + lineGap * Double(ms.count - 1)
print(String(format: "見出しの文字の箱：高さ %.0fpx（上限 %.0fpx＝20%%）", textHeight, headlineLimit))
guard textHeight <= headlineLimit else { fail("見出しが画像の 20% を超える") }

// 見出しの場所は、行の数によらず 2 行分を取る（1 行の見出しはその真ん中に置く）。画面の大きさと位置を全部の枚で揃えるため
let lineHeight = ms[0].ascent + ms[0].descent
let reservedHeight = lineHeight * 2 + lineGap
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 16, color: rgb(0.02, 0.10, 0.32, 0.45))
var baseline = H - topMargin - (reservedHeight - textHeight) / 2
for (l, m) in zip(lines, ms) {
    baseline -= m.ascent
    ctx.textPosition = CGPoint(x: (W - m.width) / 2, y: baseline)
    CTLineDraw(l, ctx)
    baseline -= m.descent + lineGap
}

ctx.restoreGState()
let textBottom = H - topMargin - reservedHeight // 見出しの場所のいちばん下（左下が原点の y）

// 4. 画面：見出しの下から、下の余白までの高さに収まるよう縮め、白い縁と角の丸み・影を付けて真ん中に置く
let gapBelowText = 70.0, bottomMargin = 70.0, bezel = 12.0, radius = 44.0
let availH = textBottom - gapBelowText - bottomMargin - bezel * 2
let scale = availH / Double(screen.height)
let sw = Double(screen.width) * scale, sh = Double(screen.height) * scale
let screenRect = CGRect(x: (W - sw) / 2, y: bottomMargin + bezel, width: sw, height: sh)
let frameRect = screenRect.insetBy(dx: -bezel, dy: -bezel)
print(String(format: "画面：%d×%d を %.3f 倍 → %.0f×%.0f（左右の余白 %.0fpx）", screen.width, screen.height, scale, sw, sh, frameRect.minX))

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: rgb(0.02, 0.10, 0.32, 0.40))
ctx.addPath(CGPath(roundedRect: frameRect, cornerWidth: radius + bezel, cornerHeight: radius + bezel, transform: nil))
ctx.setFillColor(rgb(1, 1, 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: screenRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(screen, in: screenRect)
ctx.restoreGState()

// 5. 書き出し
guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[4]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("書き出し先を作れない") }
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fail("書き出せない") }
print("✅ \(args[4])")
