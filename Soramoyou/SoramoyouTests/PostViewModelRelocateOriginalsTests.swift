//
//  PostViewModelRelocateOriginalsTests.swift
//  SoramoyouTests
//
//  ⭐️ 投稿の再編集で公開範囲を変えたとき、原画像を新しい公開範囲のフォルダへ移すことを検証する（URL 側の E）。
//  - 置き場（originals/{uid}/{公開範囲}/{ファイル名}）の 3 つ目が新しい公開範囲と違えば、同じファイル名で
//    新しいフォルダへ中身のまま写す（downloadData → uploadDataWithoutURL）。公開になるときだけ URL を取る
//  - 写した先は後片付けの対象に入れる（投稿の更新が失敗したら消える）。移す前の置き場は更新の成功後に消す
//  - 同じフォルダのままなら写さない（公開以外で古い URL が残っていたら "" にするだけ・公開で URL が空なら取る）
//  - 置き場が分からない・持ち主が違う原画像は触らない
//  savePost() を丸ごと通すと、テストの土台のアプリから本番の PostHog に post_completed が送られるため、
//  関数単位で確かめる（PostViewModelRecipeCorpusTests と同じ方針）。
//  期待する置き場・URL・中身はテストの中に直に書く（入力から組み立てると、何もしない実装でも一致してしまうため）。
//

@testable import Soramoyou
import UIKit
import XCTest

@MainActor
final class PostViewModelRelocateOriginalsTests: XCTestCase {
    /// 元投稿（公開範囲と原画像）で再編集の状態を作り、公開範囲を新しいものに変えた ViewModel を返す
    private func makeViewModel(
        oldVisibility: Visibility,
        newVisibility: Visibility,
        originals: [ImageInfo]?
    ) -> (PostViewModel, MockStorageServiceForRelocate) {
        let storage = MockStorageServiceForRelocate()
        let vm = PostViewModel(
            userId: "u1",
            imageService: MockImageService(),
            storageService: storage,
            firestoreService: MockFirestoreService()
        )
        // 編集済みの本体はこのテストでは見ない（再編集の状態を作るためだけに置く）
        let edited = ImageInfo(url: "", width: 400, height: 300, order: 0, storagePath: "posts/u1/public/e1.jpg")
        let post = Post(id: "p1", userId: "u1", images: [edited], originalImages: originals, visibility: oldVisibility)
        // 再編集の入口と同じく、元投稿の値を流し込んでから利用者が公開範囲を変える
        vm.seedForEditing(PostEditingContext(post: post))
        vm.visibility = newVisibility
        return (vm, storage)
    }

    /// 原画像（幅 400・高さ 300）。order は並び順
    private func original(url: String, storagePath: String?, order: Int = 0) -> ImageInfo {
        ImageInfo(url: url, width: 400, height: 300, order: order, storagePath: storagePath)
    }

    // MARK: - 公開範囲が変わる（写す）

    /// 公開 → フォロワー限定：同じファイル名でフォロワー限定のフォルダへ中身のまま写し、URL は書かない
    func testPublicToFollowersMovesOriginalsWithoutURL() async throws {
        let (vm, storage) = makeViewModel(
            oldVisibility: .public,
            newVisibility: .followers,
            originals: [
                original(url: "https://fake-storage.test/originals/u1/public/o1.jpg", storagePath: "originals/u1/public/o1.jpg", order: 0),
                original(url: "https://fake-storage.test/originals/u1/public/o2.jpg", storagePath: "originals/u1/public/o2.jpg", order: 1),
            ]
        )

        let relocated = try await vm.relocateOriginalImagesForEditing()

        let result = try XCTUnwrap(relocated)
        XCTAssertEqual(storage.calls, [
            "downloadData originals/u1/public/o1.jpg",
            "uploadDataWithoutURL originals/u1/followers/o1.jpg",
            "downloadData originals/u1/public/o2.jpg",
            "uploadDataWithoutURL originals/u1/followers/o2.jpg",
        ], "1 枚ずつ読んで写す・URL は取らない・この段では何も消さない")
        XCTAssertEqual(
            storage.uploadedData["originals/u1/followers/o1.jpg"],
            Data("中身:originals/u1/public/o1.jpg".utf8),
            "JPEG にし直さず中身のまま写す"
        )
        XCTAssertEqual(storage.uploadedData["originals/u1/followers/o2.jpg"], Data("中身:originals/u1/public/o2.jpg".utf8))
        XCTAssertEqual(result.images, [
            ImageInfo(url: "", width: 400, height: 300, order: 0, storagePath: "originals/u1/followers/o1.jpg"),
            ImageInfo(url: "", width: 400, height: 300, order: 1, storagePath: "originals/u1/followers/o2.jpg"),
        ])
        XCTAssertEqual(result.oldPathsToDelete, ["originals/u1/public/o1.jpg", "originals/u1/public/o2.jpg"])
    }

