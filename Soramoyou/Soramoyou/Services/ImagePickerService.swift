//
//  ImagePickerService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import PhotosUI

/// PHPickerViewControllerをSwiftUIで使用するためのUIViewControllerRepresentable
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var selectedImages: [UIImage]
    let maxSelectionCount: Int
    let onSelectionComplete: (() -> Void)?
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
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
            
            // 選択された画像を非同期で読み込む
            Task {
                var loadedImages: [UIImage] = []
                
                for result in results {
                    if result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                        do {
                            let image = try await self.loadImage(from: result.itemProvider)
                            loadedImages.append(image)
                        } catch {
                            LoggingService.shared.log("画像の読み込みに失敗しました: \(error.localizedDescription)", level: .warning)
                        }
                    }
                }
                
                await MainActor.run {
                    self.parent.selectedImages = loadedImages
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
    }
}

/// 写真選択の状態を管理するViewModel
@MainActor
class PhotoSelectionViewModel: ObservableObject {
    @Published var selectedImages: [UIImage] = []
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
        errorMessage = nil
    }
    
    /// 画像を削除
    func removeImage(at index: Int) {
        guard index < selectedImages.count else { return }
        selectedImages.remove(at: index)
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
