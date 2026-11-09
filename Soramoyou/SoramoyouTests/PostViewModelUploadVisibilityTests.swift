//
//  PostViewModelUploadVisibilityTests.swift
//  SoramoyouTests
//
//  ⭐️ 投稿の画像を上げるとき、公開範囲によって Firestore に書く URL を変えることを検証する（URL 側の C-3）。
//  - フォロワー限定・非公開：画像は今までどおり Storage に上げるが、URL は取りに行かない
//    （url は ""・サムネイルの URL は nil・置き場 storagePath / thumbnailStoragePath は残す）
//  - 公開：今までどおり URL を取って書く（見張り役＝本物に替えても変わらないことを確かめる）
//  偽物の Storage は「上げた置き場」と「URL を取りに行った回数」を記録し、
//  返す URL は置き場から作る（期待値をテストの中で直に組み立てられるようにするため）。
//

@testable import Soramoyou
import UIKit
import XCTest

@MainActor
final class PostViewModelUploadVisibilityTests: XCTestCase {
    /// 8×8 のダミー画像（リサイズは MockImageService がそのまま返すので中身は問わない）
    private func dummyImage() -> UIImage {
        let size = CGSize(width: 8, height: 8)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Storage・画像処理・Firestore を偽物に替えた ViewModel と、検証用の Storage の偽物を返す
    private func makeViewModel(visibility: Visibility) -> (PostViewModel, MockStorageServiceForUpload) {
        let storage = MockStorageServiceForUpload()
        let vm = PostViewModel(
            userId: "u1",
            imageService: MockImageService(),
            storageService: storage,
            firestoreService: MockFirestoreService()
        )
        vm.visibility = visibility
        // uploadOriginalImages は selectedImages から上げる
        vm.selectedImages = [dummyImage()]
        return (vm, storage)
    }

    // MARK: - 本体とサムネイル（uploadImages）

    func testFollowersImagesWriteNoURL() async throws {
        try await assertImagesWriteNoURL(visibility: .followers, folder: "followers")
    }

    func testPrivateImagesWriteNoURL() async throws {
        try await assertImagesWriteNoURL(visibility: .private, folder: "private")
    }

    /// 見張り役：公開は今までどおり本体とサムネイルの URL を取って書く
    func testPublicImagesKeepURL() async throws {
        let (vm, storage) = makeViewModel(visibility: .public)

        let uploaded = try await vm.uploadImages([dummyImage()])

        XCTAssertEqual(uploaded.count, 1)
        let image = try XCTUnwrap(uploaded.first)
        XCTAssertTrue(image.storagePath.hasPrefix("posts/u1/public/"), "置き場は公開の場所: \(image.storagePath)")
        XCTAssertTrue(
            image.thumbnailStoragePath.hasPrefix("thumbnails/u1/public/"),
            "サムネイルの置き場は thumbnails/ 付き: \(image.thumbnailStoragePath)"
        )
        XCTAssertEqual(image.url, MockStorageServiceForUpload.fakeURL(for: image.storagePath).absoluteString)
        XCTAssertEqual(
            image.thumbnail,
            MockStorageServiceForUpload.fakeURL(for: image.thumbnailStoragePath).absoluteString,
            "サムネイルの URL は thumbnails/ 付きの置き場から取る"
        )
        XCTAssertEqual(storage.uploadedPaths, [image.storagePath, image.thumbnailStoragePath])
        XCTAssertEqual(storage.urlFetchCount, 2, "公開は本体とサムネイルの 2 つとも URL を取る")
    }

    // MARK: - 原画像（uploadOriginalImages）

    func testFollowersOriginalsWriteNoURL() async throws {
        try await assertOriginalsWriteNoURL(visibility: .followers, folder: "followers")
    }

    func testPrivateOriginalsWriteNoURL() async throws {
        try await assertOriginalsWriteNoURL(visibility: .private, folder: "private")
    }

    /// 見張り役：公開は今までどおり原画像の URL を取って書く
    func testPublicOriginalsKeepURL() async throws {
        let (vm, storage) = makeViewModel(visibility: .public)

        let uploaded = try await vm.uploadOriginalImages()

        XCTAssertEqual(uploaded.count, 1)
        let original = try XCTUnwrap(uploaded.first)
        XCTAssertTrue(original.storagePath.hasPrefix("originals/u1/public/"), "置き場は公開の場所: \(original.storagePath)")
        XCTAssertEqual(original.url, MockStorageServiceForUpload.fakeURL(for: original.storagePath).absoluteString)
        XCTAssertEqual(storage.uploadedPaths, [original.storagePath])
        XCTAssertEqual(storage.urlFetchCount, 1, "公開は原画像の URL を取る")
    }

    // MARK: - Helpers

    /// 公開以外の本体とサムネイル：上げるが URL は取らない・置き場は残す
    private func assertImagesWriteNoURL(
        visibility: Visibility,
        folder: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let (vm, storage) = makeViewModel(visibility: visibility)

        let uploaded = try await vm.uploadImages([dummyImage()])

        XCTAssertEqual(uploaded.count, 1, file: file, line: line)
        let image = try XCTUnwrap(uploaded.first, file: file, line: line)
        XCTAssertTrue(
            image.storagePath.hasPrefix("posts/u1/\(folder)/"),
            "置き場は \(folder) の場所: \(image.storagePath)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            image.thumbnailStoragePath.hasPrefix("thumbnails/u1/\(folder)/"),
            "サムネイルの置き場は thumbnails/ 付き: \(image.thumbnailStoragePath)",
            file: file,
            line: line
        )
        XCTAssertEqual(image.url, "", "公開以外は本体の URL を書かない", file: file, line: line)
        XCTAssertNil(image.thumbnail, "公開以外はサムネイルの URL を書かない", file: file, line: line)
        XCTAssertEqual(
            storage.uploadedPaths,
            [image.storagePath, image.thumbnailStoragePath],
            "画像そのものは今までどおり上げる",
            file: file,
            line: line
        )
        XCTAssertEqual(storage.urlFetchCount, 0, "公開以外は URL を取りに行かない", file: file, line: line)
    }

    /// 公開以外の原画像：上げるが URL は取らない・置き場は残す
    private func assertOriginalsWriteNoURL(
        visibility: Visibility,
        folder: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let (vm, storage) = makeViewModel(visibility: visibility)

        let uploaded = try await vm.uploadOriginalImages()

        XCTAssertEqual(uploaded.count, 1, file: file, line: line)
        let original = try XCTUnwrap(uploaded.first, file: file, line: line)
        XCTAssertTrue(
            original.storagePath.hasPrefix("originals/u1/\(folder)/"),
            "置き場は \(folder) の場所: \(original.storagePath)",
            file: file,
            line: line
        )
        XCTAssertEqual(original.url, "", "公開以外は原画像の URL を書かない", file: file, line: line)
        XCTAssertEqual(
            storage.uploadedPaths,
            [original.storagePath],
            "原画像そのものは今までどおり上げる",
            file: file,
            line: line
        )
        XCTAssertEqual(storage.urlFetchCount, 0, "公開以外は URL を取りに行かない", file: file, line: line)
    }
}

// MARK: - Mock

/// 上げた置き場と「URL を取りに行った」回数を記録する Storage の偽物
final class MockStorageServiceForUpload: StorageServiceProtocol {
    /// 上げた置き場（URL あり・なしのどちらで上げても記録する。サムネイルは thumbnails/ 付き）
    private(set) var uploadedPaths: [String] = []
    /// URL を取りに行った回数（uploadImage・uploadThumbnail・downloadURL のどれでも 1 回と数える）
    private(set) var urlFetchCount = 0

