//
//  Feature1FoundationTests.swift
//  SoramoyouTests
//
//  ⭐️ 機能1（気分フレーム＋気持ちコメント）共通基盤(STEP 1)のテスト
//  - Mood / MoodStyle の基本契約
//  - Post の mood / frameId Firestore 往復（toFirestoreData ↔ init(from:)）
//  - ImageCompositor の合成契約（extent 保持 / 描画可能 / caption 未入力は passthrough）
//    + キャプション配置のピクセル検証（mirror・placement をビルドでなく実描画で担保）
//

import XCTest
import CoreImage
import UIKit
import SwiftUI
import FirebaseFirestore
@testable import Soramoyou

final class Feature1FoundationTests: XCTestCase {

    // MARK: - Helpers

    /// 単色の base 画像を生成（RGBA8 / sRGB）
    private func makeSolidBase(gray: UInt8, width: Int, height: Int) -> CIImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = gray; bytes[i + 1] = gray; bytes[i + 2] = gray; bytes[i + 3] = 255
        }
        return CIImage(
            bitmapData: Data(bytes),
            bytesPerRow: width * 4,
            size: CGSize(width: width, height: height),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
    }

    /// 合成結果を実描画し、白に近い画素の数と「行（縦）方向の重心」を返す。
    /// 行 0 を上端とした座標で重心を出すため、placement(.top/.bottom) の上下を機械検証できる。
    private func whiteStats(_ image: CIImage, threshold: UInt8 = 150) -> (count: Int, centroidY: Double) {
        let ctx = CIContext()
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, let cg = ctx.createCGImage(image, from: image.extent) else {
            return (0, 0)
        }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let c = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        c?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var count = 0
        var rowSum = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if bytes[i] > threshold, bytes[i + 1] > threshold, bytes[i + 2] > threshold {
                    count += 1
                    rowSum += Double(y)
                }
            }
        }
        return (count, count > 0 ? rowSum / Double(count) : 0)
    }

    // MARK: - Mood / MoodStyle

    func testMoodCasesAndRawValuesAreStable() {
        // raw value は Firestore 保存値。表示名変更で壊れないことを担保する。
        XCTAssertEqual(Mood.allCases.count, 5)
        XCTAssertEqual(Mood.calm.rawValue, "calm")
        XCTAssertEqual(Mood.uplifted.rawValue, "uplifted")
        XCTAssertEqual(Mood.wistful.rawValue, "wistful")
        XCTAssertEqual(Mood.dignified.rawValue, "dignified")
        XCTAssertEqual(Mood.dreamy.rawValue, "dreamy")
    }

    func testEveryMoodHasStyle() {
        for mood in Mood.allCases {
            XCTAssertFalse(mood.style.palette.isEmpty, "\(mood) の palette が空")
            XCTAssertFalse(mood.displayName.isEmpty)
            XCTAssertFalse(mood.iconName.isEmpty)
        }
    }

    func testMoodPlacementsAsDesigned() {
        XCTAssertEqual(Mood.dignified.style.captionPlacement, .top)
        XCTAssertEqual(Mood.calm.style.captionPlacement, .bottom)
        XCTAssertEqual(Mood.uplifted.style.captionPlacement, .center)
    }

    // MARK: - Post 往復

    func testPostMoodAndFrameIdRoundTrip() throws {
        let image = ImageInfo(url: "https://example.com/a.jpg", width: 100, height: 200, order: 0)
        let post = Post(
            id: "p1", userId: "u1", images: [image],
            caption: "暮れていく空 #夕焼け", mood: .wistful, frameId: "frame_wistful_01",
            frameCaption: "金色のひととき",
            visibility: .public
        )

        let data = post.toFirestoreData()
        XCTAssertEqual(data["mood"] as? String, "wistful")
        XCTAssertEqual(data["frameId"] as? String, "frame_wistful_01")
        // フレーム用コメントは通常 caption と別キーで保存される
        XCTAssertEqual(data["frameCaption"] as? String, "金色のひととき")

        let restored = try Post(from: data)
        XCTAssertEqual(restored.mood, .wistful)
        XCTAssertEqual(restored.frameId, "frame_wistful_01")
        XCTAssertEqual(restored.caption, "暮れていく空 #夕焼け")
        XCTAssertEqual(restored.frameCaption, "金色のひととき", "フレーム用コメントが往復するべき")
    }

    func testPostWithoutMoodIsBackwardCompatible() throws {
        // 旧投稿（mood / frameId なし）が壊れないこと。
        let image = ImageInfo(url: "https://example.com/b.jpg", width: 100, height: 200, order: 0)
        let post = Post(id: "p2", userId: "u1", images: [image], visibility: .public)

        let data = post.toFirestoreData()
        XCTAssertNil(data["mood"])
        XCTAssertNil(data["frameId"])
        XCTAssertNil(data["frameCaption"])

        let restored = try Post(from: data)
        XCTAssertNil(restored.mood)
        XCTAssertNil(restored.frameId)
        XCTAssertNil(restored.frameCaption)
    }

    // MARK: - ImageCompositor 契約

    func testComposeGrowsCanvasWhenFramed() {
        // 新方式: 写真の外側に余白＋下プレートを足すので、出力は base より大きい（写真は欠けない）。
        let base = makeSolidBase(gray: 128, width: 240, height: 360)
        let out = ImageCompositor.compose(.init(base: base, caption: "テスト", mood: .calm))
        XCTAssertGreaterThan(out.extent.width, 240, "側余白で幅が増える")
        XCTAssertGreaterThan(out.extent.height, 360, "余白＋プレートで縦が増える")
    }

    func testComposePassthroughWhenNoMood() {
        // mood 無し＝フレームなし。extent は base のまま（額縁を付けない）。
        let base = makeSolidBase(gray: 128, width: 240, height: 360)
        let out = ImageCompositor.compose(.init(base: base, caption: "テスト", mood: nil))
        XCTAssertEqual(out.extent.width, 240, accuracy: 1)
        XCTAssertEqual(out.extent.height, 360, accuracy: 1)
    }

    func testComposeIsRenderable() {
        let base = makeSolidBase(gray: 128, width: 240, height: 360)
        let out = ImageCompositor.compose(.init(base: base, caption: "テスト", mood: .dreamy))
        let ctx = CIContext()
        XCTAssertNotNil(ctx.createCGImage(out, from: out.extent))
    }

    func testFrameWithoutCaptionStillFramesButHasNoPlate() {
        // mood あり・コメント無し → 余白フレームは付くがプレート無し（adaptive plate ≈0）。
        // コメント有りはプレート分だけ縦が高くなる。
        let base = makeSolidBase(gray: 128, width: 240, height: 360)
        let noCaption = ImageCompositor.compose(.init(base: base, caption: nil, mood: .calm, style: .classic))
        let withCaption = ImageCompositor.compose(.init(base: base, caption: "ひとこと", mood: .calm, style: .classic))
        XCTAssertGreaterThan(noCaption.extent.width, 240, "コメント無しでも余白フレームは付く")
        XCTAssertGreaterThan(
            withCaption.extent.height, noCaption.extent.height,
            "コメント有りはプレート分だけ縦が増えるべき"
        )
    }

    func testCaptionRendersInBottomPlateNotOverPhoto() {
        // コメントは写真の上ではなく下プレートに描かれる。bottomBand は枠が透明・帯が濃色・文字が白なので
        // 白画素＝コメントのみ。その重心が下部(プレート)にあることを検証する（写真領域=上部ではない）。
        let base = makeSolidBase(gray: 30, width: 240, height: 360)
        XCTAssertEqual(whiteStats(base).count, 0, "base は暗いので白画素ゼロ")

        let out = ImageCompositor.compose(.init(base: base, caption: "しずかな空にひとことを", mood: .calm, style: .bottomBand))
        let stats = whiteStats(out)
        XCTAssertGreaterThan(stats.count, 0, "コメントの白画素が現れるべき")
        XCTAssertGreaterThan(
            stats.centroidY, out.extent.height * 0.6,
            "コメントは下プレートに描かれるべき(重心が下部)。写真の上に乗っていたら失敗"
        )
    }

    func testEmptyCaptionProducesNoCaptionPixels() {
        // 空白のみ/未入力のコメントは焼かない（bottomBand 帯は濃色なので白画素は出ない）。
        let base = makeSolidBase(gray: 30, width: 240, height: 360)
        let blank = ImageCompositor.compose(.init(base: base, caption: "   ", mood: .calm, style: .bottomBand))
        XCTAssertEqual(whiteStats(blank).count, 0, "空白コメントは白文字を焼かない")
    }

    // MARK: - 焼き込み seam（composeToUIImage / orientation 往復）

    /// 単色 UIImage を指定 orientation 付きで生成（raw ピクセルは width×height）
    private func makeSolidUIImage(gray: UInt8, width: Int, height: Int, orientation: UIImage.Orientation) -> UIImage? {
        let ci = makeSolidBase(gray: gray, width: width, height: height)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: orientation)
    }

    /// 指定座標の RGB 平均輝度(0...255)
    private func brightness(_ image: CIImage, x: Int, y: Int) -> Double {
        let ctx = CIContext()
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard w > 0, h > 0, let cg = ctx.createCGImage(image, from: image.extent) else { return 0 }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let c = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        c?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let cx = min(max(x, 0), w - 1), cy = min(max(y, 0), h - 1)
        let i = (cy * w + cx) * 4
        return (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3.0
    }

    func testComposeToUIImageNormalizesOrientationAndFrames() throws {
        // raw 240×360 を .right(横向き保存)として作る。向きを適用すると 360×240(横長)になる。
        // 投稿フローで来る「向きタグ付き画像」を模す（CIImage は向きを無視する罠の回帰）。
        let base = try XCTUnwrap(makeSolidUIImage(gray: 30, width: 240, height: 360, orientation: .right))
        XCTAssertEqual(base.imageOrientation, .right)

        // matte: 白マットなので端は白＝base(暗)より明るいことも併せて検証できる
        let out = ImageCompositor.composeToUIImage(base: base, mood: .calm, caption: "ひとことを添えて", style: .matte)

        // 1) 向きが .up に正規化される（uploadImages→encodeJPEG の正規化と整合）
        XCTAssertEqual(out.imageOrientation, .up)
        // 2) 向き適用後は横長(写真 360×240)。フレーム余白で更に大きくなるが、横長(width>height)は保たれる。
        //    向きを無視すると縦長(width<height)になるため、これで orientation 反映を担保する。
        XCTAssertGreaterThan(out.size.width, out.size.height, "向き適用後の横長が保たれるべき(orientation 反映の回帰)")
        XCTAssertGreaterThan(out.size.width, 360, "フレーム余白で 360 より大きいべき")

        let outCI = try XCTUnwrap(out.cgImage.map { CIImage(cgImage: $0) })
        // 3) コメントの白画素が焼き込まれている
        XCTAssertGreaterThan(whiteStats(outCI).count, 0, "コメントが焼き込まれているべき")
        // 4) 端(マット余白)が base gray30 より明るい＝フレームが付いている
        let edgeBrightness = brightness(outCI, x: 4, y: Int(out.size.height) / 2)
        XCTAssertGreaterThan(edgeBrightness, 50, "端にフレーム(白マット)が乗っているべき(base 30 より明るい)")
    }

    func testComposeToUIImagePassthroughWhenNoMoodNoCaption() throws {
        // mood も caption も無ければ合成なし（向き正規化のみ）。白画素ゼロ。
        let base = try XCTUnwrap(makeSolidUIImage(gray: 30, width: 200, height: 300, orientation: .up))
        let out = ImageCompositor.composeToUIImage(base: base, mood: nil, caption: nil)
        let outCI = try XCTUnwrap(out.cgImage.map { CIImage(cgImage: $0) })
        XCTAssertEqual(whiteStats(outCI).count, 0, "mood/caption 無しなら白画素は出ない")
    }

    // MARK: - FrameStyle（枠スタイル選択）

    func testFrameStyleCasesAndRawValuesAreStable() {
        // raw value は frameId("mood_style") の保存値。変更で過去データと不整合になるため固定。
        XCTAssertEqual(FrameStyle.allCases.count, 3)
        XCTAssertEqual(FrameStyle.classic.rawValue, "classic")
        XCTAssertEqual(FrameStyle.matte.rawValue, "matte")
        XCTAssertEqual(FrameStyle.bottomBand.rawValue, "bottomBand")
        for style in FrameStyle.allCases {
            XCTAssertFalse(style.displayName.isEmpty)
            XCTAssertFalse(style.iconName.isEmpty)
        }
    }

    func testFrameStylesProduceDistinctCanvasStructure() throws {
        // 3スタイルの構造差をキャンバス寸法で検証：classic/matte=左右に余白(幅増)、
        // bottomBand=左右余白なし(幅は写真のまま)＋下帯(縦増)。
        let base = try XCTUnwrap(makeSolidUIImage(gray: 30, width: 240, height: 360, orientation: .up))
        let classic = ImageCompositor.composeToUIImage(base: base, mood: .calm, caption: "あ", style: .classic)
        let matte = ImageCompositor.composeToUIImage(base: base, mood: .calm, caption: "あ", style: .matte)
        let band = ImageCompositor.composeToUIImage(base: base, mood: .calm, caption: "あ", style: .bottomBand)

        XCTAssertGreaterThan(classic.size.width, 240, "classic は側余白で幅が増えるべき")
        XCTAssertGreaterThan(matte.size.width, 240, "matte は側余白で幅が増えるべき")
        XCTAssertEqual(band.size.width, 240, accuracy: 1, "bottomBand は側余白なし＝幅は写真のまま")
        XCTAssertGreaterThan(band.size.height, 360, "bottomBand は下帯で縦が増えるべき")
    }

    func testComposeToUIImageAppliesFrameStyle() throws {
        // matte / bottomBand でも焼き込みが成立し、白画素(白マット or 白キャプション)が現れる。
        let base = try XCTUnwrap(makeSolidUIImage(gray: 30, width: 240, height: 360, orientation: .up))

        let matte = ImageCompositor.composeToUIImage(base: base, mood: .calm, caption: "白いマット", style: .matte)
        let matteCI = try XCTUnwrap(matte.cgImage.map { CIImage(cgImage: $0) })
        XCTAssertGreaterThan(whiteStats(matteCI).count, 0, "matte は白マット/白文字の白画素が出るべき")

        let band = ImageCompositor.composeToUIImage(base: base, mood: .calm, caption: "下帯のことば", style: .bottomBand)
        let bandCI = try XCTUnwrap(band.cgImage.map { CIImage(cgImage: $0) })
        XCTAssertGreaterThan(whiteStats(bandCI).count, 0, "bottomBand は白文字キャプションの白画素が出るべき")
    }

    // MARK: - PostEditingContext（再編集 seed）

    func testPostEditingContextExtractsFieldsAndParsesStyle() {
        let img = ImageInfo(
            url: "https://e.com/a.jpg", thumbnail: "https://e.com/a_t.jpg",
            width: 100, height: 200, order: 0,
            storagePath: "posts/u1/a.jpg", thumbnailStoragePath: "posts/u1/a_t.jpg"
        )
        let orig = ImageInfo(url: "https://e.com/o.jpg", width: 100, height: 200, order: 0, storagePath: "originals/u1/o.jpg")
        let post = Post(
            id: "p9", userId: "u1", images: [img], originalImages: [orig],
            caption: "本文 #空", mood: .wistful, frameId: "wistful_matte", frameCaption: "夕暮れ",
            hashtags: ["空"], skyColors: ["#abcdef"], visibility: .followers,
            likesCount: 7, commentsCount: 3
        )
        let ctx = PostEditingContext(post: post)
        XCTAssertEqual(ctx.postId, "p9")
        XCTAssertEqual(ctx.mood, .wistful)
        XCTAssertEqual(ctx.frameStyle, .matte, "frameId 末尾から枠スタイルを復元するべき")
        XCTAssertEqual(ctx.caption, "本文 #空")
        XCTAssertEqual(ctx.frameCaption, "夕暮れ")
        XCTAssertEqual(ctx.visibility, .followers)
        XCTAssertEqual(ctx.likesCount, 7)
        XCTAssertEqual(ctx.commentsCount, 3)
        XCTAssertEqual(ctx.skyColors, ["#abcdef"])
        // 原画像は再編集で変わらない＝引き継ぐ（C1 data-loss 対策）
        XCTAssertEqual(ctx.originalImages?.first?.url, "https://e.com/o.jpg", "原画像を保持して引き継ぐべき")
        // 旧 Storage パス（孤児削除用）には「置換される編集済み画像＋サムネ」のみ含む。
        XCTAssertTrue(ctx.oldStoragePaths.contains("posts/u1/a.jpg"))
        XCTAssertTrue(ctx.oldStoragePaths.contains("posts/u1/a_t.jpg"))
        // 原画像パスは削除対象に含めない（保持するため。含めると再編集不可になる）。
        XCTAssertFalse(ctx.oldStoragePaths.contains("originals/u1/o.jpg"), "原画像パスは削除対象に含めない（保持）")
    }

    func testPostEditingContextStyleFallbackAndBandParse() {
        let img = ImageInfo(url: "https://e.com/a.jpg", width: 100, height: 200, order: 0)
        // frameId なし → classic
        let noFrame = Post(id: "p1", userId: "u1", images: [img], visibility: .public)
        XCTAssertEqual(PostEditingContext(post: noFrame).frameStyle, .classic)
        // 旧形式 "frame_wistful_01" → 末尾 "01" は FrameStyle に無い → classic フォールバック
        let legacy = Post(id: "p2", userId: "u1", images: [img], frameId: "frame_wistful_01", visibility: .public)
        XCTAssertEqual(PostEditingContext(post: legacy).frameStyle, .classic)
        // "calm_bottomBand" → bottomBand 復元
        let band = Post(id: "p3", userId: "u1", images: [img], mood: .calm, frameId: "calm_bottomBand", visibility: .public)
        XCTAssertEqual(PostEditingContext(post: band).frameStyle, .bottomBand)
    }

    // MARK: - フレーム文字の色・フォント選択

    /// UIColor の RGBA 成分を取り出す（テスト比較用）
    private func rgba(_ color: UIColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    func testFrameFontStyleMapsToFontDesignStably() {
        // raw value は Firestore 保存値。固定であること＋Font.Design への対応を担保。
        XCTAssertEqual(FrameFontStyle.allCases.count, 4)
        XCTAssertEqual(FrameFontStyle.standard.rawValue, "standard")
        XCTAssertEqual(FrameFontStyle.rounded.rawValue, "rounded")
        XCTAssertEqual(FrameFontStyle.serif.rawValue, "serif")
        XCTAssertEqual(FrameFontStyle.mono.rawValue, "mono")
        XCTAssertEqual(FrameFontStyle.standard.fontDesign, .default)
        XCTAssertEqual(FrameFontStyle.rounded.fontDesign, .rounded)
        XCTAssertEqual(FrameFontStyle.serif.fontDesign, .serif)
        XCTAssertEqual(FrameFontStyle.mono.fontDesign, .monospaced)
        for f in FrameFontStyle.allCases {
            XCTAssertFalse(f.displayName.isEmpty)
            XCTAssertFalse(f.iconName.isEmpty)
        }
    }

    func testColorHexRoundTrip() {
        // "#RRGGBB" → UIColor → "#RRGGBB" が一致する
        let hex = "#3366CC"
        let color = try? XCTUnwrap(UIColor(hex: hex))
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.toHexString(), "#3366CC")
        // 先頭 # なし・小文字も解析できる
        XCTAssertEqual(UIColor(hex: "ff0000")?.toHexString(), "#FF0000")
        // 不正値は nil
        XCTAssertNil(UIColor(hex: "xyz"))
        XCTAssertNil(UIColor(hex: "#12"))
        // Color 経由でも往復する
        XCTAssertEqual(Color(hex: "#00FF80")?.toHexString(), "#00FF80")
    }

    func testToHexStringClampsWideGamutToValidHex() {
        // ColorPicker は広色域(Display P3)の色も返しうる。toHexString は 00..FF にクランプして
        // 常に妥当な6桁hexを出す＝preview と bake が同じ(クランプ済み)hexを使い続けられる(方針④)。
        let wide = UIColor(displayP3Red: 1.2, green: -0.1, blue: 0.5, alpha: 1)
        let hex = wide.toHexString()
        XCTAssertEqual(hex.count, 7, "\"#RRGGBB\" の7文字であるべき")
        XCTAssertTrue(hex.hasPrefix("#"))
        // クランプ後のhexは必ず再パースできる（preview==bake の連続性の担保）
        XCTAssertNotNil(UIColor(hex: hex), "クランプ後hexは常に再パース可能であるべき")
    }

    func testResolveCaptionColorOverrideWinsAndStyleDefaults() {
        // override 指定時はそれを最優先（style/mood に関わらず）
        let red = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        let resolved = ImageCompositor.resolveCaptionColor(style: .classic, mood: .calm, override: red)
        let c = rgba(resolved)
        XCTAssertEqual(c.r, 1, accuracy: 0.02)
        XCTAssertEqual(c.g, 0, accuracy: 0.02)
        XCTAssertEqual(c.b, 0, accuracy: 0.02)

        // nil（おまかせ）は style 既定色：matte=濃色 / bottomBand=白
        let matte = rgba(ImageCompositor.resolveCaptionColor(style: .matte, mood: .calm, override: nil))
        XCTAssertLessThan((matte.r + matte.g + matte.b) / 3, 0.3, "matte は濃い文字色（白マットに対し）")
        let band = rgba(ImageCompositor.resolveCaptionColor(style: .bottomBand, mood: .calm, override: nil))
        XCTAssertGreaterThan((band.r + band.g + band.b) / 3, 0.9, "bottomBand は白文字（濃色帯に対し）")
    }

    func testResolveFontDesignOverrideWinsAndMoodDefault() {
        // override 指定時はそのデザイン
        XCTAssertEqual(ImageCompositor.resolveFontDesign(mood: .calm, override: .serif), .serif)
        XCTAssertEqual(ImageCompositor.resolveFontDesign(mood: .calm, override: .mono), .monospaced)
        // nil は mood 既定（calm=.default / wistful=.serif）
        XCTAssertEqual(ImageCompositor.resolveFontDesign(mood: .calm, override: nil), Mood.calm.style.fontDesign)
        XCTAssertEqual(ImageCompositor.resolveFontDesign(mood: .wistful, override: nil), Mood.wistful.style.fontDesign)
    }

    func testComposeCanvasUnchangedWithColorFontOverrides() {
        // 文字色・フォントの上書きはレイアウト（キャンバス寸法）に影響しない＝写真の見え方は不変。
        let base = makeSolidBase(gray: 128, width: 240, height: 360)
        let plain = ImageCompositor.compose(.init(base: base, caption: "ことば", mood: .calm, style: .classic))
        let styled = ImageCompositor.compose(.init(
            base: base, caption: "ことば", mood: .calm, style: .classic,
            captionColor: UIColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1), fontStyle: .serif
        ))
        XCTAssertEqual(plain.extent.width, styled.extent.width, accuracy: 1, "色/フォント上書きで幅は変わらない")
        XCTAssertEqual(plain.extent.height, styled.extent.height, accuracy: 1, "色/フォント上書きで高さは変わらない")
    }

    func testPostFrameTextColorAndFontRoundTrip() throws {
        let image = ImageInfo(url: "https://example.com/a.jpg", width: 100, height: 200, order: 0)
        let post = Post(
            id: "p10", userId: "u1", images: [image],
            mood: .calm, frameId: "calm_classic", frameCaption: "晴れた日",
            frameTextColorHex: "#FFCC00", frameFontStyle: .serif,
            visibility: .public
        )
        let data = post.toFirestoreData()
        XCTAssertEqual(data["frameTextColorHex"] as? String, "#FFCC00")
        XCTAssertEqual(data["frameFontStyle"] as? String, "serif")

        let restored = try Post(from: data)
        XCTAssertEqual(restored.frameTextColorHex, "#FFCC00", "文字色 hex が往復するべき")
        XCTAssertEqual(restored.frameFontStyle, .serif, "フォントが往復するべき")
    }

    func testPostBackwardCompatNoFrameTextColorFont() throws {
        // 旧投稿（色・フォントなし）は nil のまま壊れない。
        let image = ImageInfo(url: "https://example.com/b.jpg", width: 100, height: 200, order: 0)
        let post = Post(id: "p11", userId: "u1", images: [image], mood: .calm, frameId: "calm_classic", visibility: .public)
        let data = post.toFirestoreData()
        XCTAssertNil(data["frameTextColorHex"])
        XCTAssertNil(data["frameFontStyle"])
        let restored = try Post(from: data)
        XCTAssertNil(restored.frameTextColorHex)
        XCTAssertNil(restored.frameFontStyle)
        // 未知のフォント raw も nil（mood 既定へフォールバック）
        var corrupt = data
        corrupt["frameFontStyle"] = "unknownFont"
        XCTAssertNil(try Post(from: corrupt).frameFontStyle)
    }

    func testPostEditingContextExtractsColorAndFont() {
        let img = ImageInfo(url: "https://e.com/a.jpg", width: 100, height: 200, order: 0)
        let post = Post(
            id: "p12", userId: "u1", images: [img],
            mood: .dreamy, frameId: "dreamy_matte", frameCaption: "ゆめ",
            frameTextColorHex: "#102030", frameFontStyle: .rounded,
            visibility: .public
        )
        let ctx = PostEditingContext(post: post)
        XCTAssertEqual(ctx.frameTextColorHex, "#102030", "再編集 seed に文字色が引き継がれるべき")
        XCTAssertEqual(ctx.frameFontStyle, .rounded, "再編集 seed にフォントが引き継がれるべき")
    }
}
