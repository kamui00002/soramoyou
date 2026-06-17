//
//  WidgetLocationStoreTests.swift
//  SoramoyouTests
//
//  App Group への粗い現在地 dual-write（本体書き / ウィジェット読み）の純関数テスト。
//  entitlement なし環境でも検証できるよう、コンテナURLは temp ディレクトリを注入する。
//

import XCTest
@testable import Soramoyou

final class WidgetLocationStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("widget-loc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWriteThenReadRoundTrips() {
        let ok = WidgetLocationStore.write(latitude: 35.0, longitude: 139.0, containerURL: tempDir)
        XCTAssertTrue(ok)
        let record = WidgetLocationStore.read(containerURL: tempDir)
        XCTAssertEqual(record?.latitude, 35.0)
        XCTAssertEqual(record?.longitude, 139.0)
    }

    func testWriteCoarsensToTwoDecimals() {
        // 街区レベルへ丸める（プライバシー）。35.681236 → 35.68 / 139.767125 → 139.77。
        WidgetLocationStore.write(latitude: 35.681236, longitude: 139.767125, containerURL: tempDir)
        let record = WidgetLocationStore.read(containerURL: tempDir)
        XCTAssertEqual(record?.latitude ?? 0, 35.68, accuracy: 0.0001)
        XCTAssertEqual(record?.longitude ?? 0, 139.77, accuracy: 0.0001)
    }

    func testReadMissingReturnsNil() {
        XCTAssertNil(WidgetLocationStore.read(containerURL: tempDir), "未書き込みなら nil（→ 東京フォールバック）")
    }

    func testWriteWithNilContainerFails() {
        // entitlement 未付与（コンテナ取得不可）でもクラッシュせず false を返す。
        XCTAssertFalse(WidgetLocationStore.write(latitude: 1, longitude: 1, containerURL: nil))
    }

    func testLatestWriteOverwrites() {
        WidgetLocationStore.write(latitude: 10, longitude: 20, containerURL: tempDir)
        WidgetLocationStore.write(latitude: 30, longitude: 40, containerURL: tempDir)
        let record = WidgetLocationStore.read(containerURL: tempDir)
        XCTAssertEqual(record?.latitude, 30, "最後に書いた座標で上書きされる")
        XCTAssertEqual(record?.longitude, 40)
    }
}
