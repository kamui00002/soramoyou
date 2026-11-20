// ⭐️ Play ストアのアイコン（32 ビット PNG＝RGBA）を、透明のない元絵から作る台本
// 使い方: make_icon <入力の PNG> <出力の PNG> <辺の長さ(px)>
// - sips だけでは透明の層（アルファ）を足せないので、sRGB の RGBA の画布に描き直して書き出す
// - 中身は全部不透明のまま（アルファの値はすべて 255）。Play が角を丸めるので、角は丸めない
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4, let side = Int(args[3]), side > 0 else {
    FileHandle.standardError.write("使い方: make_icon <入力> <出力> <辺>\n".data(using: .utf8)!)
    exit(2)
}

let src = URL(fileURLWithPath: args[1])
let dst = URL(fileURLWithPath: args[2])

// 元絵を読む（読めなければ 1 で終わる）
guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write("元絵を読めない\n".data(using: .utf8)!)
    exit(1)
}

// sRGB・8 ビット×4（R・G・B・A）の画布。premultipliedLast＝アルファの層を持つ形
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
          data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
else {
    FileHandle.standardError.write("画布を作れない\n".data(using: .utf8)!)
    exit(1)
}

// 縮めるときの補間は高品質に（ぼやけ・ギザギザを抑える）
ctx.interpolationQuality = .high
ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write("書き出しの準備に失敗\n".data(using: .utf8)!)
    exit(1)
}

CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("書き出しに失敗\n".data(using: .utf8)!)
    exit(1)
}
