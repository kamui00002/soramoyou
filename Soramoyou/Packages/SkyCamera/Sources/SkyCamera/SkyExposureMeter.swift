import AVFoundation
import CoreVideo
import Foundation

/// プレビュー映像から「白飛びしている画素の割合」を実測する測光器。
///
/// `AVCaptureVideoDataOutput` で流れてくるフレームの輝度プレーン（Y）だけを間引いて読み、
/// 判定そのものは `SkyPriorityExposure`（純関数）へ渡す。ここは配管に徹する。
///
/// 負荷対策は 2 段構え。
/// 1. 時間で間引く（既定 4 回／秒）。露出は人の目より速く動く必要が無い。
/// 2. 空間で間引く（縦横それぞれ約 100 点）。1920×1440 を全部読むと 276 万画素だが、
///    100×100 に間引けば 1 万点で済む。白飛び「率」を見るだけなので精度は十分。
final class SkyExposureMeter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    // MARK: - Properties

    /// セッションへ挿す出力。構成は `prepare()` で済ませる。
    let output = AVCaptureVideoDataOutput()

    /// フレーム処理専用のキュー。セッションキューを塞ぐと撮影が詰まるので必ず分ける。
    private let queue = DispatchQueue(label: "app.soramoyou.skycamera.meter", qos: .userInitiated)

    /// 測定結果（白飛び率 0〜1）の通知先。`queue` 上で呼ばれる。
    private let onMeasure: (Double) -> Void

    /// 届くバッファが Full Range かどうか。`prepare()` で確定する。
    private var isFullRange = true

    /// 有効化フラグ。`queue` 上でのみ読み書きしてデータ競合を避ける。
    private var isEnabled = false

    /// 最後に処理した時刻（`CACurrentMediaTime` 相当の単調時計）。
    private var lastProcessedAt: CFTimeInterval = 0

    /// 処理の最短間隔（秒）。4 回／秒。
    private let minInterval: CFTimeInterval = 0.25

    /// 間引き後に狙うサンプル数（縦横それぞれ）。
    private let targetSamplesPerAxis = 100

    /// Full Range 基準の白飛び閾値。
    private let clipThreshold: UInt8

    // MARK: - Init

    init(clipThreshold: UInt8, onMeasure: @escaping (Double) -> Void) {
        self.clipThreshold = clipThreshold
        self.onMeasure = onMeasure
        super.init()
    }

    // MARK: - Setup

    /// 出力のピクセル形式を決めてデリゲートを張る。
    /// `session.addOutput(_:)` の**前**に呼ぶこと（形式の選択に利用可能一覧を使うため）。
    func prepare() {
        // 輝度をそのまま読みたいので YCbCr の 2 面形式を選ぶ。RGB だと変換コストが乗る。
        let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let available = output.availableVideoPixelFormatTypes
        if available.contains(full) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: full]
            isFullRange = true
        } else if available.contains(video) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: video]
            isFullRange = false
        }
        // 処理が間に合わないフレームは捨てる。溜めるとメモリを食うだけで露出判定には無意味。
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// 測定の ON/OFF。OFF のあいだはフレームを即座に捨てる。
    func setEnabled(_ enabled: Bool) {
        queue.async {
            self.isEnabled = enabled
            // 次に ON になったとき間隔待ちで取りこぼさないよう、時計を巻き戻しておく。
            self.lastProcessedAt = 0
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isEnabled else { return }

        // 時間で間引く。露出制御に 30fps は要らない。
        let now = CACurrentMediaTime()
        guard now - lastProcessedAt >= minInterval else { return }
        lastProcessedAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let luma = sampleLumaPlane(pixelBuffer) else { return }

        let threshold = SkyPriorityExposure.effectiveThreshold(
            fullRangeThreshold: clipThreshold, isFullRange: isFullRange)
        let fraction = SkyPriorityExposure.clippedFraction(luma: luma, threshold: threshold)
        onMeasure(fraction)
    }

    // MARK: - Private

    /// 輝度プレーン（plane 0）を間引いて読む。
    /// 合成バッファでの検証ができるよう internal にしてある（`@testable import` から呼ぶ）。
    /// - Returns: 間引いた輝度サンプル。読めなければ nil
    func sampleLumaPlane(_ pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        // 読み取り中にバッファが書き換わらないようロックする。
        // defer で必ず解除する（途中 return でも取りこぼさない）。
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0, bytesPerRow >= width else { return nil }

        // 縦横それぞれ目標サンプル数まで間引く。
        let strideX = max(1, width / targetSamplesPerAxis)
        let strideY = max(1, height / targetSamplesPerAxis)

        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var samples: [UInt8] = []
        samples.reserveCapacity((width / strideX + 1) * (height / strideY + 1))

        // ⚠️ 行の先頭間隔は width ではなく bytesPerRow を使う。
        //    ハードウェアは行末にパディングを入れることがあり、width で進むと行がずれていく。
        var y = 0
        while y < height {
            let rowStart = y * bytesPerRow
            var x = 0
            while x < width {
                samples.append(pointer[rowStart + x])
                x += strideX
            }
            y += strideY
        }
        return samples
    }
}
