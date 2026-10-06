//
//  SoratomoPhotoPicker.swift
//  Soramoyou
//
//  そらともの投稿で、写真ライブラリから写真を 1 枚だけ選ぶ画面 ⭐️
//  （tasks 13.7・design.md の SoratomoPhotoPicker・要件 6.1・7.5）
//
//  ⚠️ 既存の `ImagePicker`（ImagePickerService.swift）とは別に作る。理由は次の 2 つ。
//     1. `PHPickerConfiguration()`（写真ライブラリを渡さない形）にして、ライブラリへのアクセス権を要らなくする。
//        既存の `ImagePicker` は `PHPickerConfiguration(photoLibrary: .shared())` で、PHAsset を引くために権限を使う。
//     2. `UIImage` ではなく、元のバイト列（Data）を返す。送信用の変換（`SoratomoImageEncoder`）は
//        元のバイト列から作る（UIImage を経由すると向きや色の扱いが変わる）。
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 写真ライブラリから写真を 1 枚だけ選び、元のバイト列を返す
///
/// - 選んだら `onPicked(data)` をメインアクターで呼ぶ。バイト列を取り出せなかったら `onPicked(nil)`
///   （呼び出し側が「この写真は使えません」を出す・要件 7.5）
/// - 選ばずに閉じたら `onCancel()` を呼ぶ
/// - 画面を閉じるのは呼び出し側（シートの表示の状態を false にする）
struct SoratomoPhotoPicker: UIViewControllerRepresentable {
    /// 選んだ写真の元のバイト列を受け取る（取り出せなければ nil）
    let onPicked: @MainActor (Data?) -> Void
    /// 選ばずに閉じたときに呼ぶ
    let onCancel: @MainActor () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // 写真ライブラリを渡さない形。選んだ写真だけがアプリに渡り、ライブラリへのアクセス権は要らない
        var configuration = PHPickerConfiguration()
        // 写真だけ（動画は選べない）
        configuration.filter = .images
        // 1 枚だけ（要件 6.1）
        configuration.selectionLimit = 1
        // 保存されている形のまま受け取る（`.automatic` だと HEIC が JPEG などに変換されることがあり、元のバイト列でなくなる）
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: PHPickerViewController, context _: Context) {
        // 更新するものは無い
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onCancel: onCancel)
    }

    // MARK: - Coordinator

    /// PHPicker の結果を受け取り、元のバイト列を取り出す
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        /// 選んだ写真の元のバイト列を受け取る
        private let onPicked: @MainActor (Data?) -> Void
        /// 選ばずに閉じたときに呼ぶ
        private let onCancel: @MainActor () -> Void

        init(onPicked: @escaping @MainActor (Data?) -> Void, onCancel: @escaping @MainActor () -> Void) {
            self.onPicked = onPicked
            self.onCancel = onCancel
        }

        func picker(_: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // 選ばずに閉じた（キャンセル）
            guard let provider = results.first?.itemProvider else {
                let onCancel = onCancel
                Task { @MainActor in onCancel() }
                return
            }

            let onPicked = onPicked
            Task {
                let data = await Self.loadOriginalData(from: provider)
                await MainActor.run {
                    onPicked(data)
                }
            }
        }

        /// 選んだ写真の元のバイト列を取り出す
        ///
        /// `loadDataRepresentation` はバイト列そのものを渡すので、`loadFileRepresentation` の
        /// 一時ファイル（completion を抜けると消える）の寿命を気にしなくてよい。
        /// - Returns: 画像でない・取り出せなかったときは nil
        private static func loadOriginalData(from provider: NSItemProvider) async -> Data? {
            let typeIdentifier = UTType.image.identifier
            guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
                return nil
            }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    // 失敗の理由（error）は使わない。呼び出し側は「使えない写真」とだけ伝える
                    continuation.resume(returning: data)
                }
            }
        }
    }
}
