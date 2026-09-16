//
//  SkyExposureMeterTests.swift ⭐️
//  SoramoyouTests
//
//  空優先 AE の「フレームバッファを読む」部分を、合成した CVPixelBuffer で検証する。
//  実機カメラが無いと確かめられないと思われがちだが、既知の中身を持つバッファを
//  自分で作れば机の上で確定できる。ここは実機でしか踏めない罠が多いので価値が高い。
//

import XCTest
import CoreVideo
@testable import SkyCamera

final class SkyExposureMeterTests: XCTestCase {

    /// 輝度プレーンを指定した値で埋めた YCbCr バッファを作る。
    /// - Parameter fill: (x, y) → 輝度値
    private func makeBuffer(width: Int, height: Int,
                            fill: (Int, Int) -> UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                pointer[y * bytesPerRow + x] = fill(x, y)
            }
        }
        return buffer
    }

    private func makeMeter() -> SkyExposureMeter {
        SkyExposureMeter(clipThreshold: 250) { _ in }
    }

    // MARK: - 行の読み出し

    func testSamplesAreReadFromCorrectRows() throws {
        // ⭐️ 本命。幅 100 は 64 バイト境界に揃わないので、CoreVideo が行末に余白を入れる。
        //    `bytesPerRow` ではなく `width` で行を進めると、読む位置が段々ズレていく。
        //    「y 行目は全部 y」で埋めておけば、ズレれば値が合わなくなって必ず露見する。
        let width = 100, height = 100
        let buffer = try XCTUnwrap(makeBuffer(width: width, height: height) { _, y in UInt8(y) })
        XCTAssertGreaterThan(
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), width,
            "前提: 行末に余白があるバッファであること（無いとこのテストは罠を踏めない）")

        let samples = try XCTUnwrap(makeMeter().sampleLumaPlane(buffer))
        // 100x100 は目標 100 点なので stride=1。全画素が順に並ぶ。
        XCTAssertEqual(samples.count, width * height)
        // 各行の先頭は行番号と一致するはず。
        for y in 0..<height {
            XCTAssertEqual(samples[y * width], UInt8(y), "\(y) 行目の読み出し位置がずれている")
        }
    }

    // MARK: - 間引き

    func testLargeFrameIsThinnedOut() throws {
        // 実機に近いサイズ。全画素（276万）ではなく約 1 万点まで間引かれること。
        let buffer = try XCTUnwrap(makeBuffer(width: 1920, height: 1440) { _, _ in 128 })
        let samples = try XCTUnwrap(makeMeter().sampleLumaPlane(buffer))
        XCTAssertLessThan(samples.count, 20_000, "間引きが効いていない（毎フレーム重くなる）")
        XCTAssertGreaterThan(samples.count, 5_000, "間引きすぎ。白飛び率の精度が落ちる")
    }

    // MARK: - 白飛び率まで通した検証

    func testFullyBlownFrameMeasuresAsFullyClipped() throws {
        // 全面が真っ白 → 白飛び率 1.0
        let buffer = try XCTUnwrap(makeBuffer(width: 200, height: 200) { _, _ in 255 })
        let samples = try XCTUnwrap(makeMeter().sampleLumaPlane(buffer))
        XCTAssertEqual(
            SkyPriorityExposure.clippedFraction(luma: samples, threshold: 250), 1.0, accuracy: 0.0001)
    }

    func testHalfBlownFrameMeasuresAsHalfClipped() throws {
        // 上半分だけ真っ白（＝明るい空と暗い地面）→ 白飛び率は約 0.5
        let buffer = try XCTUnwrap(makeBuffer(width: 200, height: 200) { _, y in
            y < 100 ? 255 : 30
        })
        let samples = try XCTUnwrap(makeMeter().sampleLumaPlane(buffer))
        let fraction = SkyPriorityExposure.clippedFraction(luma: samples, threshold: 250)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.05)

        // そしてこの状況では必ず露出が下がること（機能の目的そのもの）。
        let next = SkyPriorityExposure.decideBias(
            clippedFraction: fraction, currentBias: 0, deviceLimits: -8.0...8.0)
        XCTAssertLessThan(next, 0, "空が半分飛んでいるのに露出を下げていない")
    }

    func testDarkFrameMeasuresAsNoClipping() throws {
        // 暗い場面では下げない（夜空・室内で無駄に暗くしないこと）。
        let buffer = try XCTUnwrap(makeBuffer(width: 200, height: 200) { _, _ in 40 })
        let samples = try XCTUnwrap(makeMeter().sampleLumaPlane(buffer))
        let fraction = SkyPriorityExposure.clippedFraction(luma: samples, threshold: 250)
        XCTAssertEqual(fraction, 0, accuracy: 0.0001)

        let next = SkyPriorityExposure.decideBias(
            clippedFraction: fraction, currentBias: 0, deviceLimits: -8.0...8.0)
        XCTAssertEqual(next, 0, accuracy: 0.0001, "暗い場面なのに露出を触っている")
    }
}
