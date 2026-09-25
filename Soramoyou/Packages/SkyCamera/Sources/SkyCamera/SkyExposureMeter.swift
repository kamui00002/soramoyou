// ⭐️ プレビュー映像から白飛び率を実測する測光器（空優先AE の目にあたる部分）
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
/// 1 フレーム分の測光結果。
struct SkyMeterReading: Sendable {
    /// 白飛びしている画素の割合（0〜1）。
    let clippedFraction: Double
    /// そのフレームの最大輝度（**届いたバッファの流儀のまま**。Video Range なら最大 235）。
    let peakLuma: UInt8
    /// 届いたバッファが Full Range（0〜255）だったか。
    /// ⭐️ `peakLuma` をどちらの物差しで読むかを後から区別するために要る。
    let isFullRange: Bool
    /// どの範囲を測ったか（空の側だけ／画面全体）。
    let region: SkyPriorityExposure.MeterRegion
}

final class SkyExposureMeter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    // MARK: - Properties

    /// セッションへ挿す出力。構成は `prepare()` で済ませる。
    let output = AVCaptureVideoDataOutput()

    /// フレーム処理専用のキュー。セッションキューを塞ぐと撮影が詰まるので必ず分ける。
    private let queue = DispatchQueue(label: "app.soramoyou.skycamera.meter", qos: .userInitiated)

    /// 測定結果の通知先。`queue` 上で呼ばれる。
    private let onMeasure: (SkyMeterReading) -> Void

    /// 有効化フラグ。`queue` 上でのみ読み書きしてデータ競合を避ける。
    private var isEnabled = false

    /// 最後に処理した時刻（`CACurrentMediaTime` 相当の単調時計）。
    private var lastProcessedAt: CFTimeInterval = 0

    /// この時刻までは測らない（露出補正が実際に効くまでの待ち）。
    /// ⚠️ これが無いと「補正をかけた → まだ効いていない古い明るさを読む → もっと下げる」を
    ///    繰り返して下限まで振り切れる（積分ワインドアップ）。
    ///    シャワーの温度調節でお湯が届く前にさらに捻ってしまうのと同じ構造。
    private var suppressedUntil: CFTimeInterval = 0

    /// 処理の最短間隔（秒）。4 回／秒。
    private let minInterval: CFTimeInterval = 0.25

    /// 間引き後に狙うサンプル数（縦横それぞれ）。
    private let targetSamplesPerAxis = 100

    /// Full Range 基準の白飛び閾値。
    private let clipThreshold: UInt8

    /// 測光する「空の側」の広さ（正立させた画面の上から何割か）。
    private let skyRegionFraction: Double

    /// 撮影を正立させる時計回りの角度（度）。`queue` 上でのみ読み書きする。
    /// ⚠️ 測光用のバッファはセンサー本来の向きのまま届くので、どちらが空かはこの角度で決まる。
    ///    nil（まだ分からない・iOS 16）のあいだは画面全体を測る（今までと同じ・安全側）。
    private var captureRotationDegrees: Double?

    /// 真上（または真下）を向いているか。`queue` 上でのみ読み書きする。
    /// 真上を向くと画面ほぼ全部が空になり「上側」に意味が無いので、画面全体を測る。
    private var looksStraightUp = false

    // MARK: - Init

    init(
        clipThreshold: UInt8,
        skyRegionFraction: Double = SkyPriorityExposure.Tuning.default.skyRegionFraction,
        onMeasure: @escaping (SkyMeterReading) -> Void
    ) {
        self.clipThreshold = clipThreshold
        self.skyRegionFraction = skyRegionFraction
        self.onMeasure = onMeasure
        super.init()
    }

    // MARK: - Setup

    /// 出力のピクセル形式を要求してデリゲートを張る。
    ///
    /// ⚠️ ここで要求した形式が**通る保証は無い**（構成の状態によって
    ///    `availableVideoPixelFormatTypes` が空を返すこともある）。
    ///    そのため実際の輝度レンジは要求値ではなく、**届いたバッファ自身**から
    ///    フレームごとに判定する（`captureOutput` を参照）。ここは希望を伝えるだけ。
    func prepare() {
        // 輝度をそのまま読みたいので YCbCr の 2 面形式を選ぶ。RGB だと変換コストが乗る。
        let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let available = output.availableVideoPixelFormatTypes
        if available.contains(full) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: full]
        } else if available.contains(video) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: video]
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
            self.suppressedUntil = 0
        }
    }

    /// 撮影を正立させる角度を伝える（端末を回すたびに呼ばれる）。
    /// - Parameter degrees: 時計回りの角度（度）。nil なら画面全体を測る
    func setCaptureRotation(_ degrees: Double?) {
        queue.async {
            self.captureRotationDegrees = degrees
        }
    }

    /// 真上（または真下）を向いているかを伝える。
    func setLooksStraightUp(_ looksUp: Bool) {
        queue.async {
            self.looksStraightUp = looksUp
        }
    }

    /// 露出補正を書き込んだあと、それが実際に効くまで測定を見送る。
    /// - Parameter interval: いまから何秒間測らないか
    ///
    /// 既に積まれている待ちより短い指定では**縮めない**（`max` を取る）。
    /// 縮めてしまうと、反映途中の古い明るさを読んで二重に下げる元の問題に戻る。
    func suppressMeasurements(for interval: CFTimeInterval) {
        queue.async {
            self.suppressedUntil = max(self.suppressedUntil, CACurrentMediaTime() + interval)
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isEnabled else { return }

        let now = CACurrentMediaTime()
        // 直前にかけた補正が効くまで待つ。待たずに測ると古い明るさで二重に下げてしまう。
        guard now >= suppressedUntil else { return }
        // 時間で間引く。露出制御に 30fps は要らない。
        guard now - lastProcessedAt >= minInterval else { return }
        lastProcessedAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 空の側だけを測る。向きが分からない／真上を見上げているときは画面全体（安全側）。
        let region: SkyPriorityExposure.SampleRegion
        let regionKind: SkyPriorityExposure.MeterRegion
        if let rotation = captureRotationDegrees, !looksStraightUp {
            region = SkyPriorityExposure.upperRegion(rotationDegrees: rotation, fraction: skyRegionFraction)
            regionKind = .upper
        } else {
            region = .wholeFrame
            regionKind = .wholeFrame
        }

        guard let luma = sampleLumaPlane(pixelBuffer, region: region) else { return }

        let isFullRange = Self.isFullRange(pixelBuffer)
        let threshold = SkyPriorityExposure.effectiveThreshold(
            fullRangeThreshold: clipThreshold,
            isFullRange: isFullRange)
        onMeasure(SkyMeterReading(
            clippedFraction: SkyPriorityExposure.clippedFraction(luma: luma, threshold: threshold),
            peakLuma: SkyPriorityExposure.peakLuma(luma: luma),
            isFullRange: isFullRange,
            region: regionKind))
    }

    // MARK: - Private

    /// 届いたバッファが Full Range（Y が 0〜255）かどうかを、バッファ自身から判定する。
    ///
    /// ⚠️ 「要求した形式」を覚えておいて使ってはいけない。要求が通らなかった場合に取り違えると、
    ///    Y が 235 までしか来ないのに閾値 250 を当て続け、白飛び率が常に 0 ＝
    ///    機能が**黙って死ぬ**。バッファ自身は常に権威ある値を持っているので、毎フレーム聞く。
    ///
    /// 判別できない形式は安全側（Video Range 扱い＝閾値を下げる）へ倒す。
    /// 「効きすぎる」より「一度も効かない」方が発覚が遅く、害が大きいため。
    /// 合成バッファでの検証ができるよう internal にしてある。
    static func isFullRange(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferGetPixelFormatType(pixelBuffer)
            == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    /// 輝度プレーン（plane 0）を間引いて読む。
    /// 合成バッファでの検証ができるよう internal にしてある（`@testable import` から呼ぶ）。
    /// - Parameter region: 読む範囲（既定は画面全体）。間引きの間隔はこの範囲の大きさから決める
    /// - Returns: 間引いた輝度サンプル。読めなければ nil
    func sampleLumaPlane(
        _ pixelBuffer: CVPixelBuffer,
        region: SkyPriorityExposure.SampleRegion = .wholeFrame
    ) -> [UInt8]? {
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

        // 読む範囲を画素へ直し、その範囲の中で縦横それぞれ目標サンプル数まで間引く。
        let ranges = region.pixelRanges(width: width, height: height)
        let strideX = max(1, ranges.x.count / targetSamplesPerAxis)
        let strideY = max(1, ranges.y.count / targetSamplesPerAxis)

        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var samples: [UInt8] = []
        samples.reserveCapacity((ranges.x.count / strideX + 1) * (ranges.y.count / strideY + 1))

        // ⚠️ 行の先頭間隔は width ではなく bytesPerRow を使う。
        //    ハードウェアは行末にパディングを入れることがあり、width で進むと行がずれていく。
        var y = ranges.y.lowerBound
        while y < ranges.y.upperBound {
            let rowStart = y * bytesPerRow
            var x = ranges.x.lowerBound
            while x < ranges.x.upperBound {
                samples.append(pointer[rowStart + x])
                x += strideX
            }
            y += strideY
        }
        return samples
    }
}
