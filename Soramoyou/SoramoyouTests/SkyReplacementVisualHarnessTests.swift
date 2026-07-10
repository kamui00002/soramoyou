//
//  SkyReplacementVisualHarnessTests.swift
//  SoramoyouTests
//
//  ⚠️ 一時ハーネス（目視確認用・マージ前に削除予定）
//
//  SkyReplacementCompositor の合成結果を人間（レビュアー）が目視確認できるよう、
//  ビフォー / アフター / マスクの PNG をホスト Mac のファイルシステムへ書き出すだけの
//  使い捨てテスト。過去の OpenCV スイープテスト（4隅パノラマ合成の実写検証）と同型の
//  運用パターンで、通常のユニットテストのように assert で判定するのではなく、
//  「人がファイルを開いて確認する」ことをゴールにしている。
//
//  シミュレータ上で走るユニットテストはホスト Mac のファイルシステムを直接読み書きできる
//  （サンドボックスされない）ため、/tmp 配下に直接 PNG を書き出せる。
//

import XCTest
import CoreImage
import UIKit
@testable import Soramoyou

final class SkyReplacementVisualHarnessTests: XCTestCase {

    // MARK: - 定数（入出力フォルダ）

    /// 実写画像を置く入力フォルダ（存在しなければ XCTSkip する）
    private static let inputDirectoryPath = "/tmp/sky-replace-test/input"
    /// ビフォー/アフター/マスクの PNG を書き出す出力フォルダ
    private static let outputDirectoryPath = "/tmp/sky-replace-test/output"

    /// 実写画像を渡す前に縮小する長辺の上限（アプリ本体の画像制約と同じ値）
    private static let maxLongSide: CGFloat = 2048

    // MARK: - Tests

    func test_visualHarness_generateBeforeAfter() async throws {
        let fileManager = FileManager.default
        let inputDirectoryURL = URL(fileURLWithPath: Self.inputDirectoryPath)
        let outputDirectoryURL = URL(fileURLWithPath: Self.outputDirectoryPath)

        // 手順1: 入力フォルダが無ければスキップ（通常のテスト実行を汚さないためのガード）
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: inputDirectoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw XCTSkip("入力フォルダなし: \(inputDirectoryURL.path)")
        }

