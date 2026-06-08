// UIImage+NormalizedOrientation.swift
// Soramoyou
//
// imageOrientation を .up に正規化するユーティリティ。
//
// 背景:
//   CIContext.jpegRepresentation は CIImage の pixels だけを書き出し、
//   EXIF orientation タグを出力 JPEG に含めない。
//   UIImage.imageOrientation が .up 以外のまま CIImage 経由でエンコードすると、
//   ピクセルが横向きのまま Firebase Storage にアップロードされ、
//   Kingfisher 等のビューアで画像が回転して表示される。
//   → アップロード前にこのメソッドで orientation を焼き込む。

import UIKit
import ImageIO

extension UIImage {
    /// imageOrientation を .up に正規化した UIImage を返す。
    ///
    /// 内部で UIGraphicsImageRenderer を使って再描画するため、
    /// 返り値のピクセルは常に正しい向きになっており orientation == .up が保証される。
    /// すでに .up の場合はコピーせずそのまま返す。
    ///
    /// 防衛策 (壊れた UIImage 入力時のクラッシュ防止):
    /// - 既に .up なら無加工で返す
    /// - サイズが 0 / 非有限 / 異常に大きい場合はそのまま返す（再描画しない）
    /// - cgImage / ciImage どちらも参照不可な「中身のない」UIImage は再描画不可なのでそのまま返す
    /// - UIGraphicsImageRenderer の draw が失敗した場合のフォールバックとして自身を返す
    ///
    /// このガードがないと、iCloud 同期失敗中の写真や壊れた画像を選択した瞬間に
    /// `StorageService.encodeJPEG` 経由で投稿フローがクラッシュする可能性がある。
    func withNormalizedOrientation() -> UIImage {
        // 1. 既に正しい向き → 何もしない
        guard imageOrientation != .up else { return self }

        // 2. サイズの妥当性チェック
        let s = size
        guard s.width.isFinite, s.height.isFinite,
              s.width > 0, s.height > 0 else {
            // 空・非有限サイズの画像は再描画不可なので元を返す
            return self
        }

        // 3. UIGraphicsImageRenderer のメモリ確保で OOM になりかねない
        //    異常に大きなサイズはガード（縦横どちらかが 20,000 px 超なら諦める）
        //    通常の写真は最大でも 8,000px 程度なので 20,000 を上限に
        let maxDimension: CGFloat = 20_000
        guard s.width <= maxDimension, s.height <= maxDimension else {
            return self
        }

        // 4. backing store (cgImage または ciImage) の存在チェック
        //    どちらも nil の UIImage は draw() しても黒画面になるだけ
        guard cgImage != nil || ciImage != nil else {
            return self
        }

        // 5. 再描画
        let renderer = UIGraphicsImageRenderer(size: s)
        let result = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: s))
        }

        // 6. 結果のサニティチェック (renderer.image が壊れた画像を返した場合の保険)
        guard result.cgImage != nil else { return self }

        return result
    }
}

extension CGImagePropertyOrientation {
    /// `UIImage.Orientation` から対応する `CGImagePropertyOrientation` を生成する。
    ///
    /// CIImage 空間で orientation を適用する用途（`CIImage.oriented(_:)`）に使う。
    /// `withNormalizedOrientation()` は UIGraphicsImageRenderer 経由で sRGB 化されうるため、
    /// Display P3 を保ったまま向きだけ整えたい合成経路ではこちらを使う。
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
