//
//  LivingSkyVideoExporterTests.swift
//  SoramoyouTests
//
//  ⭐️ LivingSkyVideoExporter（Living Sky の mp4 書き出し）のユニットテスト。
//  設計書 docs/living-sky-design.md §5（動画書き出し）。
//  `saveToPhotos` は Photos 権限に依存するため対象外（`renderVideo` のみ検証する）。
//

import XCTest
import AVFoundation
import CoreImage
@testable import Soramoyou

final class LivingSkyVideoExporterTests: XCTestCase {

    /// `renderVideo` が有効な mp4 を書き出すことを検証する。
    ///
    /// - `setPreparedStateForTesting` で prepare を経由せず、決定的なテスト用 photo/mask
    ///   （2色バンド写真 × 全面「空」扱いの白マスク）を直接注入する。
    /// - `loopDuration: 1.0` にして 30fps × 1秒 = 30フレームの短い書き出しでテストを高速に保つ。
    /// - シミュレータの Metal 環境で CIKernel をロードできない場合は XCTSkip で逃がす。
    func test_renderVideo_producesValidMP4() async throws {
        let engine = LivingSkyEngine()
        guard engine.isAvailable else {
            throw XCTSkip("この実行環境では Living Sky の Metal カーネルをロードできない")
        }

        let size = 128
        let photo = CIImageTestHelpers.makeTwoBandCIImage(size: size)
        let mask = CIImage(color: CIColor.white).cropped(to: photo.extent)
        engine.setPreparedStateForTesting(photo: photo, mask: mask)
        engine.parameters = LivingSkyParameters(
            windAngleDegrees: 30,
            speed: 1.0,
            shimmerAmount: 0.05,
            loopDuration: 1.0
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempURL)
        }

        var progressValues: [Double] = []
        let exporter = LivingSkyVideoExporter()
        try await exporter.renderVideo(to: tempURL, engine: engine) { value in
            progressValues.append(value)
        }

        // ①ファイル存在＆サイズ>0
        let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let fileSize = (attributes[.size] as? Int) ?? 0
        XCTAssertGreaterThan(fileSize, 0, "書き出した mp4 のファイルサイズが 0")

        // ②AVURLAsset の duration が 1.0±0.1s
        let asset = AVURLAsset(url: tempURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        XCTAssertEqual(
            durationSeconds, 1.0, accuracy: 0.1,
            "動画の長さが期待値（1.0s）から外れている: \(durationSeconds)s"
        )

        // ③videoTrack の naturalSize が偶数寸法（H.264 は奇数寸法不可のため clampToEven の確認）
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            XCTFail("videoTrack が見つからない")
            return
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        XCTAssertEqual(Int(naturalSize.width) % 2, 0, "幅が偶数寸法でない: \(naturalSize.width)")
        XCTAssertEqual(Int(naturalSize.height) % 2, 0, "高さが偶数寸法でない: \(naturalSize.height)")

        // ④progress が単調増加で最後に≥0.96 に達した
        XCTAssertFalse(progressValues.isEmpty, "progress コールバックが一度も呼ばれなかった")
        for i in 1..<progressValues.count {
            XCTAssertGreaterThanOrEqual(
                progressValues[i], progressValues[i - 1],
                "progress が単調増加していない（index \(i): \(progressValues[i - 1]) → \(progressValues[i])）"
            )
        }
        XCTAssertGreaterThanOrEqual(
            progressValues.last ?? 0, 0.96,
            "progress の最終値が 0.96 未満: \(progressValues.last ?? 0)"
        )

        // 報告用に実測値を出力する（fileSize / duration / naturalSize）
        print(
            "LivingSkyVideoExporterTests: fileSize=\(fileSize)bytes " +
            "duration=\(durationSeconds)s naturalSize=\(naturalSize) " +
            "progressLast=\(progressValues.last ?? 0)"
        )
    }
}
