// ⭐️ LivingSkyVideoExporter.swift
// Living Sky（空のループアニメーション）の mp4 書き出し・Photos 保存
//
//  LivingSkyVideoExporter.swift
//  Soramoyou
//
// 設計書: docs/living-sky-design.md §5（動画書き出し）
//
// 責務を2段に分離する（テスト可能性のため。Photos権限に依存する保存処理をレンダリングから独立させる）:
// - (a) `renderVideo(to:engine:progress:)`: prepare 済み LivingSkyEngine からループ1周分の mp4 を書き出す
// - (b) `saveToPhotos(fileURL:)`: 書き出した mp4 を Photos ライブラリへ保存する

import AVFoundation
import CoreImage
import Photos
import UIKit

/// `LivingSkyVideoExporter` の処理中に発生しうるエラー
enum LivingSkyVideoExporterError: Error, LocalizedError {
    /// `engine` が `prepare` 済みでない（photo/mask が無い）
    case notPrepared
    /// `AVAssetWriter` の初期化・入力追加に失敗した
    case writerInitializationFailed
    /// `AVAssetWriterInputPixelBufferAdaptor` の pixelBufferPool が取得できない
    case pixelBufferPoolUnavailable
    /// `CVPixelBuffer` の生成に失敗した
    case pixelBufferCreationFailed
    /// 書き出し処理（フレーム生成・append・finishWriting）が失敗した
    case writingFailed(String)
    /// Photos への書き込み権限が無い（`.authorized`/`.limited` 以外）
    case photosAccessDenied

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "空の解析が完了していません"
        case .writerInitializationFailed:
            return "動画の初期化に失敗しました"
        case .pixelBufferPoolUnavailable, .pixelBufferCreationFailed:
            return "動画フレームの生成に失敗しました"
        case .writingFailed(let reason):
            return "動画の書き出しに失敗しました: \(reason)"
        case .photosAccessDenied:
            return "写真への保存が許可されていません。設定アプリで許可してください"
        }
    }
}

/// Living Sky のループアニメーションを mp4 として書き出し、Photos ライブラリへ保存するエンジン。
final class LivingSkyVideoExporter {

    // MARK: - 定数

    /// 出力フレームレート（設計書§5: 30fps）
    private static let frameRate: Int32 = 30

    /// 動画の平均ビットレート（bps）。SNS向けサイズと画質のバランスを見て12Mbpsに設定。
    private static let averageBitRate: Int = 12_000_000

    // MARK: - (a) mp4 書き出し

    /// prepare 済みの `LivingSkyEngine` から、ループちょうど1周分の mp4 を書き出す。
    ///
    /// - Parameters:
    ///   - url: 書き出し先ファイル URL（`AVAssetWriter` は上書き不可のため、事前に存在しないこと）
    ///   - engine: `.export` 品質で `prepare` 済みのエンジン（未 prepare なら `notPrepared` を throw）
    ///   - progress: 0...1 の進捗コールバック（メインスレッドとは限らないため呼び出し側で dispatch する）
    func renderVideo(
        to url: URL,
        engine: LivingSkyEngine,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard let photo = engine.preparedPhoto else {
            throw LivingSkyVideoExporterError.notPrepared
        }

        // 設計書§5: フレーム数 = ループ長T × 30fps（例: T=8s → 240フレーム）。
        // フレーム i の時刻 = i/30 秒として `engine.makeFrame(elapsed:)` に渡す。
        let loopDuration = max(engine.parameters.loopDuration, 0.001)
        let frameCount = max(1, Int((loopDuration * Double(Self.frameRate)).rounded()))

        // H.264 は奇数寸法を受け付けないため、偶数へ丸める（`width & ~1` で最下位ビットを落とす）。
        let rawWidth = Int(photo.extent.width.rounded())
        let rawHeight = Int(photo.extent.height.rounded())
        let width = max(2, rawWidth & ~1)
        let height = max(2, rawHeight & ~1)
        let outputExtent = CGRect(x: 0, y: 0, width: width, height: height)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw LivingSkyVideoExporterError.writerInitializationFailed
        }

        // 設計書§7「動画の再エンコードで継ぎ目が滲む」対策: キーフレーム間隔をループ長（=全フレーム数）に
        // 揃えることで、ループの継ぎ目付近に余計なキーフレームが挟まって画質が滲むのを避ける。
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: Self.averageBitRate,
            AVVideoMaxKeyFrameIntervalKey: frameCount
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw LivingSkyVideoExporterError.writerInitializationFailed
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw LivingSkyVideoExporterError.writingFailed(
                writer.error?.localizedDescription ?? "startWriting に失敗しました"
            )
        }
        writer.startSession(atSourceTime: .zero)

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            throw LivingSkyVideoExporterError.pixelBufferPoolUnavailable
        }

        let ciContext = CIContextPool.shared.ciContext
        guard let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LivingSkyVideoExporterError.writerInitializationFailed
        }

        for i in 0..<frameCount {
            try Task.checkCancellation()

            // input.isReadyForMoreMediaData を待つ（Task.yield で他タスクに実行機会を譲りつつポーリング）。
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                await Task.yield()
            }

            let elapsed = Double(i) / Double(Self.frameRate)
            guard let frame = engine.makeFrame(elapsed: elapsed) else {
                writer.cancelWriting()
                throw LivingSkyVideoExporterError.writingFailed("makeFrame がフレームを生成できませんでした（i=\(i)）")
            }

            var pixelBufferOut: CVPixelBuffer?
            let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBufferOut)
            guard poolStatus == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
                writer.cancelWriting()
                throw LivingSkyVideoExporterError.pixelBufferCreationFailed
            }

            // CVPixelBufferPool 再利用（毎フレーム同じプールから取得・render のみで CGImage/UIImage 変換なし）。
            ciContext.render(frame, to: pixelBuffer, bounds: outputExtent, colorSpace: outputColorSpace)

            let presentationTime = CMTime(value: CMTimeValue(i), timescale: Self.frameRate)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                writer.cancelWriting()
                throw LivingSkyVideoExporterError.writingFailed(
                    writer.error?.localizedDescription ?? "append に失敗しました（i=\(i)）"
                )
            }

            progress(Double(i + 1) / Double(frameCount))
        }

        input.markAsFinished()

        // AVAssetWriter.finishWriting はコールバック API のため withCheckedThrowingContinuation で
        // async/await に橋渡しする。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: LivingSkyVideoExporterError.writingFailed(
                            writer.error?.localizedDescription ?? "status=\(writer.status.rawValue)"
                        )
                    )
                }
            }
        }
    }

    // MARK: - (b) Photos 保存

    /// 書き出し済みの mp4 ファイルを Photos ライブラリへ保存する。
    ///
    /// - Parameter fileURL: `renderVideo(to:engine:progress:)` で書き出した mp4 の URL
    func saveToPhotos(fileURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw LivingSkyVideoExporterError.photosAccessDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
        }

#if DEBUG
        // DEBUG ビルドでは E2E 検証用に一時ファイルを削除せず残す
        // （呼び出し側 `LivingSkyPreviewView` がパスを print してレビュアーが実ファイルを確認できるようにする）。
#else
        // Release ビルドでは保存成功後に一時ファイルを削除する。
        try? FileManager.default.removeItem(at: fileURL)
#endif
    }
}
