//
//  PostKFImageTests.swift
//  SoramoyouTests
//
//  投稿の画像を読む KFImage を作る部品（KFImage.post）のテスト ⭐️（URL 側の C・C-1 の 4）
//
//  - 期待する値（鍵・パス・URL・識別子）はここに直接書く（入力から作った値どうしを比べると、何もしない実装でも緑になるため）
//  - KFImage は読み先を外から見せない（Kingfisher の Context.source は internal）。
//    → 読み先は `PostImageSource.kingfisherSource` で、キャッシュと加工は `KFImage.post` の options で確かめる。
//    「KFImage.post が kingfisherSource を使っていること」そのものは、テストで押さえられない（コードを読んで確かめる）
//  - 実際に読み込めるか（Storage・ネットワーク）と画面の見た目は、ここでは確かめない（手の確認＝C-1 の 5）
//

import Kingfisher
@testable import Soramoyou
import XCTest

@MainActor
final class PostKFImageTests: XCTestCase {
    // MARK: - 部品

    /// 公開の本体のダウンロード URL（トークン付き）
    private let publicURL = URL(string: "https://firebasestorage.googleapis.com/v0/b/demo/o/posts%2Fu1%2Fpublic%2Fa.jpg?alt=media&token=t1")!

    /// 読み先が Storage のパスで読む提供元なら、そのパス（それ以外は nil）
    private func storagePath(of source: Source?) -> String? {
        guard case let .provider(provider)? = source else { return nil }
        return (provider as? PostStorageImageProvider)?.storagePath
    }

    // MARK: - 読み先（kingfisherSource）

    func testRemoteSourceIsTheSameAsKFImageWithURL() {
        // 見張り役：公開の画像は今までどおり URL で読む。鍵は URL の文字列そのもの（端末に入っている分がそのまま使える）
        let source = PostImageSource.remote(publicURL).kingfisherSource

        XCTAssertEqual(source?.cacheKey, "https://firebasestorage.googleapis.com/v0/b/demo/o/posts%2Fu1%2Fpublic%2Fa.jpg?alt=media&token=t1")
        XCTAssertEqual(source?.url?.absoluteString, "https://firebasestorage.googleapis.com/v0/b/demo/o/posts%2Fu1%2Fpublic%2Fa.jpg?alt=media&token=t1")
    }

    func testStorageSourceReadsByPathWithoutDownloadURL() {
        // フォロワー限定の本体・非公開のサムネイルは、Storage のパスで読む（鍵はパスそのもの）
        let body = PostImageSource.storage("posts/u1/followers/a.jpg").kingfisherSource
        XCTAssertEqual(body?.cacheKey, "posts/u1/followers/a.jpg")
        XCTAssertEqual(storagePath(of: body), "posts/u1/followers/a.jpg")

        let thumbnail = PostImageSource.storage("thumbnails/u1/private/a_thumb.jpg").kingfisherSource
        XCTAssertEqual(thumbnail?.cacheKey, "thumbnails/u1/private/a_thumb.jpg")
        XCTAssertEqual(storagePath(of: thumbnail), "thumbnails/u1/private/a_thumb.jpg")

        // URL を持たない（トークン付きの URL を使わない）。
        // ⚠️ 読み先が nil でも通るので、中身は上の 4 つで確かめている
        XCTAssertNil(body?.url)
    }

    func testUnavailableHasNoSource() {
        // 見張り役：読めないものは読みに行かない
        XCTAssertNil(PostImageSource.unavailable.kingfisherSource)
    }

    // MARK: - KFImage.post

    func testPostForStorageUsesDedicatedCacheWithoutProcessor() {
        let image = KFImage.post(.storage("posts/u1/followers/a.jpg"))
        let targetCache = image?.options.targetCache
        let processorIdentifier = image?.options.processor.identifier

        // 専用のキャッシュに入れる（付け忘れると標準のキャッシュに入り、サインアウトで消えない。画面では見分けがつかない）
        XCTAssertIdentical(targetCache, PostStorageImageCache.shared, "専用のキャッシュが付いていない")
        // 加工を付けない（付けると鍵が「パス@加工の識別子」になる）。何もしない加工の識別子は空の文字列
        XCTAssertEqual(processorIdentifier, "")
    }

    func testPostForRemoteKeepsDefaultCache() {
        // 見張り役：公開の画像は今までどおり標準のキャッシュ。
        // targetCache が nil なら Kingfisher は ImageCache.default を使う（アプリは Kingfisher の既定の設定を変えていない）
        let image = KFImage.post(.remote(publicURL))
        let isMade = image != nil
        let targetCache = image?.options.targetCache
        let processorIdentifier = image?.options.processor.identifier

        XCTAssertTrue(isMade)
        XCTAssertNil(targetCache)
        XCTAssertEqual(processorIdentifier, "")
    }

    func testPostForUnavailableIsNil() {
        // 見張り役：読めないときは作らない（画面側が今の「読めない」ときの表示を出す）
        let isMade = KFImage.post(.unavailable) != nil
        XCTAssertFalse(isMade)
    }
}
