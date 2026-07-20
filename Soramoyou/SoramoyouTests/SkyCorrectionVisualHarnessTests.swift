//
//  SkyCorrectionVisualHarnessTests.swift
//  SoramoyouTests
//
//  ⭐️ 意図的に残す開発用目視ハーネス（入力フォルダが無ければ自動スキップ・CIに影響なし）
//
//  ワンタップ空補正（EditViewModel.applySkyCorrection → generateFinalImage）の
//  Before/After を実写画像に対して書き出し、人間（レビュアー）が目視確認できるようにする
//  使い捨てテスト。SkyReplacementVisualHarnessTests と同型の運用パターン。
//
//  2026-07-20 追加背景: シミュレータ実写検証で「明るいグレーの壁が空マスクに誤包含され、
//  空補正で青く染まる」問題（IMG_8225系の見上げ構図）が見つかったため、空色適応ゲート
//  （SkyColorGate）を導入した。本ハーネスはその軽減効果を実写9枚で目視確認するための資産。
//

import XCTest
import CoreImage
import UIKit
@testable import Soramoyou

@MainActor
final class SkyCorrectionVisualHarnessTests: XCTestCase {

    // MARK: - 定数（入出力フォルダ）

    /// 実写画像を置く入力フォルダ（存在しなければ XCTSkip する）
    private static let inputDirectoryPath = "/tmp/sky-replace-test/poc-jpeg"
    /// Before/After の PNG を書き出す出力フォルダ
    private static let outputDirectoryPath = "/tmp/sky-replace-test/output/sky-correction"

    /// 実写画像を渡す前に縮小する長辺の上限（アプリ本体の画像制約と同じ値）
    private static let maxLongSide: CGFloat = 2048

    // MARK: - Tests

    func test_visualHarness_skyCorrectionBeforeAfter() async throws {
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

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg"]
        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: inputDirectoryURL,
            includingPropertiesForKeys: nil
        ))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        var summaryLines: [String] = []

        for url in fileURLs where imageExtensions.contains(url.pathExtension.lowercased()) {
            guard let loaded = UIImage(contentsOfFile: url.path) else {
                XCTFail("画像読み込みに失敗: \(url.path)")
                continue
            }
            let name = url.deletingPathExtension().lastPathComponent
            let image = resizedIfNeeded(loaded, maxLongSide: Self.maxLongSide)

            // アプリ本体と同じ経路（EditViewModel.applySkyCorrection → generateFinalImage）を
            // 実サービス（ImageService・HeuristicSkyMaskProvider）で通す。
            let vm = EditViewModel(
                images: [image],
                userId: nil,
                imageService: ImageService(),
                firestoreService: MockFirestoreService(),
                skyMaskProvider: HeuristicSkyMaskProvider()
            )
            await Task.yield()

            await vm.applySkyCorrection()

            if let errorMessage = vm.errorMessage {
                // 空が十分に検出できない写真は「適用しない」が正しい挙動。失敗にはせず記録だけ残す。
                summaryLines.append("\(name): SKIPPED (\(errorMessage))")
                let skipURL = outputDirectoryURL.appendingPathComponent("\(name)__SKIPPED.txt")
                try? errorMessage.write(to: skipURL, atomically: true, encoding: .utf8)
                continue
            }

            do {
                let output = try await vm.generateFinalImage()
                // before.png は `image`（EditViewModel に渡したのと同じ、EXIF 向きタグ付きのまま
                // 未加工の入力）を焼き込んでから書き出す。`UIImage.pngData()` は imageOrientation を
                // 焼き込まず生ピクセルをそのまま書き出すため（後述 bakeOrientation 参照）、
                // 焼き込まずに書くと before/after で向きが食い違い目視比較にならない。
                // EditViewModel 自体には常に未加工の `image` を渡している（実アプリと同じ経路で
                // 向き正規化=Fix1 を実際に通す）。
                try writePNG(bakeOrientation(image), filename: "\(name)__before.png", to: outputDirectoryURL)
                try writePNG(output, filename: "\(name)__after.png", to: outputDirectoryURL)
                let intensity = vm.editRecipe.skyCorrectionIntensity ?? 0
                summaryLines.append("\(name): applied (intensity=\(intensity))")
            } catch {
                XCTFail("\(name): 書き出し失敗: \(error)")
            }
        }

        // 手順: 結果一覧を print（レビュアーがコンソールでも把握できるように）
        print("=== SkyCorrectionVisualHarness 処理結果一覧 ===")
        for line in summaryLines {
            print(line)
        }
    }

    // MARK: - Private: 実写リサイズ

    /// 画像の長辺が maxLongSide を超えていれば、アスペクト比を保ったまま縮小する。
    /// EditViewModel には実アプリと同じ「EXIF 向きタグ付きのまま・向き未焼き込み」の画像を渡す
    /// （`normalizedTransformedImage` による向き正規化＝Fix1 を実際に通すため、ここでは
    /// 縮小が不要なら imageOrientation はそのまま保持する）。
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

    // MARK: - Private: 向き焼き込み（PNG 書き出し前の前処理）

    /// `.up` へ向きを焼き込む（`UIImage.draw(in:)` は imageOrientation を考慮して描画するため、
    /// 結果は常に `.up` になる）。
    ///
    /// - Note: `UIImage.pngData()` は imageOrientation を焼き込まず CGImage の生ピクセルを
    ///   そのまま書き出す（`CIImage(cgImage:)` と同じ「向きを無視する罠」、
    ///   `Feature1FoundationTests` のコメント参照）。目視ハーネスの before.png をこのまま書くと
    ///   before（未焼き込み）/ after（EditViewModel が内部で焼き込み済み）で向きが食い違い、
    ///   目視比較にならない。before.png を書き出す直前にだけ本関数を通す。
    private func bakeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
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