    /// フォロワー限定 → 公開：公開のフォルダへ写し、写した先の URL を取って書く
    func testFollowersToPublicMovesOriginalsWithURL() async throws {
        let (vm, storage) = makeViewModel(
            oldVisibility: .followers,
            newVisibility: .public,
            originals: [original(url: "", storagePath: "originals/u1/followers/o1.jpg")]
        )

        let relocated = try await vm.relocateOriginalImagesForEditing()

        let result = try XCTUnwrap(relocated)
        XCTAssertEqual(storage.calls, [
            "downloadData originals/u1/followers/o1.jpg",
            "uploadDataWithoutURL originals/u1/public/o1.jpg",
            "downloadURL originals/u1/public/o1.jpg",
        ])
        XCTAssertEqual(storage.uploadedData["originals/u1/public/o1.jpg"], Data("中身:originals/u1/followers/o1.jpg".utf8))
        XCTAssertEqual(result.images, [
            ImageInfo(
                url: "https://fake-storage.test/originals/u1/public/o1.jpg",
                width: 400,
                height: 300,
                order: 0,
                storagePath: "originals/u1/public/o1.jpg"
            ),
        ])
        XCTAssertEqual(result.oldPathsToDelete, ["originals/u1/followers/o1.jpg"])
    }

    /// 非公開 → フォロワー限定：フォロワー限定のフォルダへ写し、URL は書かない
    func testPrivateToFollowersMovesOriginalsWithoutURL() async throws {
        let (vm, storage) = makeViewModel(
            oldVisibility: .private,
            newVisibility: .followers,
            originals: [original(url: "", storagePath: "originals/u1/private/o1.jpg")]
        )

        let relocated = try await vm.relocateOriginalImagesForEditing()

        let result = try XCTUnwrap(relocated)
        XCTAssertEqual(storage.calls, [
            "downloadData originals/u1/private/o1.jpg",
            "uploadDataWithoutURL originals/u1/followers/o1.jpg",
        ])
        XCTAssertEqual(storage.uploadedData["originals/u1/followers/o1.jpg"], Data("中身:originals/u1/private/o1.jpg".utf8))
        XCTAssertEqual(result.images, [
            ImageInfo(url: "", width: 400, height: 300, order: 0, storagePath: "originals/u1/followers/o1.jpg"),
        ])
        XCTAssertEqual(result.oldPathsToDelete, ["originals/u1/private/o1.jpg"])
    }

    /// 置き場（storagePath）を持たない旧データは、URL から置き場を取り出して写す
    func testLegacyOriginalWithoutStoragePathMovesUsingURL() async throws {
        let (vm, storage) = makeViewModel(
            oldVisibility: .public,
            newVisibility: .followers,
            originals: [
                original(
                    url: "https://firebasestorage.googleapis.com/v0/b/soramoyou-test.appspot.com/o/originals%2Fu1%2Fpublic%2Fo1.jpg?alt=media&token=t1",
                    storagePath: nil
                ),
            ]
        )

        let relocated = try await vm.relocateOriginalImagesForEditing()

        let result = try XCTUnwrap(relocated)
        XCTAssertEqual(storage.calls, [
            "downloadData originals/u1/public/o1.jpg",
            "uploadDataWithoutURL originals/u1/followers/o1.jpg",
        ])
        XCTAssertEqual(result.images, [
            ImageInfo(url: "", width: 400, height: 300, order: 0, storagePath: "originals/u1/followers/o1.jpg"),
        ])
        XCTAssertEqual(result.oldPathsToDelete, ["originals/u1/public/o1.jpg"])
    }

