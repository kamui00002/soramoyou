//
//  ColorMatchingTests.swift
//  SoramoyouTests
//
//  ColorMatchingユーティリティのユニットテスト
//  色変換・距離計算・フィルタリングが正しく動作することを検証
//

import XCTest
@testable import Soramoyou

final class ColorMatchingTests: XCTestCase {

    // MARK: - hexToRGB テスト

    /// "#"プレフィックス付きの16進数カラーコードを正しく変換できること
    func testHexToRGBWithHash() {
        let result = ColorMatching.hexToRGB("#FF0000")

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(result?.g, 0.0, accuracy: 0.001)
        XCTAssertEqual(result?.b, 0.0, accuracy: 0.001)
    }

    /// "#"プレフィックスなしの16進数カラーコードを正しく変換できること
    func testHexToRGBWithoutHash() {
        let result = ColorMatching.hexToRGB("00FF00")

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.r, 0.0, accuracy: 0.001)
        XCTAssertEqual(result?.g, 1.0, accuracy: 0.001)
        XCTAssertEqual(result?.b, 0.0, accuracy: 0.001)
    }

    /// 青色（#0000FF）を正しく変換できること
    func testHexToRGBBlue() {
        let result = ColorMatching.hexToRGB("#0000FF")

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.r, 0.0, accuracy: 0.001)
        XCTAssertEqual(result?.g, 0.0, accuracy: 0.001)
        XCTAssertEqual(result?.b, 1.0, accuracy: 0.001)
    }

    /// 無効なカラーコード（桁数不足）でnilを返すこと
    func testHexToRGBInvalidShortString() {
        let result = ColorMatching.hexToRGB("#FFF")
        XCTAssertNil(result)
    }

    /// 空文字列でnilを返すこと
    func testHexToRGBEmptyString() {
        let result = ColorMatching.hexToRGB("")
        XCTAssertNil(result)
    }

    /// 無効な16進数文字でnilを返すこと
    func testHexToRGBInvalidHexCharacters() {
        let result = ColorMatching.hexToRGB("#GGGGGG")
        XCTAssertNil(result)
    }

    /// 前後の空白を除去して正しく変換できること
    func testHexToRGBWithWhitespace() {
        let result = ColorMatching.hexToRGB("  #FF0000  ")

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.r, 1.0, accuracy: 0.001)
    }

    // MARK: - calculateRGBDistance テスト

    /// 同一色間の距離が0であること
    func testCalculateRGBDistanceSameColor() {
        let color: ColorMatching.RGB = (r: 0.5, g: 0.5, b: 0.5)
        let distance = ColorMatching.calculateRGBDistance(color, color)

        XCTAssertEqual(distance, 0.0, accuracy: 0.001)
    }

    /// 赤と緑の距離が正しく計算されること
    func testCalculateRGBDistanceRedAndGreen() {
        let red: ColorMatching.RGB = (r: 1.0, g: 0.0, b: 0.0)
        let green: ColorMatching.RGB = (r: 0.0, g: 1.0, b: 0.0)

        let distance = ColorMatching.calculateRGBDistance(red, green)

        // sqrt(1^2 + 1^2 + 0^2) = sqrt(2) ≈ 1.414
        XCTAssertEqual(distance, sqrt(2.0), accuracy: 0.001)
    }

    /// 黒と白の距離が最大値（sqrt(3)）であること
    func testCalculateRGBDistanceBlackAndWhite() {
        let black: ColorMatching.RGB = (r: 0.0, g: 0.0, b: 0.0)
        let white: ColorMatching.RGB = (r: 1.0, g: 1.0, b: 1.0)

        let distance = ColorMatching.calculateRGBDistance(black, white)

        // sqrt(1^2 + 1^2 + 1^2) = sqrt(3) ≈ 1.732
        XCTAssertEqual(distance, sqrt(3.0), accuracy: 0.001)
    }

    // MARK: - filterPostsByColorDistance テスト

    /// ターゲット色に近い投稿のみがフィルタリングされること
    func testFilterPostsByColorDistance() {
        // 赤系の投稿と青系の投稿を用意
        let redPost = createTestPost(id: "red-post", skyColors: ["#FF0000"])
        let bluePost = createTestPost(id: "blue-post", skyColors: ["#0000FF"])

        let posts = [redPost, bluePost]

        // 赤色でフィルタリング（閾値0.5）
        let result = ColorMatching.filterPostsByColorDistance(
            posts: posts, targetColor: "#FF0000", threshold: 0.5
        )

        // 赤い投稿のみが残ること
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "red-post")
    }

    /// 閾値が大きい場合は全ての投稿が返されること
    func testFilterPostsByColorDistanceLargeThreshold() {
        let redPost = createTestPost(id: "red-post", skyColors: ["#FF0000"])
        let bluePost = createTestPost(id: "blue-post", skyColors: ["#0000FF"])

        let posts = [redPost, bluePost]

        // 閾値を大きくして全投稿を含める
        let result = ColorMatching.filterPostsByColorDistance(
            posts: posts, targetColor: "#FF0000", threshold: 2.0
        )

        XCTAssertEqual(result.count, 2)
    }

    /// skyColorsがnilの投稿がフィルタリングで除外されること
    func testFilterPostsByColorDistanceNilSkyColors() {
        let postWithColors = createTestPost(id: "with-colors", skyColors: ["#FF0000"])
        let postWithoutColors = createTestPost(id: "without-colors", skyColors: nil)

        let posts = [postWithColors, postWithoutColors]

        let result = ColorMatching.filterPostsByColorDistance(
            posts: posts, targetColor: "#FF0000", threshold: 0.5
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "with-colors")
    }

    /// 無効なターゲット色の場合、元の投稿リストがそのまま返されること
    func testFilterPostsByColorDistanceInvalidTargetColor() {
        let post = createTestPost(id: "test", skyColors: ["#FF0000"])
        let posts = [post]

        let result = ColorMatching.filterPostsByColorDistance(
            posts: posts, targetColor: "invalid", threshold: 0.5
        )

        // 無効な色の場合は元のリストをそのまま返す
        XCTAssertEqual(result.count, 1)
    }

    /// 投稿が複数のskyColorsを持つ場合、いずれかが閾値以内なら含まれること
    func testFilterPostsByColorDistanceMultipleSkyColors() {
        // 赤と青の両方を持つ投稿
        let post = createTestPost(id: "multi-color", skyColors: ["#0000FF", "#FF0000"])

        let posts = [post]

        // 赤色でフィルタリング（閾値0.5）
        let result = ColorMatching.filterPostsByColorDistance(
            posts: posts, targetColor: "#FF0000", threshold: 0.5
        )

        // 赤色が含まれているので結果に残る
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - ヘルパーメソッド

    private func createTestPost(
        id: String,
        skyColors: [String]?
    ) -> Post {
        let imageInfo = ImageInfo(
            url: "https://example.com/image.jpg",
            width: 1024,
            height: 768,
            order: 0
        )

        return Post(
            id: id,
            userId: "test-user",
            images: [imageInfo],
            caption: "Test",
            skyColors: skyColors,
            visibility: .public
        )
    }
}
