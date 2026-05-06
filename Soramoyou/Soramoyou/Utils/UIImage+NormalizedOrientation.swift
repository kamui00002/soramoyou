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

extension UIImage {
    /// imageOrientation を .up に正規化した UIImage を返す。
    ///
    /// 内部で UIGraphicsImageRenderer を使って再描画するため、
    /// 返り値のピクセルは常に正しい向きになっており orientation == .up が保証される。
    /// すでに .up の場合はコピーせずそのまま返す。
    func withNormalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
