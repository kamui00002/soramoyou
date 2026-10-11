//
//  SoratomoImageCacheTests.swift
//  SoramoyouTests
//
//  そらともの画像のキャッシュをグループごとに分ける（SoratomoGroupImageCaches）のテスト ⭐️
//  （leave-group 7.3・要件 5.4・5.5・要確認 Q3 の前半）
//
//  - キャッシュは一時フォルダの下に作り、終わったらフォルダごと消す（端末の本物のキャッシュに触れない）
//  - 要確認 Q3: Kingfisher 8.6.2 の置き場（`親/com.onevcat.Kingfisher.ImageCache.<name>`）・メモリの上限の変更・
//    消去とフォルダの削除が、期待どおりかをここで確かめる。実機での確かめは 12.2
//  - ディスクへの書き込みは `diskStorage.store`（同期）で行い、確かめはファイルの有無で見る
//    （Kingfisher の非同期の書き込みと「あるかもしれない」の覚えに左右されないように）
//

import Kingfisher
@testable import Soramoyou
import UIKit
import XCTest

final class SoratomoImageCacheTests: XCTestCase {
    private var rootDirectory: URL!
    private var parentDirectory: URL!
    private var fallback: ImageCache!
    private var caches: SoratomoGroupImageCaches!
    private var defaultsSuiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoratomoImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        parentDirectory = rootDirectory.appendingPathComponent("soratomo-images", isDirectory: true)
        fallback = try ImageCache(name: "fallback", cacheDirectoryURL: rootDirectory)
        caches = SoratomoGroupImageCaches(parentDirectory: parentDirectory, fallback: fallback)
        defaultsSuiteName = "SoratomoImageCacheTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        caches = nil
        fallback = nil
        try? FileManager.default.removeItem(at: rootDirectory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
    }

    // MARK: - 部品

