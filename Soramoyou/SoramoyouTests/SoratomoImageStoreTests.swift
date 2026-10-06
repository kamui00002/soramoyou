//
//  SoratomoImageStoreTests.swift
//  SoramoyouTests
//
//  そらともの画像の保存・取得・キャッシュのうち、Storage に依存しない部分のテスト ⭐️（tasks 11.4）
//  - 2 枚を合わせた進み具合の計算（SoratomoImageStoreProgress）
//  - Storage のエラーの写し（SoratomoImageStoreErrorMapping）
//  - 取得の鍵（SoratomoStorageImageProvider.cacheKey）
//  - そらとも専用のキャッシュの全消去と、投稿の 2 つの鍵の削除（SoratomoImageCache）
//
//  Storage への実際のアップロード・削除・取得は、本番での通しの確認（tasks 15.1）で確かめる。
//
//  Storage のエラーは、FirebaseStorage を import せずに、SDK のソースから読んだ
//  ドメイン（FIRStorageErrorDomain）とコード（-13000 台）の数値で組み立てる。
//  SDK の定義と、このファイルの数値が食い違えば、写しのテストが落ちる。
//

import Kingfisher
@testable import Soramoyou
import UIKit
import XCTest

final class SoratomoImageStoreTests: XCTestCase {
    // MARK: - Storage のエラーの数値（FirebaseStorage の StorageErrorCode の値）

    private let storageDomain = "FIRStorageErrorDomain"
    private let codeUnknown = -13000
    private let codeObjectNotFound = -13010
    private let codeUnauthenticated = -13020
    private let codeUnauthorized = -13021
    private let codeRetryLimitExceeded = -13030
    private let codeNonMatchingChecksum = -13031
    private let codeCancelled = -13040

    private func storageError(_ code: Int, userInfo: [String: Any] = [:]) -> NSError {
        NSError(domain: storageDomain, code: code, userInfo: userInfo)
    }

    // MARK: - 2 枚を合わせた進み具合

    func testProgressCombinesBothImagesByBytes() {
        // 表示用 800 バイト・サムネイル 200 バイトの合計 1000 バイトで割る
        var progress = SoratomoImageStoreProgress(totals: [800, 200])
        XCTAssertEqual(progress.fraction, 0.0, accuracy: 0.0001)

        progress.update(index: 0, completedBytes: 400)
        XCTAssertEqual(progress.fraction, 0.4, accuracy: 0.0001)

        progress.update(index: 1, completedBytes: 200)
        XCTAssertEqual(progress.fraction, 0.6, accuracy: 0.0001)
    }

    func testProgressNeverGoesBackward() {
        // 再試行で小さい値が届いても、表示の進み具合を巻き戻さない
        var progress = SoratomoImageStoreProgress(totals: [800, 200])
        progress.update(index: 0, completedBytes: 400)
        progress.update(index: 0, completedBytes: 100)
        XCTAssertEqual(progress.fraction, 0.4, accuracy: 0.0001)
    }

    func testProgressClampsToTotalAndIgnoresInvalidInput() {
        var progress = SoratomoImageStoreProgress(totals: [800, 200])
        // 送るバイト数を超えた値は丸める（800 / 1000）
        progress.update(index: 0, completedBytes: 99999)
        XCTAssertEqual(progress.fraction, 0.8, accuracy: 0.0001)
        // 負の値・範囲外の何枚目かは、無視する
        progress.update(index: 1, completedBytes: -50)
        progress.update(index: 7, completedBytes: 100)
        XCTAssertEqual(progress.fraction, 0.8, accuracy: 0.0001)
    }

