//
//  PostStorageImageProviderTests.swift
//  SoramoyouTests
//
//  公開以外の投稿の画像の取得（PostStorageImageProvider）と、専用のキャッシュのテスト ⭐️（URL 側の C・C-1 の 3）
//
//  - 鍵・上限は、期待する値をここに直接書く（入力から作った値どうしを比べると、何もしない実装でも緑になるため）
//  - キャッシュを消すテストは一時フォルダの下にキャッシュを作り、終わったらフォルダごと消す（端末の本物のキャッシュに触れない）
//  - ディスクへの書き込みは `diskStorage.store`（同期）で行い、確かめはファイルの数で見る
//  - 取得そのもの（getData）と失敗の渡し方は Storage が要るので、ここでは確かめない（手の確認＝C-1 の 5）
//  - サインアウトの配線（ContentView）は単体テストで押さえられない（grep と手の確認）
//

import Kingfisher
@testable import Soramoyou
import UIKit
import XCTest

final class PostStorageImageProviderTests: XCTestCase {
    private var rootDirectory: URL!
    private var cache: ImageCache!

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostStorageImageProviderTests-\(UUID().uuidString)", isDirectory: true)
        cache = try ImageCache(name: "postStorageTest", cacheDirectoryURL: rootDirectory)
    }

    override func tearDownWithError() throws {
        cache = nil
        try? FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: - 部品

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// フォルダの中のファイルの数（フォルダが無ければ nil）
    private func fileCount(in directory: URL) -> Int? {
        try? FileManager.default.contentsOfDirectory(atPath: directory.path).count
    }

    // MARK: - 取得の鍵と上限

    func testCacheKeyIsStoragePathItself() {
        // 本体・サムネイル・原画像のパス（storage.rules の posts・thumbnails・originals の形）
        XCTAssertEqual(PostStorageImageProvider(storagePath: "posts/u1/followers/a.jpg").cacheKey, "posts/u1/followers/a.jpg")
        XCTAssertEqual(PostStorageImageProvider(storagePath: "thumbnails/u1/followers/a_thumb.jpg").cacheKey, "thumbnails/u1/followers/a_thumb.jpg")
        XCTAssertEqual(PostStorageImageProvider(storagePath: "originals/u1/private/o.jpg").cacheKey, "originals/u1/private/o.jpg")
    }

    func testMaxDataBytesIsFiveMebibytes() {
        // 本体・原画像はアップロードのときに 5 MiB までに抑え（StorageService.uploadImage）、
        // Storage のルールも 5 MiB 未満しか書かせない（storage.rules の isValidSize）
        XCTAssertEqual(PostStorageImageProvider.maxDataBytes, 5_242_880)
    }

    func testProviderHasNoDownloadURL() {
        // ダウンロード URL を持たない（トークン付きの URL を作らない・保存しない）
        XCTAssertNil(PostStorageImageProvider(storagePath: "posts/u1/private/a.jpg").contentURL)
    }

    // MARK: - キャッシュ

    func testClearEmptiesMemoryAndDisk() throws {
        let key = "posts/u1/followers/a.jpg"
        cache.store(makeImage(), forKey: key, toDisk: false)
        try cache.diskStorage.store(value: Data([0x01, 0x02, 0x03]), forKey: key)
        // 陽性対照: 消す前はメモリとディスクの両方に入っている
        XCTAssertTrue(cache.memoryStorage.isCached(forKey: key))
        XCTAssertEqual(fileCount(in: cache.diskStorage.directoryURL), 1)

        let done = expectation(description: "ディスクを消し終える")
        PostStorageImageCacheStore(cache: cache).clear { done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertFalse(cache.memoryStorage.isCached(forKey: key), "メモリが残っている")
        XCTAssertEqual(fileCount(in: cache.diskStorage.directoryURL) ?? 0, 0, "ディスクが残っている")
    }

    func testStaticClearEmptiesSharedButNotTheDefaultCache() {
        let key = "posts/test-\(UUID().uuidString)/followers/a.jpg"
        let defaultKey = "post-storage-test-default-\(UUID().uuidString)"
        // メモリだけに入れる（ディスクの削除は裏で行われるため、結果をすぐ確かめられるように）
        PostStorageImageCache.shared.store(makeImage(), forKey: key, toDisk: false)
        ImageCache.default.store(makeImage(), forKey: defaultKey, toDisk: false)
        // 陽性対照: 消す前は両方入っている
        XCTAssertTrue(PostStorageImageCache.shared.isCached(forKey: key))
        XCTAssertTrue(ImageCache.default.isCached(forKey: defaultKey))

        PostStorageImageCache.clear()

        XCTAssertFalse(PostStorageImageCache.shared.isCached(forKey: key), "公開以外の画像が消えていない")
        XCTAssertTrue(ImageCache.default.isCached(forKey: defaultKey), "標準のキャッシュまで消えた")

        ImageCache.default.removeImage(forKey: defaultKey)
    }

    func testSharedCacheIsSeparateFromDefaultAndSoratomo() {
        let shared = PostStorageImageCache.shared
        XCTAssertFalse(shared === ImageCache.default)
        XCTAssertFalse(shared === SoratomoImageCache.shared)
        // 名前が同じだと同じフォルダを使う（片方を消すと、もう片方のディスクも消える）→ フォルダも別であること
        let sharedPath = shared.diskStorage.directoryURL.standardizedFileURL.path
        XCTAssertNotEqual(sharedPath, ImageCache.default.diskStorage.directoryURL.standardizedFileURL.path)
        XCTAssertNotEqual(sharedPath, SoratomoImageCache.shared.diskStorage.directoryURL.standardizedFileURL.path)
    }

    func testSharedCacheKeepsKingfisherDefaultMemoryLimit() {
        // 持ち主ごとに分けないので、1 つのキャッシュの既定（物理メモリの 1/4）のまま（10/21 の決定）
        XCTAssertEqual(PostStorageImageCache.shared.memoryStorage.config.totalCostLimit, Int(ProcessInfo.processInfo.physicalMemory / 4))
    }
}