    /// 偽物が返す URL。置き場から作るので、テストで期待値を直に組み立てられる
    static func fakeURL(for path: String) -> URL {
        // テスト用の固定の文字列（置き場は英数字と / だけ）なので失敗しない
        URL(string: "https://fake-storage.test/\(path)")!
    }

    func uploadImage(_: UIImage, path: String) async throws -> URL {
        uploadedPaths.append(path)
        urlFetchCount += 1
        return Self.fakeURL(for: path)
    }

    func uploadThumbnail(_: UIImage, path: String) async throws -> URL {
        // 本物と同じく thumbnails/ を前に付けた所に置く
        let fullPath = "thumbnails/\(path)"
        uploadedPaths.append(fullPath)
        urlFetchCount += 1
        return Self.fakeURL(for: fullPath)
    }

    func uploadImageWithoutURL(_: UIImage, path: String) async throws {
        uploadedPaths.append(path)
    }

    func uploadThumbnailWithoutURL(_: UIImage, path: String) async throws {
        uploadedPaths.append("thumbnails/\(path)")
    }

    func downloadURL(path: String) async throws -> URL {
        urlFetchCount += 1
        return Self.fakeURL(for: path)
    }

    func deleteImage(path _: String) async throws {}

    func uploadProgress(path _: String) -> AsyncStream<Double> {
        AsyncStream { $0.finish() }
    }
}
