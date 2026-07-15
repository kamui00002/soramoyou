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

    /// `renderVideo` が `writer.startWriting()` 成功後に失敗した場合、書きかけの mp4 ファイルを
    /// 削除することを検証する（PR レビュー指摘Aの回帰テスト）。
    ///
    /// 失敗経路を作る方式の選定理由:
    /// - Engine を未 prepare のまま呼ぶ方式（`notPrepared`）は `writer.startWriting()` より前で
    ///   throw するため、defer によるクリーンアップを一切経由せず検証にならない。
    /// - `makeFrame` を確実に nil にする決定的な入力（kernel はあるが photo/mask だけ壊す等）は
    ///   `LivingSkyEngine` の公開APIから作れない。
    /// - そこで「書き出し開始直後に Task をキャンセルする」方式を採る。`renderVideo` は
    ///   ループの毎回の先頭で `try Task.checkCancellation()` を呼んでおり、これは
    ///   `writer.startWriting()`（＝ファイル生成済み）より必ず後に実行されるため、
    ///   Metal カーネルの可否に関わらず必ず「startWriting成功後の失敗」を再現できる
    ///   （Metal が使えない環境では `engine.makeFrame` が nil を返して `writingFailed` になる
    ///   が、いずれにせよ startWriting 後の失敗経路を通る点は変わらない）。このため、他のテストと
    ///   異なり `engine.isAvailable` による XCTSkip は行わない（常に実行されることが本テストの
    ///   前提のため）。
    /// - `loopDuration` は既定値（`LivingSkyParameters()` の 6.0 秒＝180フレーム。v2で8.0→6.0に改定）
    ///   のまま使う。ループ本体が長いほど「セットアップ完了→ループ先頭のキャンセル検知」までの
    ///   時間的余裕が確保しやすく、キャンセルが確実にループ内（＝defer 登録後）で検知されるようにするため。
    ///
    /// 非自明性の根拠（このテストは fix 前だと失敗する）: `AVAssetWriter` は `startWriting()` の
    /// 時点で出力 URL にファイルを生成する。修正前のコードは `Task.checkCancellation()` の throw を
    /// 個別の `writer.cancelWriting()` 呼び出しでカバーしておらず、キャンセル経由の失敗では
    /// 書きかけファイルが削除されずに残っていた。修正後は defer が全失敗経路を一本化してカバーする。
    func test_renderVideo_cleansUpFileOnFailure() async throws {
        let engine = LivingSkyEngine()

        let size = 128
        let photo = CIImageTestHelpers.makeTwoBandCIImage(size: size)
        let mask = CIImage(color: CIColor.white).cropped(to: photo.extent)
        engine.setPreparedStateForTesting(photo: photo, mask: mask)
        // engine.parameters は既定値（loopDuration=6.0秒）のまま使う（理由は上記コメント参照）。

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let exporter = LivingSkyVideoExporter()
        let renderTask = Task {
            try await exporter.renderVideo(to: tempURL, engine: engine) { _ in }
        }
        renderTask.cancel()

        do {
            try await renderTask.value
            XCTFail("キャンセルしたのに renderVideo が成功してしまった")
        } catch {
            // どのエラー型で throw されるかは Metal の可否・タイミングに依存する
            // （CancellationError または LivingSkyVideoExporterError.writingFailed）ため、
            // 型は問わず「throw されたこと」だけを確認する。
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempURL.path),
            "キャンセルによる失敗時に書きかけの mp4 ファイルが削除されずに残っている（defer によるクリーンアップの回帰）"
        )
    }
}
