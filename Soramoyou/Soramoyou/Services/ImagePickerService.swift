//
//  ImagePickerService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import PhotosUI
import Photos
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.soramoyou.photo-editor",
    category: "ImagePickerService"
)

/// PHPickerViewControllerをSwiftUIで使用するためのUIViewControllerRepresentable
///
/// `pickedMetadata` には選択された各画像に対応する PHAsset 由来の外部編集情報を
/// 同じ index で格納する（写真Appで編集済みバッジ表示用）。⭐️ Issue #4
/// Photos ライブラリへのアクセス権限が無い場合や、PHAsset を解決できない場合は
/// 各要素は nil となる。
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var selectedImages: [UIImage]
    @Binding var pickedMetadata: [ExternalEditInfo?]
    let maxSelectionCount: Int
    let onSelectionComplete: (() -> Void)?

    /// メタデータのバインディングを必要としない呼び出し（プロフィール画像選択など）も
    /// 互換に保つためデフォルトの `.constant([])` を提供する。
    init(
        selectedImages: Binding<[UIImage]>,
        pickedMetadata: Binding<[ExternalEditInfo?]> = .constant([]),
        maxSelectionCount: Int,
        onSelectionComplete: (() -> Void)? = nil
    ) {
        self._selectedImages = selectedImages
        self._pickedMetadata = pickedMetadata
        self.maxSelectionCount = maxSelectionCount
        self.onSelectionComplete = onSelectionComplete
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // PHPhotoLibrary.shared() を渡すことで `result.assetIdentifier` が取得できる。
        // これがないと PHAsset を解決できず、写真Appで編集済みバッジが表示できない。
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = maxSelectionCount
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // 更新は不要
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                return
            }

            // 選択された画像とメタ情報を順序を保って非同期に読み込む
            Task {
                var loadedImages: [UIImage] = []
                var loadedMetadata: [ExternalEditInfo?] = []

                for result in results {
                    guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else {
                        continue
                    }
                    do {
                        let image = try await self.loadImage(from: result.itemProvider)
                        loadedImages.append(image)

                        // PHAsset から外部編集情報を抽出（権限なし or 解決失敗で nil）
                        let meta = self.resolveExternalEditInfo(from: result.assetIdentifier)
                        loadedMetadata.append(meta)
                    } catch {
                        logger.error("画像の読み込みに失敗しました: \(error.localizedDescription)")
                    }
                }

                await MainActor.run {
                    self.parent.selectedImages = loadedImages
                    self.parent.pickedMetadata  = loadedMetadata
                    self.parent.onSelectionComplete?()
                }
            }
        }

        private func loadImage(from provider: NSItemProvider) async throws -> UIImage {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let image = object as? UIImage {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: PhotoSelectionError.validationFailed)
                    }
                }
            }
        }

        /// PHPickerResult.assetIdentifier から PHAsset を解決し、外部編集情報を抽出する。
        /// 権限なし・解決失敗時は nil を返す（バッジを出さないだけで、画像自体は使える）。
        private func resolveExternalEditInfo(from identifier: String?) -> ExternalEditInfo? {
            guard let identifier = identifier, !identifier.isEmpty else {
                return nil
            }

            // 権限ステータス確認（読み取り権限がなければ PHAsset.fetchAssets はからの結果になる）
            let status: PHAuthorizationStatus
            if #available(iOS 14, *) {
                status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            } else {
                status = PHPhotoLibrary.authorizationStatus()
            }
            switch status {
            case .authorized, .limited:
                break
            default:
                logger.debug("写真ライブラリ権限なし。外部編集情報の取得をスキップします")
                return nil
            }

            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard let asset = fetched.firstObject else {
                return nil
            }

            // mediaSubtypes でフラグ判定（photoEdited が編集済みフラグ）
            let subtypes = asset.mediaSubtypes
            let hasAdjustments = subtypes.contains(.photoHDR)
                || subtypes.contains(.photoPanorama)
                || asset.value(forKey: "hasAdjustments") as? Bool == true
                || subtypes.rawValue & UInt(1 << 4) != 0  // photoEdited (mediaSubtypes raw bit)

            // formatIdentifier は PHAdjustmentData の取得が必要（非同期）。
            // ここでは同期的に取れる範囲のみ使い、formatIdentifier は別途取得する。
            // 同期取得を試みる：requestContentEditingInput は非同期だが、ここでは
            // 簡略化のため formatIdentifier を nil にしておく（後続で改善余地あり）。
            let formatIdentifier: String? = nil

            return ExternalEditInfo(
                hasAdjustments: hasAdjustments,
                formatIdentifier: formatIdentifier,
                isHDR: subtypes.contains(.photoHDR),
                isLivePhoto: subtypes.contains(.photoLive),
                isPanorama: subtypes.contains(.photoPanorama),
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate
            )
        }
    }
}

