// ⭐️ PhotoKitAdapter.swift
// PhotoKit (PHAdjustmentData) ↔ EditRecipe 変換アダプター
// 「続きを編集」（Resume Editing）機能の実現
//
//  PhotoKitAdapter.swift
//  Soramoyou
//

import Photos
import UIKit

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
    ///
    /// - Parameter adjustmentData: Photos から渡される調整データ
    /// - Returns: 復元されたレシピ、または nil（デコード失敗時）
    static func recipe(from adjustmentData: PHAdjustmentData) -> EditRecipe? {
        // 自アプリのデータかチェック
        guard adjustmentData.formatIdentifier == formatIdentifier else {
            // 他アプリの編集データ → 復元不可
            return nil
        }

        // バージョン互換チェック
        if adjustmentData.formatVersion != formatVersion {
            // 将来: バージョンに応じたマイグレーション処理を追加
            print("[PhotoKitAdapter] formatVersion の不一致: \(adjustmentData.formatVersion) vs \(formatVersion)")
        }

        // デコード
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(EditRecipe.self, from: adjustmentData.data)
        } catch {
            // デコード失敗 → nil を返してフォールバック（レンダ済み画像のみ使用）
            print("[PhotoKitAdapter] レシピのデコードに失敗: \(error)")
            return nil
        }
    }

    // MARK: - PHAsset への編集保存

    /// PHAsset に編集を保存する（Resume Editing 対応）
    ///
    /// PhotoKit の「Editing Asset Content」ワークフロー:
    /// 1. PHContentEditingOutput.renderedContentURL にレンダ済みコンテンツを書く
    /// 2. PHContentEditingOutput.adjustmentData に編集レシピを設定
    static func saveEdit(
        asset:         PHAsset,
        recipe:        EditRecipe,
        renderedImage: CGImage,
        exportFormat:  ExportFormat = .heif
    ) async throws {
        // PHAsset の ContentEditingInput を取得
        let input = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PHContentEditingInput, Error>) in
            asset.requestContentEditingInput(with: nil) { input, _ in
                if let input = input {
                    continuation.resume(returning: input)
                } else {
                    continuation.resume(throwing: PhotoKitAdapterError.contentEditingInputFailed)
                }
            }
        }

        // 変更を Photos ライブラリに書き込む
        try await PHPhotoLibrary.shared().performChanges {
            let output = PHContentEditingOutput(contentEditingInput: input)

            // レンダ済み画像を書き出し
            // renderedContentURL は iOS 17+ では non-optional URL
            let outputURL = output.renderedContentURL
            let pool      = CIContextPool.shared
            let ciImage   = CIImage(cgImage: renderedImage)

            do {
                switch exportFormat {
                case .heif:
                    try pool.ciContext.writeHEIFRepresentation(
                        of:         ciImage,
                        to:         outputURL,
                        format:     .RGBA8,
                        colorSpace: pool.outputColorSpace
                    )
                case .jpeg:
                    try pool.ciContext.writeJPEGRepresentation(
                        of:         ciImage,
                        to:         outputURL,
                        colorSpace: pool.outputColorSpace
                    )
                default:
                    try pool.ciContext.writeHEIFRepresentation(
                        of:         ciImage,
                        to:         outputURL,
                        format:     .RGBA8,
                        colorSpace: pool.outputColorSpace
                    )
                }
            } catch {
                print("[PhotoKitAdapter] レンダ済み画像の書き出し失敗: \(error)")
            }

            // 編集レシピを PHAdjustmentData として設定
            output.adjustmentData = try? adjustmentData(from: recipe)

            // 変更リクエスト
            let changeRequest = PHAssetChangeRequest(for: asset)
            changeRequest.contentEditingOutput = output
        }
    }

    // MARK: - 既存編集の読み込み（Resume Editing）

    /// PHAsset から既存の編集レシピを読み込む
    ///
    /// - Parameter asset: Photos のアセット
    /// - Returns: 自アプリの編集レシピ、または nil（他アプリ編集時）
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

    /// この PHAdjustmentData が自アプリで再編集可能か
    static func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool {
        adjustmentData.formatIdentifier == formatIdentifier
    }
}

// MARK: - エラー定義

enum PhotoKitAdapterError: LocalizedError {
    case contentEditingInputFailed

    var errorDescription: String? {
        switch self {
        case .contentEditingInputFailed:
            return "ContentEditingInput の取得に失敗しました"
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
