// ⭐️ PhotoKitAdapter.swift
// PhotoKit (PHAdjustmentData) ↔ EditRecipe 変換アダプター
// 「続きを編集」（Resume Editing）機能の実現
//
//  PhotoKitAdapter.swift
//  Soramoyou
//
// 🔧 Phase 0 修正 (2026-04-22):
//   - saveEdit のシグネチャ変更: renderedImage: CGImage → renderedCIImage: CIImage
//     （二重ラスタライズ回避：CIImage を最後まで持つ）
//   - HEIF 書き出しを .RGBA8 → .RGBAh（10bit HEIF で iPhone 純正と同等画質）
//   - JPEG 書き出しに compressionQuality: 0.95 を明示指定
//   - PNG は引き続き CGImage 経由（PNG は 8bit 上限なので問題なし）
//   - print ログを os.Logger に置換（rules/swift.md 準拠）
//
// 🔧 Phase 2 追加 (2026-04-22):
//   - EditRecipe.targetDynamicRange == .hdr で iOS 17+ 時に
//     `writeHEIF10Representation` を呼び出し、10bit HDR HEIF として書き出す
//   - 投稿用 (JPEG 8bit, StorageService) と写真保存用 (HEIF10, ここ) の動線分離
//

import CoreImage
import os
import Photos
import UIKit

private let logger = Logger(subsystem: "com.soramoyou.photo-editor", category: "PhotoKitAdapter")

/// PhotoKit との連携アダプター
///
/// PHAdjustmentData を使用することで、Photos アプリからアプリ内で
/// 「続きを編集」（Resume Editing）ができるようになる。
///
/// 設計ポイント:
/// - formatIdentifier は基本不変（変えると過去編集の再開不可）
/// - formatVersion はスキーマ破壊変更時にインクリメント
/// - デコード失敗時はレンダ済み画像だけ使うフォールバックを提供
final class PhotoKitAdapter {

    // MARK: - 定数

    /// アプリ固有の識別子
    /// 【重要】この値を変えると過去の編集が再開不可になる
    static let formatIdentifier = "com.soramoyou.photo-editor"

    /// レシピスキーマバージョン
    static let formatVersion = "1.0"

    // MARK: - EditRecipe ↔ PHAdjustmentData 変換

    /// EditRecipe を PHAdjustmentData に変換する
    static func adjustmentData(from recipe: EditRecipe) throws -> PHAdjustmentData {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting     = .prettyPrinted
        let data = try encoder.encode(recipe)

        return PHAdjustmentData(
            formatIdentifier: formatIdentifier,
            formatVersion:    formatVersion,
            data:             data
        )
    }