    private func path(_ groupId: String, _ skyId: String = "sky-1") -> String {
        SoratomoImagePaths(groupId: groupId, authorId: "author-1", skyId: skyId).display
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// メモリとディスクの両方に入れる（ディスクは同期で書く）
    private func storeInMemoryAndDisk(_ cache: ImageCache, key: String) throws {
        cache.store(makeImage(), forKey: key, toDisk: false)
        try cache.diskStorage.store(value: Data([0x01, 0x02, 0x03]), forKey: key)
    }

    /// フォルダの中のファイルの数（フォルダが無ければ nil）
    private func fileCount(in directory: URL) -> Int? {
        try? FileManager.default.contentsOfDirectory(atPath: directory.path).count
    }

    private func waitForCompletion(_ run: (@escaping @Sendable () -> Void) -> Void) {
        let done = expectation(description: "ディスクを消し終える")
        run { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    // MARK: - パスとグループ

    func testGroupIdIsTakenFromStoragePath() {
        XCTAssertEqual(SoratomoGroupImageCaches.groupId(fromStoragePath: "soratomo/g1/u/s/display.jpg"), "g1")
        XCTAssertEqual(SoratomoGroupImageCaches.groupId(fromStoragePath: "soratomo/g1/u/s/thumb.jpg"), "g1")
        for malformed in ["", "soratomo", "soratomo/", "soratomo//u/s/display.jpg", "other/g1/u/s/display.jpg", "/soratomo/g1/x"] {
            XCTAssertNil(SoratomoGroupImageCaches.groupId(fromStoragePath: malformed), malformed)
        }
    }

    func testMalformedPathFallsBackWithoutCreatingGroupFolders() {
        // 壊れた値で落とさず、受け皿を返す。グループのフォルダは作らない
        for malformed in ["", "soratomo", "soratomo//u/s/display.jpg", "other/g1/u/s/display.jpg"] {
            XCTAssertTrue(caches.cache(forStoragePath: malformed) === fallback, malformed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parentDirectory.path))
    }

    func testSameGroupSharesOneCacheAndOtherGroupsDoNot() {
        let groupA = caches.cache(forStoragePath: path("gA", "sky-1"))
        XCTAssertTrue(groupA === caches.cache(forStoragePath: path("gA", "sky-2")), "同じグループで別のキャッシュになった")
        XCTAssertTrue(groupA === caches.cache(forStoragePath: SoratomoImagePaths(groupId: "gA", authorId: "x", skyId: "y").thumbnail))
        let groupB = caches.cache(forStoragePath: path("gB"))
        XCTAssertFalse(groupA === groupB, "別のグループが同じキャッシュになった")
        XCTAssertFalse(groupA === fallback)
        XCTAssertFalse(groupA === ImageCache.default)
    }

    // MARK: - 要確認 Q3（Kingfisher 8.6.2 の置き場とメモリの上限）

    func testGroupCacheLivesUnderParentWithKingfisherNaming() throws {
        let key = path("gA")
        let cache = caches.cache(forStoragePath: key)
        let expected = parentDirectory.appendingPathComponent("com.onevcat.Kingfisher.ImageCache.soratomo.gA", isDirectory: true)

        // 自分で組む規則（覚えに無いグループを消すときに使う）が、Kingfisher の本物と一致する
        XCTAssertEqual(cache.diskStorage.directoryURL.standardizedFileURL.path, expected.standardizedFileURL.path)
        XCTAssertEqual(caches.directoryURL(forGroup: "gA").standardizedFileURL.path, expected.standardizedFileURL.path)

        try cache.diskStorage.store(value: Data([0x01]), forKey: key)
        XCTAssertEqual(fileCount(in: expected), 1, "グループのフォルダに書かれていない")
    }

    func testGroupCacheMemoryLimitIsSplitByMembershipCap() {
        XCTAssertEqual(SoratomoGroupService.maxListedGroups, 10)
        let expected = Int(ProcessInfo.processInfo.physicalMemory / 4 / 10)
        XCTAssertEqual(SoratomoGroupImageCaches.groupMemoryCostLimit, expected)
        XCTAssertEqual(caches.cache(forStoragePath: path("gA")).memoryStorage.config.totalCostLimit, expected)
        // 受け皿（1.14.x の共通のキャッシュと同じ作り）は Kingfisher の既定（1/4）のまま
        XCTAssertEqual(fallback.memoryStorage.config.totalCostLimit, Int(ProcessInfo.processInfo.physicalMemory / 4))
    }

    // MARK: - 消す

    func testRemoveGroupDropsOnlyThatGroup() throws {
        let keyA = path("gA")
        let keyB = path("gB")
        let cacheA = caches.cache(forStoragePath: keyA)
        let cacheB = caches.cache(forStoragePath: keyB)
        try storeInMemoryAndDisk(cacheA, key: keyA)
        try storeInMemoryAndDisk(cacheB, key: keyB)
        // 陽性対照: 消す前は両方入っている
        XCTAssertTrue(cacheA.memoryStorage.isCached(forKey: keyA))
        XCTAssertEqual(fileCount(in: caches.directoryURL(forGroup: "gA")), 1)

        waitForCompletion { caches.removeGroup("gA", completion: $0) }

        XCTAssertFalse(cacheA.memoryStorage.isCached(forKey: keyA), "抜けたグループのメモリが残っている")
        XCTAssertNil(fileCount(in: caches.directoryURL(forGroup: "gA")), "抜けたグループのフォルダが残っている")
        XCTAssertTrue(cacheB.memoryStorage.isCached(forKey: keyB), "ほかのグループのメモリまで消えた")
        XCTAssertEqual(fileCount(in: caches.directoryURL(forGroup: "gB")), 1, "ほかのグループのディスクまで消えた")
        // 覚えから外れているので、次は新しいキャッシュになる
        XCTAssertFalse(caches.cache(forStoragePath: keyA) === cacheA)
    }

    func testLateStoreAfterRemoveGroupDoesNotRecreateFolder() {
        // 抜けた後に届いた読み込み途中の画像は、消す前に受け取ったキャッシュ（覚えから外れたインスタンス）へ
        // 保存しに来る。Kingfisher の provider の読み込みは取り消せないため（leave-group /review-full D2）
        let key = path("gA")
        let inFlight = caches.cache(forStoragePath: key)
        waitForCompletion { caches.removeGroup("gA", completion: $0) }
        // 陽性対照の前提: 消した直後はフォルダが無い
        XCTAssertNil(fileCount(in: caches.directoryURL(forGroup: "gA")))

        // 読み込みが終わり、Kingfisher がそのインスタンスへ保存する（本物の保存の入口・ディスクにも書く）
        let stored = expectation(description: "保存を終える")
        inFlight.store(makeImage(), original: Data([0x01, 0x02, 0x03]), forKey: key, toDisk: true) { _ in
            stored.fulfill()
        }
        wait(for: [stored], timeout: 5)

        XCTAssertNil(fileCount(in: caches.directoryURL(forGroup: "gA")), "抜けたグループのフォルダが作り直された")
        XCTAssertFalse(inFlight.memoryStorage.isCached(forKey: key), "抜けたグループの画像がメモリに戻った")
    }

    func testRemoveGroupDeletesFolderLeftByPreviousLaunch() throws {
        // 前の起動で書いたフォルダ（この起動の覚えには無い）も消す
        let key = path("gA")
        let previousLaunch = SoratomoGroupImageCaches(parentDirectory: parentDirectory, fallback: fallback)
        try previousLaunch.cache(forStoragePath: key).diskStorage.store(value: Data([0x01]), forKey: key)
        XCTAssertEqual(fileCount(in: caches.directoryURL(forGroup: "gA")), 1)

        waitForCompletion { caches.removeGroup("gA", completion: $0) }

        XCTAssertNil(fileCount(in: caches.directoryURL(forGroup: "gA")))
    }

    func testClearEmptiesAllGroupsAndFallback() throws {
        let keyA = path("gA")
        let keyB = path("gB")
        let cacheA = caches.cache(forStoragePath: keyA)
        let cacheB = caches.cache(forStoragePath: keyB)
        try storeInMemoryAndDisk(cacheA, key: keyA)
        try storeInMemoryAndDisk(cacheB, key: keyB)
        try storeInMemoryAndDisk(fallback, key: "legacy-key")
        XCTAssertEqual(fileCount(in: fallback.diskStorage.directoryURL), 1)

        waitForCompletion { caches.clear(completion: $0) }

        XCTAssertFalse(cacheA.memoryStorage.isCached(forKey: keyA))
        XCTAssertFalse(cacheB.memoryStorage.isCached(forKey: keyB))
        XCTAssertFalse(FileManager.default.fileExists(atPath: parentDirectory.path), "親のフォルダが残っている")
        XCTAssertFalse(fallback.memoryStorage.isCached(forKey: "legacy-key"), "受け皿のメモリが残っている")
        XCTAssertEqual(fileCount(in: fallback.diskStorage.directoryURL) ?? 0, 0, "受け皿のディスクが残っている")
        XCTAssertFalse(caches.cache(forStoragePath: keyA) === cacheA)
    }

    func testPurgeLegacyRunsOnlyOnce() throws {
        try storeInMemoryAndDisk(fallback, key: "legacy-key")

        waitForCompletion { caches.purgeLegacyIfNeeded(defaults: defaults, completion: $0) }

        XCTAssertTrue(defaults.bool(forKey: SoratomoImageCache.legacyPurgedKey))
        XCTAssertFalse(fallback.memoryStorage.isCached(forKey: "legacy-key"))
        XCTAssertEqual(fileCount(in: fallback.diskStorage.directoryURL) ?? 0, 0, "1.14.x の画像がディスクに残っている")

        // 2 回目は消さない（印が立っている）
        fallback.store(makeImage(), forKey: "after-purge", toDisk: false)
        caches.purgeLegacyIfNeeded(defaults: defaults)
        XCTAssertTrue(fallback.memoryStorage.isCached(forKey: "after-purge"), "2 回目も消した")
    }
}
