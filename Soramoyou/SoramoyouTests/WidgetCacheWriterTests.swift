//
//  WidgetCacheWriterTests.swift
//  SoramoyouTests
//
//  ウィジェット用キャッシュライターの I/O ロジックを、注入した temp ディレクトリで検証する。
//  App Group entitlement は不要（containerURL を注入できる設計のため）。
//

import XCTest
import UIKit
@testable import Soramoyou

final class WidgetCacheWriterTests: XCTestCase {

    private var tempContainer: URL!

    override func setUpWithError() throws {
        tempContainer = FileManager.default.temporaryDirectory
            .appendingPathComponent("widgetcache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempContainer, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempContainer, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        tempContainer = nil
    }

    // MARK: - ヘルパー

    /// 指定ピクセルサイズの単色画像（scale=1 でピクセル＝ポイント）。
    private func makeImage(_ width: CGFloat, _ height: CGFloat, color: UIColor = .systemBlue) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func writer(maxEntries: Int = 50) -> WidgetCacheWriter {
        WidgetCacheWriter(containerURL: tempContainer, maxEntries: maxEntries)
    }

    private func imageURL(_ fileName: String) -> URL {
        tempContainer
            .appendingPathComponent(AppGroup.Path.imagesDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - テスト

    func testCacheWritesImageAndIndex() throws {
        let w = writer()
        let index = try w.cache(
            image: makeImage(1000, 800),
            postId: "P1",
            timeOfDay: "evening",
            skyColors: ["#ff8a00"],
            createdAt: Date(timeIntervalSince1970: 1000)
        )

        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entries.first?.postId, "P1")
        XCTAssertEqual(index.entries.first?.imageFileName, "P1.jpg")

        // 画像ファイルが書かれ、長辺 512px 以内に縮小されている。
        let fileURL = imageURL("P1.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let data = try Data(contentsOf: fileURL)
        let decoded = UIImage(data: data)?.cgImage
        XCTAssertNotNil(decoded)
        let longSide = max(decoded!.width, decoded!.height)
        XCTAssertLessThanOrEqual(longSide, 512, "長辺は 512px 以内")
        XCTAssertGreaterThan(longSide, 0)

        // 別インスタンスから読んでも同じ。
        XCTAssertEqual(writer().loadIndex().entries.first?.postId, "P1")
    }

    func testDuplicatePostIdIsDeduplicated() throws {
        let w = writer()
        _ = try w.cache(image: makeImage(600, 400), postId: "P1", timeOfDay: "morning", skyColors: [], createdAt: Date(timeIntervalSince1970: 1000))
        let index = try w.cache(image: makeImage(600, 400), postId: "P1", timeOfDay: "evening", skyColors: [], createdAt: Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(index.entries.count, 1, "同じ postId は 1 件に集約")
        XCTAssertEqual(index.entries.first?.timeOfDay, "evening", "新しい内容で上書き")
    }

    func testPruningKeepsNewestUpToMax() throws {
        let w = writer(maxEntries: 3)
        // P1(古)〜P5(新) を順に書く。
        for i in 1...5 {
            _ = try w.cache(
                image: makeImage(400, 300),
                postId: "P\(i)",
                timeOfDay: nil,
                skyColors: [],
                createdAt: Date(timeIntervalSince1970: TimeInterval(1000 + i * 100))
            )
        }
        let index = w.loadIndex()
        XCTAssertEqual(index.entries.count, 3, "上限 3 件に切り詰め")
        let ids = Set(index.entries.map { $0.postId })
        XCTAssertEqual(ids, ["P3", "P4", "P5"], "新しい 3 件が残る")

        // 切り詰めで外れた画像ファイルは削除されている（孤児防止）。
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL("P1.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL("P2.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL("P5.jpg").path))
    }

    func testClearRemovesEverything() throws {
        let w = writer()
        _ = try w.cache(image: makeImage(400, 300), postId: "P1", timeOfDay: nil, skyColors: [], createdAt: Date())
        try w.clear()
        XCTAssertTrue(w.loadIndex().entries.isEmpty, "クリア後はインデックス空")
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL("P1.jpg").path))
    }

    func testContainerUnavailableThrows() {
        let w = WidgetCacheWriter(containerURL: nil)
        XCTAssertThrowsError(
            try w.cache(image: makeImage(100, 100), postId: "P1", timeOfDay: nil, skyColors: [], createdAt: Date())
        ) { error in
            XCTAssertEqual(error as? WidgetCacheWriter.WidgetCacheError, .containerUnavailable)
        }
    }
}
