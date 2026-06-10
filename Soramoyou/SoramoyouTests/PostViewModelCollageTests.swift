//
//  PostViewModelCollageTests.swift
//  SoramoyouTests
//
//  ⭐️ 配置写真(v1)の createPost 分岐を直接検証する。
//  savePost のアップロードはモック不要で、純粋構築の createPost を @testable で直接呼ぶ。
//  - collage は合成済み1枚（images.count==1）
//  - 原画像/抽出メタは付けない（再編集破綻・検索の歪み防止）
//  - パネルラベルは4枚分すべて保存される（fold後1枚から枚数導出していた切り詰めバグの回帰防止）
//

import XCTest
import UIKit
@testable import Soramoyou

final class PostViewModelCollageTests: XCTestCase {

    /// 1×1 のダミー画像
    private func dummyImage() -> UIImage {
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    @MainActor
    func testCreatePostCollageNilsOriginalsAndMetaAndKeepsAllLabels() throws {
        let vm = PostViewModel(userId: "u1")
        vm.setSelectedImages([dummyImage(), dummyImage(), dummyImage(), dummyImage()])
        vm.postKind = .collage
        vm.collageLayout = .grid2x2
        vm.panelLabels = ["朝", "昼", "夜", "雨"]
        // 抽出メタが存在しても collage では nil 化されることを検証するため、あえてセットする。
        vm.extractedInfo = ExtractedImageInfo(
            capturedAt: Date(), timeOfDay: .morning,
            skyColors: ["#abcdef"], colorTemperature: 5500, skyType: .clear
        )

        // fold 後を模す: 本体は合成済み1枚、原画像URLは素材4枚分そのまま渡す。
        let folded = [UploadedImage(
            url: "https://e.com/c.jpg", thumbnail: "https://e.com/c_t.jpg",
            width: 1000, height: 1000, storagePath: "posts/u1/c.jpg", thumbnailStoragePath: "posts/u1/c_t.jpg"
        )]
        let originals = (0..<4).map { i in
            UploadedOriginalImage(url: "https://e.com/o\(i).jpg", width: 100, height: 100, storagePath: "orig/u1/o\(i).jpg")
        }

        let post = try vm.createPost(imageURLs: folded, originalImageURLs: originals)

        XCTAssertEqual(post.images.count, 1, "collage は合成済み1枚を保存する")
        XCTAssertNil(post.originalImages, "collage は原画像を残さない（images=1枚との非対称・再編集破綻を防ぐ）")
        XCTAssertEqual(post.postKind, .collage)
        XCTAssertEqual(post.collageLayout, .grid2x2)
        // ★切り詰めバグ回帰防止: fold後1枚ではなく素材4枚からラベル枚数を導出するので全ラベルが残る
        XCTAssertEqual(post.panelLabels, ["朝", "昼", "夜", "雨"], "4パネル分のラベルが全て保存されるべき")

        // 抽出メタは collage では付けない（朝/昼/夜/雨を1値で表せない＝検索の歪み防止）
        XCTAssertNil(post.skyType)
        XCTAssertNil(post.timeOfDay)
        XCTAssertNil(post.skyColors)
        XCTAssertNil(post.colorTemperature)
        XCTAssertNil(post.capturedAt)
    }

    @MainActor
    func testCreatePostCollageOmitsLabelsWhenAllEmpty() throws {
        let vm = PostViewModel(userId: "u1")
        vm.setSelectedImages([dummyImage(), dummyImage(), dummyImage(), dummyImage()])
        vm.postKind = .collage
        vm.panelLabels = ["", "  ", "", ""]   // 全て空/空白

        let folded = [UploadedImage(
            url: "https://e.com/c.jpg", thumbnail: nil, width: 1000, height: 1000,
            storagePath: "posts/u1/c.jpg", thumbnailStoragePath: "posts/u1/c_t.jpg"
        )]
        let post = try vm.createPost(imageURLs: folded, originalImageURLs: nil)
        XCTAssertNil(post.panelLabels, "全ラベルが空なら panelLabels は保存しない（nil）")
    }

    @MainActor
    func testCreatePostCompositeNilsExternalEditInfo() throws {
        // 合成投稿(collage/panorama)は端末内で生成した新規画像なので、素材1枚目の外部編集情報を
        // 引き継がない（ギャラリーの「写真Appで編集済み」等のバッジ誤表示を防ぐ）。F5 回帰防止。
        for kind in [PostKind.collage, PostKind.panorama] {
            let vm = PostViewModel(userId: "u1")
            vm.setSelectedImages([dummyImage()])
            vm.postKind = kind
            // 素材に外部編集情報がある状態を模す（4枚分。合成後は1枚でも元4枚分が残りうる）。
            vm.setExternalEditInfos([
                ExternalEditInfo(hasAdjustments: true, formatIdentifier: "com.apple.photo"),
                ExternalEditInfo(hasAdjustments: true, formatIdentifier: "com.apple.photo"),
                ExternalEditInfo(hasAdjustments: true, formatIdentifier: "com.apple.photo"),
                ExternalEditInfo(hasAdjustments: true, formatIdentifier: "com.apple.photo")
            ])
            let folded = [UploadedImage(
                url: "https://e.com/c.jpg", thumbnail: "https://e.com/c_t.jpg",
                width: 1000, height: 1000, storagePath: "posts/u1/c.jpg", thumbnailStoragePath: "posts/u1/c_t.jpg"
            )]
            let post = try vm.createPost(imageURLs: folded, originalImageURLs: nil)
            XCTAssertEqual(post.images.count, 1)
            XCTAssertNil(post.images[0].externalEditInfo, "\(kind) は合成画像に素材の外部編集情報を付けない")
        }
    }

    @MainActor
    func testCreatePostSingleKeepsExternalEditInfo() throws {
        // 通常投稿(.single)は素材＝投稿画像が1対1なので、外部編集情報を従来どおり保持する
        // （合成分岐が単写真に波及しないことの確認）。
        let vm = PostViewModel(userId: "u1")
        vm.setSelectedImages([dummyImage()])
        vm.postKind = .single
        vm.setExternalEditInfos([ExternalEditInfo(hasAdjustments: true, formatIdentifier: "com.apple.photo")])
        let imageURLs = [UploadedImage(
            url: "https://e.com/s.jpg", thumbnail: "https://e.com/s_t.jpg",
            width: 800, height: 600, storagePath: "posts/u1/s.jpg", thumbnailStoragePath: "posts/u1/s_t.jpg"
        )]
        let post = try vm.createPost(imageURLs: imageURLs, originalImageURLs: nil)
        XCTAssertEqual(post.images[0].externalEditInfo?.formatIdentifier, "com.apple.photo",
                       "単写真は外部編集情報を保持する")
    }

    @MainActor
    func testCreatePostSingleKeepsOriginalsAndMeta() throws {
        // 通常投稿(.single)は従来どおり原画像・メタを保持する（collage 分岐が単写真に波及しないことの確認）。
        let vm = PostViewModel(userId: "u1")
        vm.setSelectedImages([dummyImage()])
        vm.postKind = .single
        vm.extractedInfo = ExtractedImageInfo(
            capturedAt: nil, timeOfDay: .evening, skyColors: ["#112233"], colorTemperature: nil, skyType: .sunset
        )
        let imageURLs = [UploadedImage(
            url: "https://e.com/s.jpg", thumbnail: "https://e.com/s_t.jpg",
            width: 800, height: 600, storagePath: "posts/u1/s.jpg", thumbnailStoragePath: "posts/u1/s_t.jpg"
        )]
        let originals = [UploadedOriginalImage(url: "https://e.com/so.jpg", width: 800, height: 600, storagePath: "orig/u1/so.jpg")]

        let post = try vm.createPost(imageURLs: imageURLs, originalImageURLs: originals)
        XCTAssertNil(post.postKind, ".single は postKind を nil 保存（旧投稿と同形状）")
        XCTAssertEqual(post.originalImages?.count, 1, "単写真は原画像を保持する")
        XCTAssertEqual(post.timeOfDay, .evening, "単写真は抽出メタを保持する")
        XCTAssertEqual(post.skyType, .sunset)
    }
}