        try fileManager.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)

        // 手順2〜3: 差し替え用の空2種 ＋ ビル入り合成写真を生成
        let sunsetSky = makeSunsetSky()
        let blueSkySky = makeBlueSkyWithClouds()
        let syntheticCity = makeSyntheticCityImage()

        // 入力フォルダの実写 ＋ synthetic-city をまとめて処理対象にする
        var subjects: [(name: String, image: UIImage)] = []

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]
        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: inputDirectoryURL,
            includingPropertiesForKeys: nil
        ))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        for url in fileURLs where imageExtensions.contains(url.pathExtension.lowercased()) {
            guard let loaded = UIImage(contentsOfFile: url.path) else {
                XCTFail("画像読み込みに失敗: \(url.path)")
                continue
            }
            let name = url.deletingPathExtension().lastPathComponent
            subjects.append((name: name, image: resizedIfNeeded(loaded, maxLongSide: Self.maxLongSide)))
        }

        subjects.append((name: "synthetic-city", image: syntheticCity))

        // 手順4: 各対象について sunset / bluesky で合成 → PNG 書き出し
        let compositor = SkyReplacementCompositor()
        let maskProvider = HeuristicSkyMaskProvider()
        let ciContext = CIContext()

        var summaryLines: [String] = []

        for subject in subjects {
            guard let cgImage = subject.image.cgImage else {
                XCTFail("\(subject.name): cgImage 取得に失敗")
                continue
            }
            // SkyReplacementCompositor.replaceSky と同じ向き正規化を行い、マスク単体の
            // 生成・可視化（skyCoverage 取得も含む）に使う CIImage を用意する。
            let orientedCI = CIImage(cgImage: cgImage)
                .oriented(CGImagePropertyOrientation(subject.image.imageOrientation))

            let skyMask: SkyMask
            do {
                // coverage 値は先にマスクだけ生成して取得する（noSkyDetected 時の報告用）
                skyMask = try await maskProvider.makeSkyMask(for: orientedCI, quality: .export)
            } catch {
                XCTFail("\(subject.name): マスク生成に失敗: \(error)")
                continue
            }

            do {
                let sunsetResult = try await compositor.replaceSky(in: subject.image, with: sunsetSky)
                let blueskyResult = try await compositor.replaceSky(in: subject.image, with: blueSkySky)

                try writePNG(subject.image, filename: "\(subject.name)__before.png", to: outputDirectoryURL)
                try writePNG(sunsetResult.image, filename: "\(subject.name)__after-sunset.png", to: outputDirectoryURL)
                try writePNG(blueskyResult.image, filename: "\(subject.name)__after-bluesky.png", to: outputDirectoryURL)

                if let maskCGImage = ciContext.createCGImage(skyMask.mask, from: skyMask.mask.extent) {
                    try writePNG(UIImage(cgImage: maskCGImage), filename: "\(subject.name)__mask.png", to: outputDirectoryURL)
                } else {
                    XCTFail("\(subject.name): マスクの CGImage 化に失敗")
                }

                summaryLines.append(
                    "\(subject.name): replaced (skyCoverage=\(skyMask.skyCoverage), confidence=\(skyMask.confidence))"
                )
            } catch SkyReplacementError.noSkyDetected {
                // 空がほぼ写っていない写真（室内など）は差し替え拒否が正しい挙動。
                // テスト失敗にはせず、判断材料の統計値だけテキストで残す。
                let reportText = """
                skyCoverage: \(skyMask.skyCoverage)
                confidence: \(skyMask.confidence)
                """
                let skipURL = outputDirectoryURL.appendingPathComponent("\(subject.name)__SKIPPED-noSkyDetected.txt")
                try? reportText.write(to: skipURL, atomically: true, encoding: .utf8)
                summaryLines.append("\(subject.name): noSkyDetected (skyCoverage=\(skyMask.skyCoverage))")
                continue
            } catch {
                XCTFail("\(subject.name): 想定外のエラー: \(error)")
            }
        }

        // 手順5: 結果一覧を print（レビュアーがコンソールでも把握できるように）
        print("=== SkyReplacementVisualHarness 処理結果一覧 ===")
        for line in summaryLines {
            print(line)
        }
    }

    // MARK: - Private: 合成用の空画像生成（手順2）

    /// 夕焼け風の空: 上（濃いオレンジ）→ 下（淡いピンク）の縦グラデーション
    private func makeSunsetSky() -> UIImage {
        makeGradientImage(
            size: CGSize(width: 2048, height: 1536),
            topColor: UIColor(red: 0.95, green: 0.45, blue: 0.15, alpha: 1),
            bottomColor: UIColor(red: 0.98, green: 0.75, blue: 0.65, alpha: 1)
        )
    }

    /// 青空風の空: 上（濃い青）→ 下（淡い水色）の縦グラデーション ＋ 白い雲（楕円）
    private func makeBlueSkyWithClouds() -> UIImage {
        let size = CGSize(width: 2048, height: 1536)
        let topColor = UIColor(red: 0.25, green: 0.5, blue: 0.95, alpha: 1)
        let bottomColor = UIColor(red: 0.75, green: 0.88, blue: 0.98, alpha: 1)

        // UIGraphicsImageRenderer は既定で端末倍率(2x/3x)で描画するため、
        // scale=1 に固定して「指定サイズ＝実ピクセルサイズ」を保証する
        // （目視確認用の PNG サイズをそろえ、意図せず巨大化しないようにするため）。
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            let cgContext = rendererContext.cgContext
            drawVerticalGradient(in: cgContext, rect: CGRect(origin: .zero, size: size), top: topColor, bottom: bottomColor)

            // 雲（白い楕円）を2〜3個、alpha 0.8 で重ねる
            UIColor(white: 1.0, alpha: 0.8).setFill()
            let cloudRects = [
                CGRect(x: size.width * 0.10, y: size.height * 0.15, width: size.width * 0.28, height: size.height * 0.10),
                CGRect(x: size.width * 0.50, y: size.height * 0.32, width: size.width * 0.22, height: size.height * 0.08),
                CGRect(x: size.width * 0.68, y: size.height * 0.10, width: size.width * 0.20, height: size.height * 0.07)
            ]
            for rect in cloudRects {
                UIBezierPath(ovalIn: rect).fill()
            }
        }
    }

    /// 上=空グラデーション下=地面（ビルシルエット入り）の合成写真。
    /// マスクがビルの輪郭（縦の直線的なエッジ）をどう扱うか目視するための素材。
    private func makeSyntheticCityImage() -> UIImage {
        let size = CGSize(width: 1024, height: 768)
        let skyHeight = size.height * 2.0 / 3.0
        let groundHeight = size.height - skyHeight

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            let cgContext = rendererContext.cgContext

            // 上2/3: 青空グラデーション（bluesky と近い色）
            cgContext.saveGState()
            cgContext.clip(to: CGRect(x: 0, y: 0, width: size.width, height: skyHeight))
            drawVerticalGradient(
                in: cgContext,
                rect: CGRect(x: 0, y: 0, width: size.width, height: skyHeight),
                top: UIColor(red: 0.25, green: 0.5, blue: 0.95, alpha: 1),
                bottom: UIColor(red: 0.75, green: 0.88, blue: 0.98, alpha: 1)
            )
            cgContext.restoreGState()

            // 下1/3: 暗いグレーの地面
            UIColor(white: 0.25, alpha: 1).setFill()
            cgContext.fill(CGRect(x: 0, y: skyHeight, width: size.width, height: groundHeight))

            // ビル: 高さ・幅がまちまちな暗い矩形を、地面から空に向けて（下端は必ず地面より下まで）描く
            UIColor(white: 0.12, alpha: 1).setFill()
            let buildingSpecs: [(xFraction: CGFloat, widthFraction: CGFloat, heightIntoSkyFraction: CGFloat)] = [
                (0.05, 0.10, 0.55),
                (0.18, 0.07, 0.30),
                (0.30, 0.12, 0.75),
                (0.50, 0.09, 0.45),
                (0.65, 0.14, 0.65),
                (0.85, 0.10, 0.20)
            ]
            for spec in buildingSpecs {
                let width = size.width * spec.widthFraction
                let x = size.width * spec.xFraction
                let intoSky = skyHeight * spec.heightIntoSkyFraction
                let topY = max(0, skyHeight - intoSky)
                let rect = CGRect(x: x, y: topY, width: width, height: size.height - topY)
                cgContext.fill(rect)
            }
        }
    }

    /// 上下2色の縦グラデーションを CGGradient で描画する共通ヘルパー
    private func drawVerticalGradient(in cgContext: CGContext, rect: CGRect, top: UIColor, bottom: UIColor) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [top.cgColor, bottom.cgColor] as CFArray,
            locations: [0, 1]
        ) else {
            return
        }
        cgContext.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )
    }

    /// 縦グラデーション画像を UIImage として生成する（サイズ指定・scale=1固定）
    private func makeGradientImage(size: CGSize, topColor: UIColor, bottomColor: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            drawVerticalGradient(in: rendererContext.cgContext, rect: CGRect(origin: .zero, size: size), top: topColor, bottom: bottomColor)
        }
    }

    // MARK: - Private: 実写リサイズ（実装メモ）

    /// 画像の長辺が maxLongSide を超えていれば、アスペクト比を保ったまま縮小する。
    /// - Note: `UIImage.draw(in:)` は imageOrientation を考慮して描画するため、
    ///   結果の UIImage は常に `.up`（向き焼き込み済み）になる。
    private func resizedIfNeeded(_ image: UIImage, maxLongSide: CGFloat) -> UIImage {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxLongSide else { return image }

        let scale = maxLongSide / longSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Private: PNG 書き出し

    private func writePNG(_ image: UIImage, filename: String, to directory: URL) throws {
        guard let data = image.pngData() else {
            XCTFail("\(filename): pngData() 変換に失敗")
            return
        }
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url)
    }
}