    // MARK: - 後片付け（投稿の更新の失敗・古いファイルの削除の失敗）

    /// 投稿の更新（updatePost）が失敗したとき後片付けで消えるのは写した先だけ（移す前の原画像は消さない）
    func testRelocationRegistersOnlyNewCopiesForRollback() async throws {
        let (vm, _) = makeViewModel(
            oldVisibility: .public,
            newVisibility: .followers,
            originals: [original(url: "https://fake-storage.test/originals/u1/public/o1.jpg", storagePath: "originals/u1/public/o1.jpg")]
        )

        _ = try await vm.relocateOriginalImagesForEditing()

        XCTAssertEqual(vm.uploadedOriginalImageURLs, ["originals/u1/followers/o1.jpg"])
    }

    /// 移す前の原画像を消すのに失敗しても、投げずに残りを消し続ける（写した先には触らない）
    func testDeleteReplacedFilesContinuesAfterFailure() async throws {
        let (vm, storage) = makeViewModel(
            oldVisibility: .public,
            newVisibility: .followers,
            originals: [original(url: "https://fake-storage.test/originals/u1/public/o1.jpg", storagePath: "originals/u1/public/o1.jpg")]
        )
        storage.failingDeletePaths = ["originals/u1/public/o1.jpg"]
        let relocated = try await vm.relocateOriginalImagesForEditing()
        let result = try XCTUnwrap(relocated)

        await vm.deleteReplacedFiles(result.oldPathsToDelete + ["posts/u1/public/e1.jpg"])

        XCTAssertEqual(storage.calls, [
            "downloadData originals/u1/public/o1.jpg",
            "uploadDataWithoutURL originals/u1/followers/o1.jpg",
            "deleteImage originals/u1/public/o1.jpg",
            "deleteImage posts/u1/public/e1.jpg",
        ], "1 つ目の削除が失敗しても 2 つ目を消す・写した先は消さない")
        XCTAssertEqual(result.images.map(\.storagePath), ["originals/u1/followers/o1.jpg"])
    }

    // MARK: - 同じフォルダのまま（写さない）

    /// 同じフォルダで公開以外：E の前に書かれた古い URL が残っていたら "" にするだけで、写さない
    func testSameFolderNonPublicClearsOldURLWithoutMoving() async throws {
        let (vm, storage) = makeViewModel(
            oldVisibility: .followers,
            newVisibility: .followers,
            originals: [original(url: "https://fake-storage.test/originals/u1/followers/o1.jpg", storagePath: "originals/u1/followers/o1.jpg")]
        )

        let relocated = try await vm.relocateOriginalImagesForEditing()

        let result = try XCTUnwrap(relocated)
        XCTAssertEqual(storage.calls, [], "写さない・消さない")
        XCTAssertEqual(result.images, [
            ImageInfo(url: "", width: 400, height: 300, order: 0, storagePath: "originals/u1/followers/o1.jpg"),
        ])
        XCTAssertEqual(result.oldPathsToDelete, [])
    }

    /// 同じフォルダで公開：URL が空なら取って書く（写さない）
    func testSameFolderPublicFetchesMissingURL() async throws {
        let (vm, storage) = makeViewModel(
            oldVisibility: .public,
            newVisibility: .public,
            originals: [original(url: "", storagePath: "originals/u1/public/o1.jpg")]
        )

        let relocated = try await vm.relocateOriginalImagesForEditing()

        let result = try XCTUnwrap(relocated)
        XCTAssertEqual(storage.calls, ["downloadURL originals/u1/public/o1.jpg"])
        XCTAssertEqual(result.images, [
            ImageInfo(
                url: "https://fake-storage.test/originals/u1/public/o1.jpg",
                width: 400,
                height: 300,
                order: 0,
                storagePath: "originals/u1/public/o1.jpg"
            ),
        ])
        XCTAssertEqual(result.oldPathsToDelete, [])
    }

    // MARK: - 見張り役（本物に替えても変わらないこと）

