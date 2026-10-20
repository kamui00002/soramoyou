//
//  PostStorageImageProvider.swift
//  Soramoyou
//
//  公開以外（フォロワー限定・非公開）の投稿の画像の取得と、その専用の画像キャッシュ ⭐️（URL 側の C・C-1）
//
//  ⚠️ ダウンロード URL を使わない。取得は `StorageReference.getData` だけで行う。
//     これは毎回 Storage のルール（本人かフォロワーか）を通るので、フォローを外された人・ブロックされた人は、
//     その後は新しく読めない（トークン付きの URL は、知っている人なら誰でも見られてしまう）。
//  URL で読むかパスで読むかの判定は `PostImageSource.resolve`。ここは `.storage(パス)` のときだけ使う。
//

import FirebaseStorage
import Foundation
import Kingfisher

// MARK: - 取得

/// 公開以外の投稿の画像を、Storage から取得して Kingfisher に渡す提供元
///
/// 使い方（画面側 = C-1 の 4）:
/// ```swift
/// KFImage(source: .provider(PostStorageImageProvider(storagePath: path)))
///     // ⚠️ 必ず付ける（付けないと標準のキャッシュに入り、サインアウトで消えない）
///     .targetCache(PostStorageImageCache.shared)
/// ```
/// - `storagePath` には、`PostImageSource.resolve` が返した `.storage(パス)` のパスをそのまま渡す（自分で組み立てない）。
/// - キャッシュの鍵は `storagePath` そのもの。キャッシュにあれば、Storage には問い合わせない。
/// - 取得に失敗したときは、Storage のエラーをそのまま `handler` に渡す（記録しない）。
///   フォローを外された後の権限の拒否は、正しい動き（ルールが断っている）。
///   Kingfisher は、これを `KingfisherError` に包んで画面側に返す。
struct PostStorageImageProvider: ImageDataProvider {
    /// 1 枚あたりの、取得できる最大のバイト数（5 MiB）
    ///
    /// 本体・原画像はアップロードのときに 5 MiB までに抑え（`StorageService.uploadImage`）、
    /// Storage のルールも 5 MiB 未満しか書かせない（storage.rules の `isValidSize`）。
    /// そらともの上限（2,000,000 バイト）は写さない（投稿の本体はそれより大きいことがある）。
    static let maxDataBytes: Int64 = 5 * 1024 * 1024

    /// 取得する画像の Storage のパス（`posts/…`・`thumbnails/…`・`originals/…`）
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
                // 権限の拒否・通信の失敗・大きすぎるなどを、Storage のエラーのまま返す。
                // データもエラーも無いことは無いはずだが、そのときは Foundation の既存のエラーで返す（新しい失敗の種類を作らない）
                handler(.failure(error ?? URLError(.unknown)))
            }
        }
    }
}

// MARK: - キャッシュ

/// 公開以外の投稿の画像のキャッシュ（アプリで使う口）
///
/// 既存の画面が使う Kingfisher の標準のキャッシュ（公開の画像が URL で入る）とも、そらとものキャッシュとも分ける。
/// 分けるのは、サインアウトのときに、この画像だけを消すため（別のアカウントに、前のアカウントが読めた画像を見せない）。
/// 持ち主ごとには分けない。フォローを外された後も、端末に入った分はサインアウトまで残る（10/21 の決定）。
/// メモリの上限は Kingfisher の既定（物理メモリの 1/4）のまま。
/// 中身は `PostStorageImageCacheStore`（テストでは一時フォルダの `ImageCache` を渡す）。ここは本番用の 1 つへ流すだけ。
///
/// ⚠️ 画面側は、必ず `.targetCache(PostStorageImageCache.shared)` を付けて読み込む。
///    付け忘れると標準のキャッシュに入り、`clear()` で消えない。
/// ⚠️ 画面側は、画像に processor（ダウンサンプリングなど）を付けない。付けると鍵が
///    `パス@processor の識別子` になる。
enum PostStorageImageCache {
    /// 本番用のキャッシュ（名前 `postStorage`。置き場は `Caches/com.onevcat.Kingfisher.ImageCache.postStorage`）
    ///
    /// 名前を標準（`default`）・そらとも（`soratomo`）と変えるのは、同じ名前だと同じフォルダを使い、
    /// 片方を消すともう片方のディスクも消えるため。
    static let shared = ImageCache(name: "postStorage")

    /// 本番用の中身
    private static let live = PostStorageImageCacheStore(cache: shared)

    /// このキャッシュを消す（メモリとディスク）
    ///
    /// サインアウトで呼ぶ（呼び出しの配線は C-1 の 3 の後半）。ディスクの削除は裏で行われ、完了を待たない。
    static func clear() {
        live.clear()
    }
}

/// 公開以外の投稿の画像のキャッシュの中身（`PostStorageImageCache` の中身）
///
/// `ImageCache` を外から受け取る（本番は `PostStorageImageCache.shared`・テストは一時フォルダのもの）。
final class PostStorageImageCacheStore {
    /// 消す対象のキャッシュ
    let cache: ImageCache

    /// - Parameter cache: 消す対象のキャッシュ
    init(cache: ImageCache) {
        self.cache = cache
    }

    /// キャッシュを消す（メモリとディスク）
    ///
    /// メモリはすぐに空になり、ディスクの削除は裏で行われる。
    /// - Parameter completion: ディスクを消し終えたときにメインで呼ぶ（テスト用）
    func clear(completion: (@Sendable () -> Void)? = nil) {
        cache.clearCache(completion: completion)
    }
}
