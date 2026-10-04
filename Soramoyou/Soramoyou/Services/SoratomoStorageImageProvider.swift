//
//  SoratomoStorageImageProvider.swift
//  Soramoyou
//
//  そらともの画像の取得（メンバー判定を経る）と、そらとも専用の画像キャッシュ ⭐️
//  （tasks 11.4・design.md の SoratomoStorageImageProvider・SoratomoImageCache・
//   要件 8.14・11.13・12.1・12.4）
//
//  ⚠️ ダウンロード URL を作らず、保存しない（要件 8.14・11.13）。
//     トークン付きの URL は、知っている人なら誰でも見られてしまう。
//     取得は `StorageReference.getData` だけで行う。これは毎回 Storage のルール
//     （グループのメンバーか）を通るので、グループを抜けた人・外された人は、その後は見られない。
//

import FirebaseStorage
import Foundation
import Kingfisher

// MARK: - 取得

/// そらともの画像を、Storage から取得して Kingfisher に渡す提供元
///
/// 使い方（画面側 = tasks 13.x）:
/// ```swift
/// KFImage(source: .provider(SoratomoStorageImageProvider(storagePath: sky.imagePaths.thumbnail)))
///     .targetCache(SoratomoImageCache.shared)   // ⚠️ 必ず付ける（付けないと、サインアウトで消えない）
/// ```
/// - `storagePath` には、`SoratomoImagePaths` の `display` か `thumbnail` をそのまま渡す（自分で組み立てない）。
/// - キャッシュの鍵は `storagePath` そのもの。キャッシュにあれば、Storage には問い合わせない。
/// - 取得に失敗したときは、`SoratomoError`（`SoratomoImageStoreErrorMapping`）を `handler` に渡す。
///   Kingfisher は、これを `KingfisherError` に包んで画面側に返す。
struct SoratomoStorageImageProvider: ImageDataProvider {
    /// 1 枚あたりの、取得できる最大のバイト数
    ///
    /// 表示用の上限（1,572,864 バイト）より大きく、これを超える画像は取得しない。
    static let maxDataBytes: Int64 = 2_000_000

    /// 取得する画像の Storage のパス（`SoratomoImagePaths` の `display` か `thumbnail`）
    let storagePath: String

    /// キャッシュの鍵（Storage のパスそのもの）
    var cacheKey: String {
        storagePath
    }

    /// 画像のデータを取得する
    ///
    /// - Note: `contentURL` は実装しない（既定の nil のまま）。ダウンロード URL を持たないため。
    func data(handler: @escaping @Sendable (Result<Data, any Error>) -> Void) {
        Storage.storage().reference().child(storagePath).getData(maxSize: Self.maxDataBytes) { data, error in
            if let data, error == nil {
                handler(.success(data))
            } else {
                // 権限の拒否・通信の失敗などを、そらともの失敗の種類に写して返す
                handler(.failure(SoratomoImageStoreErrorMapping.map(error ?? SoratomoError.unknown, operation: .download)))
            }
        }
    }
}

// MARK: - キャッシュ

/// そらとも専用の画像キャッシュ
///
/// 既存の画面が使う Kingfisher の標準のキャッシュとは分ける（名前 `soratomo`）。
/// 分けるのは、サインアウトのときに、そらともの画像だけを（既存の画像に触らずに）消すため。
/// 鍵は Storage のパス（`SoratomoStorageImageProvider.cacheKey`）。
///
/// ⚠️ 画面側は、必ず `.targetCache(SoratomoImageCache.shared)` を付けて読み込む。
///    付け忘れると標準のキャッシュに入り、`clear()` でも `remove(_:)` でも消えない。
/// ⚠️ 画面側は、画像に processor（ダウンサンプリングなど）を付けない。付けると鍵が
///    `パス@processor の識別子` になり、`remove(_:)` が消す鍵と一致しなくなる。
enum SoratomoImageCache {
    /// そらとも専用のキャッシュ
    static let shared = ImageCache(name: "soratomo")

    /// そらとものキャッシュを、すべて消す（メモリとディスク）
    ///
    /// サインアウトで呼ぶ（呼び出しの配線は tasks 14.1）。別のアカウントに、前のアカウントの画像を見せないため。
    /// ディスクの削除は裏で行われ、完了を待たない。
    static func clear() {
        shared.clearCache()
    }

    /// 投稿の 2 枚（表示用・サムネイル）の鍵を、キャッシュから消す
    ///
    /// 投稿を削除したときに呼ぶ（削除した画像が、端末に残らないように）。
    /// - Parameter paths: 消す投稿の画像の置き場所
    static func remove(_ paths: SoratomoImagePaths) {
        shared.removeImage(forKey: paths.display)
        shared.removeImage(forKey: paths.thumbnail)
    }
}