    /// 公開 → 公開（URL あり）：何もしない
    func testPublicToPublicKeepsOriginalsAsIs() async throws {
        let (vm, storage) = makeViewModel(
            oldVisibility: .public,
            newVisibility: .public,
            originals: [original(url: "https://fake-storage.test/originals/u1/public/o1.jpg", storagePath: "originals/u1/public/o1.jpg")]
        )

        let relocated = try await vm.relocateOriginalImagesForEditing()

        let result = try XCTUnwrap(relocated)
        XCTAssertEqual(storage.calls, [])
        XCTAssertEqual(result.images, [
            ImageInfo(
                url: "https://fake-storage.test/originals/u1/public/o1.jpg",
                width: 400,
                height: 300,
                order: 0,
                storagePath: "originals/u1/public/o1.jpg"
            ),
        ])
        XCTAssertEqual(result.oldPathsToDelete, [])
    }

    /// 原画像の無い投稿：何もせず nil を返す（createPost は今までどおり）
    func testNoOriginalImagesReturnsNil() async throws {
        let (vm, storage) = makeViewModel(oldVisibility: .public, newVisibility: .followers, originals: nil)

        let relocated = try await vm.relocateOriginalImagesForEditing()

        XCTAssertNil(relocated)
        XCTAssertEqual(storage.calls, [])
    }

    /// 持ち主が違う・置き場の形が分からない原画像：触らない
    func testOtherOwnerOrUnknownPathIsLeftAsIs() async throws {
        let (vm, storage) = makeViewModel(
            oldVisibility: .public,
            newVisibility: .followers,
            originals: [
                original(url: "https://fake-storage.test/originals/u2/public/o1.jpg", storagePath: "originals/u2/public/o1.jpg", order: 0),
                original(url: "https://e.com/o.jpg", storagePath: "originals/u1/o.jpg", order: 1),
            ]
        )

        let relocated = try await vm.relocateOriginalImagesForEditing()

        let result = try XCTUnwrap(relocated)
        XCTAssertEqual(storage.calls, [])
        XCTAssertEqual(result.images, [
            ImageInfo(
                url: "https://fake-storage.test/originals/u2/public/o1.jpg",
                width: 400,
                height: 300,
                order: 0,
                storagePath: "originals/u2/public/o1.jpg"
            ),
            ImageInfo(url: "https://e.com/o.jpg", width: 400, height: 300, order: 1, storagePath: "originals/u1/o.jpg"),
        ])
        XCTAssertEqual(result.oldPathsToDelete, [])
    }
}

// MARK: - Mock

/// 呼ばれた順に「操作 置き場」を記録する Storage の偽物（原画像を読む・写す・URL を取る・消す）
final class MockStorageServiceForRelocate: StorageServiceProtocol {
    /// 呼ばれた順の記録（例: "downloadData originals/u1/public/o1.jpg"）
    private(set) var calls: [String] = []
    /// 中身のまま上げたもの（置き場 → 中身）
    private(set) var uploadedData: [String: Data] = [:]
    /// 消すのに失敗させる置き場
    var failingDeletePaths: Set<String> = []

    func downloadData(path: String) async throws -> Data {
        calls.append("downloadData \(path)")
        // 中身は置き場から作る（写した先の中身をテストで直に書けるようにするため）
        return Data("中身:\(path)".utf8)
    }

    func uploadDataWithoutURL(_ data: Data, path: String) async throws {
        calls.append("uploadDataWithoutURL \(path)")
        uploadedData[path] = data
    }

    func downloadURL(path: String) async throws -> URL {
        calls.append("downloadURL \(path)")
        // テスト用の固定の文字列（置き場は英数字と / だけ）なので失敗しない
        return URL(string: "https://fake-storage.test/\(path)")!
    }

    func deleteImage(path: String) async throws {
        calls.append("deleteImage \(path)")
        if failingDeletePaths.contains(path) {
            throw FakeDeleteFailure()
        }
    }

    func uploadImage(_: UIImage, path _: String) async throws -> URL {
        fatalError("MockStorageServiceForRelocate.uploadImage はこのテストでは使いません")
    }

    func uploadThumbnail(_: UIImage, path _: String) async throws -> URL {
        fatalError("MockStorageServiceForRelocate.uploadThumbnail はこのテストでは使いません")
    }

    func uploadProgress(path _: String) -> AsyncStream<Double> {
        AsyncStream { $0.finish() }
    }
}

/// 消すのに失敗したことにする偽物のエラー
private struct FakeDeleteFailure: Error {}