    func testProgressReachesOneOnlyWhenBothImagesAreFinished() {
        var progress = SoratomoImageStoreProgress(totals: [800, 200])
        progress.finish(index: 0)
        XCTAssertEqual(progress.fraction, 0.8, accuracy: 0.0001)
        progress.finish(index: 1)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 0.0001)
    }

    func testProgressWithEmptyTotalsIsOneOnlyAfterAllFinished() {
        // 分母が 0 のときは割れない。全部送り終えたときだけ 100% にする
        var progress = SoratomoImageStoreProgress(totals: [0, 0])
        XCTAssertEqual(progress.fraction, 0.0, accuracy: 0.0001)
        progress.finish(index: 0)
        XCTAssertEqual(progress.fraction, 0.0, accuracy: 0.0001)
        progress.finish(index: 1)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 0.0001)
    }

    // MARK: - Storage のエラーの写し

    func testUnauthorizedMapsByOperation() {
        // ルールに拒否された: 書き込みは「ルールに拒否された」、読み取りは「メンバーでない」
        let error = storageError(codeUnauthorized)
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(error, operation: .upload), .permissionDenied)
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(error, operation: .download), .notMember)
    }

    func testUnauthenticatedMapsToPermissionDeniedForBothOperations() {
        let error = storageError(codeUnauthenticated)
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(error, operation: .upload), .permissionDenied)
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(error, operation: .download), .permissionDenied)
    }

    func testRetryLimitExceededMapsToNetwork() {
        let error = storageError(codeRetryLimitExceeded)
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(error, operation: .upload), .network)
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(error, operation: .download), .network)
    }

    func testURLErrorMapsToNetworkExceptCancel() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(offline, operation: .upload), .network)
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(offline, operation: .download), .network)
        // 取り消しは通信の失敗ではない
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(cancelled, operation: .upload), .unknown)
    }

    func testStorageUnknownWrappingURLErrorMapsToNetwork() {
        // Storage は、圏外などの失敗を `unknown` に包んで返す（元のドメインとコードを userInfo に入れる）
        let byResponseKeys = storageError(codeUnknown, userInfo: [
            "ResponseErrorDomain": NSURLErrorDomain,
            "ResponseErrorCode": NSURLErrorNotConnectedToInternet,
        ])
        let byUnderlyingError = storageError(codeUnknown, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
        ])
        let wrappedCancel = storageError(codeUnknown, userInfo: [
            "ResponseErrorDomain": NSURLErrorDomain,
            "ResponseErrorCode": NSURLErrorCancelled,
        ])
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(byResponseKeys, operation: .upload), .network)
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(byUnderlyingError, operation: .download), .network)
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(wrappedCancel, operation: .upload), .unknown)
        // 包んでいるものが無い `unknown` は、`unknown` のまま
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(storageError(codeUnknown), operation: .upload), .unknown)
    }

    func testOtherStorageErrorsMapToUnknown() {
        for code in [codeCancelled, codeObjectNotFound, codeNonMatchingChecksum] {
            let error = storageError(code)
            XCTAssertEqual(SoratomoImageStoreErrorMapping.map(error, operation: .upload), .unknown, "code=\(code)")
            XCTAssertEqual(SoratomoImageStoreErrorMapping.map(error, operation: .download), .unknown, "code=\(code)")
        }
    }

    func testStorageCodesInOtherDomainsAreNotTreatedAsStorageErrors() {
        // コードの数値が同じでも、Storage のドメインでなければ、Storage の失敗として読まない
        let other = NSError(domain: "com.example.other", code: codeUnauthorized)
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(other, operation: .upload), .unknown)
    }

    func testSoratomoErrorPassesThrough() {
        XCTAssertEqual(SoratomoImageStoreErrorMapping.map(SoratomoError.notMember, operation: .upload), .notMember)
    }

    func testIsObjectNotFoundOnlyForStorageObjectNotFound() {
        XCTAssertTrue(SoratomoImageStoreErrorMapping.isObjectNotFound(storageError(codeObjectNotFound)))
        XCTAssertFalse(SoratomoImageStoreErrorMapping.isObjectNotFound(storageError(codeUnauthorized)))
        XCTAssertFalse(SoratomoImageStoreErrorMapping.isObjectNotFound(NSError(domain: "com.example.other", code: codeObjectNotFound)))
    }

    // MARK: - 取得の鍵

    func testProviderCacheKeyIsStoragePathItselfAndHasNoURL() {
        let paths = SoratomoImagePaths(groupId: "g1", authorId: "u1", skyId: "s1")
        let display = SoratomoStorageImageProvider(storagePath: paths.display)
        let thumbnail = SoratomoStorageImageProvider(storagePath: paths.thumbnail)
        XCTAssertEqual(display.cacheKey, paths.display)
        XCTAssertEqual(thumbnail.cacheKey, paths.thumbnail)
        XCTAssertNotEqual(display.cacheKey, thumbnail.cacheKey)
        // ダウンロード URL を持たない（要件 8.14・11.13）
        XCTAssertNil(display.contentURL)
        XCTAssertNil(thumbnail.contentURL)
    }

    // MARK: - キャッシュ

    /// キャッシュに入れる 1 ピクセルの画像
    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// 他のテストと鍵がぶつからない、一意の置き場所
    private func makePaths(skyId: String) -> SoratomoImagePaths {
        SoratomoImagePaths(groupId: "test-\(UUID().uuidString)", authorId: "u", skyId: skyId)
    }

    func testRemoveDropsBothKeysOfThePostAndKeepsOthers() {
        let paths = makePaths(skyId: "target")
        let other = makePaths(skyId: "other")
        let cache = SoratomoImageCache.shared
        // メモリだけに入れる（ディスクの削除は裏で行われるため、結果をすぐ確かめられるように）
        for key in [paths.display, paths.thumbnail, other.display] {
            cache.store(makeImage(), forKey: key, toDisk: false)
        }
        // 陽性対照: 消す前は 3 つとも入っている
        XCTAssertTrue(cache.isCached(forKey: paths.display))
        XCTAssertTrue(cache.isCached(forKey: paths.thumbnail))
        XCTAssertTrue(cache.isCached(forKey: other.display))

        SoratomoImageCache.remove(paths)

        XCTAssertFalse(cache.isCached(forKey: paths.display), "表示用の鍵が消えていない")
        XCTAssertFalse(cache.isCached(forKey: paths.thumbnail), "サムネイルの鍵が消えていない")
        XCTAssertTrue(cache.isCached(forKey: other.display), "別の投稿の鍵まで消えた")

        SoratomoImageCache.remove(other)
    }

    func testClearEmptiesSoratomoCacheButNotTheDefaultCache() {
        let paths = makePaths(skyId: "clear")
        let defaultKey = "soratomo-test-default-\(UUID().uuidString)"
        let soratomoCache = SoratomoImageCache.shared
        // そらとも専用であること（既存の画面が使う標準のキャッシュと別のもの）
        XCTAssertFalse(soratomoCache === ImageCache.default)

        soratomoCache.store(makeImage(), forKey: paths.display, toDisk: false)
        ImageCache.default.store(makeImage(), forKey: defaultKey, toDisk: false)
        // 陽性対照: 消す前は両方入っている
        XCTAssertTrue(soratomoCache.isCached(forKey: paths.display))
        XCTAssertTrue(ImageCache.default.isCached(forKey: defaultKey))

        SoratomoImageCache.clear()

        XCTAssertFalse(soratomoCache.isCached(forKey: paths.display), "そらともの画像が消えていない")
        XCTAssertTrue(ImageCache.default.isCached(forKey: defaultKey), "標準のキャッシュまで消えた")

        ImageCache.default.removeImage(forKey: defaultKey)
    }
}