/// 写真選択の状態を管理するViewModel
@MainActor
class PhotoSelectionViewModel: ObservableObject {
    @Published var selectedImages: [UIImage] = []
    /// 選択された各画像に対応する外部編集情報（写真Appバッジ表示用）⭐️ Issue #4
    @Published var pickedMetadata: [ExternalEditInfo?] = []
    @Published var isShowingImagePicker = false
    @Published var errorMessage: String?
    @Published var isLoading = false
    
    var maxSelectionCount: Int {
        didSet {
            // 最大選択数を超えている場合は、超過分を削除
            if selectedImages.count > maxSelectionCount {
                selectedImages = Array(selectedImages.prefix(maxSelectionCount))
            }
        }
    }
    
    private let imageService: ImageServiceProtocol
    
    init(
        maxSelectionCount: Int = 10,
        imageService: ImageServiceProtocol = ImageService()
    ) {
        self.maxSelectionCount = maxSelectionCount
        self.imageService = imageService
    }
    
    /// 最大選択数を更新
    func updateMaxSelectionCount(_ count: Int) {
        maxSelectionCount = count
    }
    
    /// 写真選択を開始
    func startPhotoSelection() {
        errorMessage = nil
        isShowingImagePicker = true
    }
    
    /// 選択された画像を検証
    func validateSelectedImages() async throws {
        guard !selectedImages.isEmpty else {
            throw PhotoSelectionError.noImagesSelected
        }
        
        guard selectedImages.count <= maxSelectionCount else {
            throw PhotoSelectionError.tooManyImages(maxCount: maxSelectionCount)
        }
        
        // 各画像のサイズとファイルサイズを検証
        for (index, image) in selectedImages.enumerated() {
            // 解像度の検証（最大2048x2048）
            let maxSize: CGFloat = 2048
            if image.size.width > maxSize || image.size.height > maxSize {
                // リサイズが必要
                let resizedImage = try await imageService.resizeImage(
                    image,
                    maxSize: CGSize(width: maxSize, height: maxSize)
                )
                selectedImages[index] = resizedImage
            }
            
            // ファイルサイズの検証（最大5MB）
            if let imageData = image.jpegData(compressionQuality: 1.0),
               imageData.count > 5 * 1024 * 1024 {
                // 圧縮が必要
                let compressedData = try await imageService.compressImage(image, quality: 0.85)
                if let compressedImage = UIImage(data: compressedData) {
                    selectedImages[index] = compressedImage
                } else {
                    throw PhotoSelectionError.imageTooLarge(index: index + 1)
                }
            }
        }
    }
    
    /// 選択された画像をクリア
    func clearSelection() {
        selectedImages.removeAll()
        pickedMetadata.removeAll()  // ⭐️ Issue #4: メタも同期してクリア
        errorMessage = nil
    }

    /// 画像を削除
    func removeImage(at index: Int) {
        guard index < selectedImages.count else { return }
        selectedImages.remove(at: index)
        // メタも同じ index で除去（既に範囲内ならば）
        if pickedMetadata.indices.contains(index) {
            pickedMetadata.remove(at: index)
        }
    }
}

// MARK: - PhotoSelectionError

enum PhotoSelectionError: LocalizedError {
    case noImagesSelected
    case tooManyImages(maxCount: Int)
    case imageTooLarge(index: Int)
    case validationFailed
    
    var errorDescription: String? {
        switch self {
        case .noImagesSelected:
            return "画像が選択されていません"
        case .tooManyImages(let maxCount):
            return "選択できる画像は最大\(maxCount)枚までです"
        case .imageTooLarge(let index):
            return "\(index)枚目の画像のサイズが大きすぎます"
        case .validationFailed:
            return "画像の検証に失敗しました"
        }
    }
}
