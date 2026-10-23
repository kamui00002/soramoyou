//
//  PostKFImage.swift
//  Soramoyou
//
//  投稿の画像を読む KFImage を、読み方（PostImageSource）から作る部品 ⭐️（URL 側の C・C-1 の 4）
//
//  画面ごとに「URL で読むか・Storage のパスで読むか」を書かないように、ここで 1 か所にまとめる。
//  包む View にしないのは、`.placeholder`・`.resizable()` などが KFImage のメソッドで、
//  包むと各画面が今付けている修飾子をそのまま残せないため。
//

import Kingfisher
import SwiftUI

extension KFImage {
    /// 投稿の画像を読む KFImage を作る
    ///
    /// 使い方（画面側）:
    /// ```swift
    /// if let image = KFImage.post(PostImageSource.resolve(imageInfo, prefersThumbnail: true)) {
    ///     image
    ///         .placeholder { ProgressView() }  // 修飾子は今の画面のまま
    ///         .resizable()
    /// } else {
    ///     // 読めない（今の画面の「読めない」ときの表示のまま）
    /// }
    /// ```
    /// - `.remote(URL)`：`KFImage(url)` と同じ（標準のキャッシュ・鍵は URL の文字列＝今までと変わらない）
    /// - `.storage(パス)`：Storage から取得し、公開以外の専用のキャッシュに入れる（サインアウトで消える）
    /// - `.unavailable`：nil（画面側が今の「読めない」ときの表示を出す）
    /// - Parameter source: `PostImageSource.resolve` が返した読み方
    /// - Returns: 読み込む KFImage（読めないときは nil）
    @MainActor
    static func post(_ source: PostImageSource) -> KFImage? {
        guard let kingfisherSource = source.kingfisherSource else { return nil }
        let image = KFImage(source: kingfisherSource)
        switch source {
        case .storage:
            // 必ず専用のキャッシュに入れる（付け忘れると標準のキャッシュに入り、サインアウトで消えない。画面では見分けがつかない）
            // ⚠️ 同じ決まりが `ImageDownloadService.storageRequest`（保存・共有・再編集）にもある。片方を変えるときは両方を直す
            return image.targetCache(PostStorageImageCache.shared)
        case .remote, .unavailable:
            // 標準のキャッシュのまま（今までと同じ置き場・同じ鍵）
            return image
        }
    }
}

extension PostImageSource {
    /// Kingfisher に渡す読み先（読めないときは nil）
    ///
    /// `KFImage.post` の中で使う。KFImage は読み先を外から見せない（Kingfisher の `Context.source` は internal）ので、
    /// 読み先の中身はこの値でテストする。
    var kingfisherSource: Source? {
        switch self {
        case let .remote(url):
            // KFImage(url) の中身と同じ作り方（Kingfisher の KFImageProtocol の init(_ url:)）＝鍵は URL の文字列のまま
            url.convertToSource()
        case let .storage(path):
            // URL を使わず、Storage のパスで読む（毎回 Storage のルールを通る）
            .provider(PostStorageImageProvider(storagePath: path))
        case .unavailable:
            nil
        }
    }
}