    /// PHAdjustmentData から EditRecipe を復元する
    static func recipe(from adjustmentData: PHAdjustmentData) -> EditRecipe? {
        guard adjustmentData.formatIdentifier == formatIdentifier else {
            return nil
        }

        if adjustmentData.formatVersion != formatVersion {
            logger.info("formatVersion の不一致: \(adjustmentData.formatVersion, privacy: .public) vs \(Self.formatVersion, privacy: .public)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(EditRecipe.self, from: adjustmentData.data)
        } catch {
            logger.error("レシピのデコードに失敗: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - PHAsset への編集保存

    /// PHAsset に編集を保存する（Resume Editing 対応）
    ///
    /// 🔧 Phase 0 修正: `renderedImage: CGImage` → `renderedCIImage: CIImage`
    /// CIImage を最後まで保持することで「8bit CGImage → CIImage → HEIF」の二重劣化を回避。
    /// HEIF 10bit (RGBAh) 保存で iPhone 純正写真アプリと同等の画質を維持する。
    ///
    /// 🔧 Phase 2 追加: `recipe.targetDynamicRange == .hdr` かつ iOS 17+ で
    /// `writeHEIF10Representation` を使用（EDR 対応端末で真の HDR 表示が可能）。
    static func saveEdit(
        asset:            PHAsset,
        recipe:           EditRecipe,
        renderedCIImage:  CIImage,
        exportFormat:     ExportFormat = .heif
    ) async throws {
        let input = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PHContentEditingInput, Error>) in
            asset.requestContentEditingInput(with: nil) { input, _ in
                if let input = input {
                    continuation.resume(returning: input)
                } else {
                    continuation.resume(throwing: PhotoKitAdapterError.contentEditingInputFailed)
                }
            }
        }

        let pool = CIContextPool.shared

        // PNG は CGImage 経由で pngData を生成（事前準備）
        // HEIF/JPEG は CIImage のまま writeXxxRepresentation に渡す
        let writeData: Data?
        switch exportFormat {
        case .heif, .jpeg:
            writeData = nil
        case .png:
            guard let cgImage = pool.ciContext.createCGImage(
                renderedCIImage,
                from: renderedCIImage.extent,
                format: .RGBAh,
                colorSpace: pool.outputColorSpace
            ) else {
                throw PhotoKitAdapterError.renderFailed
            }
            writeData = UIImage(cgImage: cgImage).pngData()
            if writeData == nil {
                throw PhotoKitAdapterError.renderFailed
            }
        }

        let useHDR = recipe.targetDynamicRange == .hdr

        // ultrareview bug_006 / M2 修正:
        // performChanges のクロージャは非 throwing のため、内部 catch で `return` しても
        // 外側の `try await` に例外が伝搬せず silent data loss になる。
        // クロージャ内のエラーを保持し、performChanges 完了後に throw する。
        //
        // `@Sendable` クロージャからローカル `var` を直接キャプチャすると Swift 6 strict
        // concurrency でエラーになるため、参照型のボックスを使って境界を越える。
        // `try await performChanges` が完了するまで呼び出し側はサスペンドしているので
        // 実行時のデータ競合は起きない（@unchecked Sendable として安全）。
        final class ErrorBox: @unchecked Sendable {
            var value: Error?
        }
        let errorBox = ErrorBox()

        try await PHPhotoLibrary.shared().performChanges {
            let output = PHContentEditingOutput(contentEditingInput: input)
            let outputURL = output.renderedContentURL

            do {
                switch exportFormat {
                case .heif:
                    if useHDR, #available(iOS 17.0, *) {
                        // Phase 2: HDR 書き出し（10bit HEIF、EDR 表示対応）
                        try pool.ciContext.writeHEIF10Representation(
                            of:         renderedCIImage,
                            to:         outputURL,
                            colorSpace: pool.outputColorSpace,
                            options:    [:]
                        )
                        logger.info("HEIF10 (HDR) 書き出し完了")
                    } else {
                        // Phase 0: 10bit HEIF（SDR）
                        try pool.ciContext.writeHEIFRepresentation(
                            of:         renderedCIImage,
                            to:         outputURL,
                            format:     .RGBAh,
                            colorSpace: pool.outputColorSpace
                        )
                    }
                case .jpeg:
                    // Phase 0: compressionQuality 0.95 を明示指定
                    try pool.ciContext.writeJPEGRepresentation(
                        of:         renderedCIImage,
                        to:         outputURL,
                        colorSpace: pool.outputColorSpace,
                        options: [
                            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95
                        ]
                    )
                case .png:
                    try writeData?.write(to: outputURL)
                }
            } catch {
                logger.error("レンダ済み画像の書き出し失敗: \(error.localizedDescription, privacy: .public)")
                errorBox.value = error
                return
            }

            output.adjustmentData = try? adjustmentData(from: recipe)

            let changeRequest = PHAssetChangeRequest(for: asset)
            changeRequest.contentEditingOutput = output
        }

        if errorBox.value != nil {
            throw PhotoKitAdapterError.renderFailed
        }
    }

    // MARK: - 既存編集の読み込み（Resume Editing）

    static func loadExistingRecipe(from asset: PHAsset) async -> EditRecipe? {
        await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: nil) { input, _ in
                guard let adjustmentData = input?.adjustmentData else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: recipe(from: adjustmentData))
            }
        }
    }

    // MARK: - 編集可能判定

    static func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool {
        adjustmentData.formatIdentifier == formatIdentifier
    }
}

// MARK: - エラー定義

enum PhotoKitAdapterError: LocalizedError {
    case contentEditingInputFailed
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .contentEditingInputFailed:
            return "ContentEditingInput の取得に失敗しました"
        case .renderFailed:
            return "レンダ済み画像の書き出しに失敗しました"
        }
    }
}

// MARK: - ExportFormat

/// 書き出しフォーマット
enum ExportFormat {
    case heif
    case jpeg
    case png
}
