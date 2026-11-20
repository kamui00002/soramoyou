// ⭐️ Play ストアのフィーチャー グラフィック（1024×500・透明なし）を描く台本（2 版）
// 使い方: feature_graphic <出力の PNG>
// - ブラウザはサンドボックスの中で動かないので、CoreGraphics（図形）と CoreText（文字）で描く
// - Play のヘルプ（answer/9866151 の Feature graphic の Highly recommended・2026-11-08 に読んだ）に合わせる：
//   ①アプリのアイコンと同じ絵を大きく置かない（掲載ではすぐ隣にアイコンが出て重複する）
//   ②アプリ名・標語は切り取られる帯の外（真ん中）に置く。帯はヘルプの図（406×198）から測った目安で、
//     1024×500 では左右それぞれ約 150px・上下それぞれ約 73px。背景の飾り（雲・光）は端に寄せる
//   ③簡単な説明と同じ文言を繰り返さない（標語は iOS のストアと同じ「今日の空、みんなの空」）
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("使い方: feature_graphic <出力>\n".data(using: .utf8)!)
    exit(2)
}

let outURL = URL(fileURLWithPath: args[1])

let W = 1024.0, H = 500.0
// 切り取られない範囲（目安に少し余裕を足した値）。ここから文字がはみ出したら描かずに止める
let safe = CGRect(x: 160, y: 80, width: W - 320, height: H - 160)

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      // noneSkipLast＝透明の層を持たない形（Play の要件「24 ビット PNG（アルファなし）」）
      let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { exit(1) }

/// sRGB の色を作る小さな道具
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// 1. 背景：上が濃い青・下が明るい水色（CoreGraphics は左下が原点なので、上＝y が大きい）
let sky = CGGradient(colorsSpace: space,
                     colors: [rgb(0.10, 0.34, 0.80), rgb(0.33, 0.60, 0.93), rgb(0.68, 0.86, 1.0)] as CFArray,
                     locations: [0, 0.55, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// 2. 左上の太陽の光のにじみ（端に寄せた背景の飾り）
let glow = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.60), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 40, y: H - 20), startRadius: 0,
                       endCenter: CGPoint(x: 40, y: H - 20), endRadius: 340, options: [])

/// ふんわりした雲：白の放射グラデーションを横に引き伸ばして置く
func softCloud(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ alpha: Double) {
    let g = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, alpha), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.scaleBy(x: rx / ry, y: 1)
    ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: ry, options: [])
    ctx.restoreGState()
}

// 雲は下の端と左右の端に寄せる（アイコンの「青空と白い雲」を広げた絵にする）
softCloud(60, 60, 240, 110, 0.70)
softCloud(330, -10, 300, 80, 0.55)
softCloud(700, -10, 300, 80, 0.55)
softCloud(980, 70, 240, 120, 0.70)
softCloud(1010, 330, 120, 80, 0.40)

// 3. 文字の準備
/// 文字の 1 行を作る
func line(_ text: String, _ fontName: String, _ size: Double, _ color: CGColor) -> CTLine {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
}

/// 行の幅・上の高さ（ascent）・下の高さ（descent）を測る
func metrics(_ l: CTLine) -> (width: Double, ascent: Double, descent: Double) {
    var a: CGFloat = 0, d: CGFloat = 0, lead: CGFloat = 0
    let w = CTLineGetTypographicBounds(l, &a, &d, &lead)
    return (w, Double(a), Double(d))
}

let title = line("そらもよう", "HiraginoSans-W7", 116, rgb(1, 1, 1))
let slogan = line("今日の空、みんなの空", "HiraginoSans-W6", 42, rgb(1, 1, 1, 0.97))
let tm = metrics(title), sm = metrics(slogan)
let lineGap = 20.0

// 4. 置く位置：2 行の組を、横も縦も真ん中に
let blockH = tm.ascent + tm.descent + lineGap + sm.ascent + sm.descent
let top = H / 2 + blockH / 2
let titleBase = top - tm.ascent
let sloganBase = titleBase - tm.descent - lineGap - sm.ascent
let titleRect = CGRect(x: (W - tm.width) / 2, y: titleBase - tm.descent, width: tm.width, height: tm.ascent + tm.descent)
let sloganRect = CGRect(x: (W - sm.width) / 2, y: sloganBase - sm.descent, width: sm.width, height: sm.ascent + sm.descent)

// 切り取られない範囲に収まっているかを、描く前に確かめる（はみ出しは描かずに止める）
for (name, r) in [("題名", titleRect), ("標語", sloganRect)] {
    print(String(format: "%@：横 %.0f〜%.0f・縦 %.0f〜%.0f", name, r.minX, r.maxX, r.minY, r.maxY))
    guard safe.contains(r) else {
        FileHandle.standardError.write("\(name)が切り取られる帯にかかる\n".data(using: .utf8)!)
        exit(4)
    }
}

// 5. 文字を描く（明るい空の上でも白い文字が読めるように、うっすら影を付ける）
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 16, color: rgb(0.02, 0.10, 0.32, 0.45))
ctx.textPosition = CGPoint(x: titleRect.minX, y: titleBase)
CTLineDraw(title, ctx)
ctx.textPosition = CGPoint(x: sloganRect.minX, y: sloganBase)
CTLineDraw(slogan, ctx)
ctx.restoreGState()

// 6. 書き出し
guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
