//
//  PostShareModelTests.swift ⭐️
//  SoramoyouTests
//
//  カードのシェアのボタンの判断（PostShareModel）のテスト。
//  1.18.0 PR-H「4: カードのシェアのボタンを動かす」
//
//  ⚠️ 期待値（読み方・文・件数）は 1 つずつ直に書く。`PostImageSource.resolve` を呼んで期待値を作ると、
//     実装と同じ式から作ることになり、式が間違っていても緑になるため。
//

@testable import Soramoyou
import UIKit
import XCTest

@MainActor
final class PostShareModelTests: XCTestCase {
    // MARK: - Helpers

    /// 画像 1 枚の投稿を作る
    private func makePost(image: ImageInfo) -> Post {
        Post(id: "p1", userId: "u1", images: [image])
    }

    /// 条件が満たされるまで 1ms ずつ待つ（上限 2 秒。LikeManagerTests と同じ形）
    /// - Returns: 条件が満たされたら true
    @discardableResult
    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        for _ in 0 ..< 2000 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("条件が満たされないまま待ち時間が尽きた", file: file, line: line)
        return false
    }

    // MARK: - Tests

    /// ① 公開の画像 → 本体の URL で取って共有シートを出し、計装を 1 件送る
    func testPublicImageDownloadsFullURLAndOpensShareSheet() async {
        let image = UIImage()
        let downloader = PostShareDownloaderStub(image: image)
        let logger = PostShareEventLoggerStub()
        let model = PostShareModel(downloader: downloader, logger: logger)
        let post = makePost(image: ImageInfo(
            url: "http://127.0.0.1:9199/v0/b/demo-soramoyou-security.appspot.com/o/posts%2Fu1%2Fpublic%2Fa.jpg?alt=media&token=t1",
            thumbnail: "https://example.com/public-thumb.jpg",
            width: 100,
            height: 100,
            order: 0,
            storagePath: "posts/u1/public/a.jpg",
            thumbnailStoragePath: "thumbnails/u1/public/a.jpg"
        ))

        await model.share(post: post, source: "home_card")

        XCTAssertEqual(
            downloader.receivedSources,
            [.remote(URL(string: "http://127.0.0.1:9199/v0/b/demo-soramoyou-security.appspot.com/o/posts%2Fu1%2Fpublic%2Fa.jpg?alt=media&token=t1")!)],
            "公開の画像は本体の URL で 1 回だけ取る（サムネイルの URL ではない）"
        )
        XCTAssertEqual(model.shareImages.count, 1)
        XCTAssertTrue(model.shareImages.first === image, "取ってきた画像をそのまま共有シートに渡す")
        XCTAssertTrue(model.isShareSheetPresented)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isPreparing, "終わったらくるくるを下ろす")
        XCTAssertEqual(logger.events.count, 1)
        XCTAssertEqual(logger.events.first?.name, "post_share_sheet_opened")
        XCTAssertEqual(logger.events.first?.parameters?["source"] as? String, "home_card")
    }

    /// ② フォロワー限定の画像 → 本体の Storage のパスで取る（URL が残っていても URL では読まない・サムネイルのパスでもない）
    func testFollowersImageDownloadsFullStoragePath() async {
        let downloader = PostShareDownloaderStub(image: UIImage())
        let model = PostShareModel(downloader: downloader, logger: PostShareEventLoggerStub())
        let post = makePost(image: ImageInfo(
            url: "https://example.com/followers-full.jpg",
            thumbnail: "https://example.com/followers-thumb.jpg",
            width: 100,
            height: 100,
            order: 0,
            storagePath: "posts/u1/followers/b.jpg",
            thumbnailStoragePath: "thumbnails/u1/followers/b.jpg"
        ))

        await model.share(post: post, source: "profile_list")

        XCTAssertEqual(downloader.receivedSources, [.storage("posts/u1/followers/b.jpg")])
    }

    /// ③ 画像なし → 「共有する画像がありません」・取りに行かない・シートを出さない・計装を送らない
    func testNoImageShowsMessageWithoutDownloading() async {
        let downloader = PostShareDownloaderStub(image: UIImage())
        let logger = PostShareEventLoggerStub()
        let model = PostShareModel(downloader: downloader, logger: logger)
        let post = Post(id: "p1", userId: "u1", images: [])

        await model.share(post: post, source: "home_card")

        XCTAssertEqual(model.errorMessage, "共有する画像がありません")
        XCTAssertEqual(downloader.receivedSources.count, 0)
        XCTAssertFalse(model.isShareSheetPresented)
        XCTAssertEqual(logger.events.count, 0)
    }

    /// ④ 取るのに失敗 → 失敗の文を出す・シートを出さない・計装を送らない・くるくるを下ろす
    ///
    /// 投げるエラーは `ImageDownloadError.downloadFailed`（本物の ImageDownloadService が権限の拒否・通信の失敗で投げるもの）。
    /// 文は ImageDownloadService.swift の errorDescription（`.downloadFailed` →「画像のダウンロードに失敗しました」）を、
    /// ErrorHandler.getUserFriendlyMessage が LocalizedError のときそのまま返す（ErrorHandler.swift の 103〜105 行目）。
    func testDownloadFailureShowsMessageAndDoesNotLog() async {
        let downloader = PostShareDownloaderStub(image: UIImage(), error: ImageDownloadError.downloadFailed)
        let logger = PostShareEventLoggerStub()
        let model = PostShareModel(downloader: downloader, logger: logger)
        let post = makePost(image: ImageInfo(
            url: "https://example.com/public-full.jpg",
            width: 100,
            height: 100,
            order: 0,
            storagePath: "posts/u1/public/a.jpg"
        ))

        await model.share(post: post, source: "tag_detail")

        XCTAssertEqual(model.errorMessage, "画像のダウンロードに失敗しました")
        XCTAssertFalse(model.isShareSheetPresented)
        XCTAssertTrue(model.shareImages.isEmpty)
        XCTAssertEqual(logger.events.count, 0, "失敗したときは計装を送らない")
        XCTAssertFalse(model.isPreparing, "失敗しても、くるくるを下ろす")
    }

    /// ⑤ source が nil（検索の画面のカード）→ 成功して計装を 1 件送り、parameters に source のキーが無い
    func testNilSourceLogsWithoutSourceKey() async {
        let downloader = PostShareDownloaderStub(image: UIImage())
        let logger = PostShareEventLoggerStub()
        let model = PostShareModel(downloader: downloader, logger: logger)
        let post = makePost(image: ImageInfo(
            url: "https://example.com/public-full.jpg",
            width: 100,
            height: 100,
            order: 0,
            storagePath: "posts/u1/public/a.jpg"
        ))

        await model.share(post: post, source: nil)

        XCTAssertTrue(model.isShareSheetPresented)
        XCTAssertEqual(logger.events.count, 1)
        XCTAssertEqual(logger.events.first?.name, "post_share_sheet_opened")
        XCTAssertNil(logger.events.first?.parameters?["source"], "source が無いときは source のキーを入れない")
    }

    /// ⑥ 取ってきている途中の 2 回目は何もしない → 取りに行くのは 1 回だけ・1 回目を進めると成功する
    func testSecondShareWhilePreparingIsIgnored() async {
        let downloader = PostShareDownloaderStub(image: UIImage(), holdsFirstDownload: true)
        let logger = PostShareEventLoggerStub()
        let model = PostShareModel(downloader: downloader, logger: logger)
        let post = makePost(image: ImageInfo(
            url: "https://example.com/public-full.jpg",
            width: 100,
            height: 100,
            order: 0,
            storagePath: "posts/u1/public/a.jpg"
        ))

        let firstShare = Task { await model.share(post: post, source: "home_card") }
        // 1 回目が画像を取りに行って「実際に止まった」ところまで待つ（上限 2 秒）。
        // 止まらなかったら、後の 2 回目が止まったままにならないよう先に止めるのを解いてから終える（固まらないため）。
        guard await waitUntil({ downloader.isHoldingDownload }) else {
            downloader.releaseHeldDownload()
            await firstShare.value
            return
        }
        XCTAssertTrue(model.isPreparing, "前提: 1 回目が画像を取ってきている途中")

        await model.share(post: post, source: "home_card") // 1 回目が終わる前の 2 回目
        XCTAssertEqual(downloader.receivedSources.count, 1, "取ってきている途中の 2 回目で、もう一度取りに行ってはいけない")

        downloader.releaseHeldDownload()
        await firstShare.value

        XCTAssertEqual(downloader.receivedSources.count, 1)
        XCTAssertTrue(model.isShareSheetPresented, "1 回目を進めると共有シートが出る")
        XCTAssertEqual(model.shareImages.count, 1)
        XCTAssertEqual(logger.events.count, 1)
        XCTAssertFalse(model.isPreparing)
    }
}

// MARK: - Stub

/// 画像の取り先の偽物（受け取った読み方を記録し、決めた画像を返すかエラーを投げる）
///
/// `ImageDownloadServiceProtocol` は Sendable。`@MainActor` のモデルから呼ばれても、この中の async は
/// main の外で走りうるので、記録と「止める／再開する」の受け渡しはロックで守る（LikeManagerTests の Mock と同じ形）。
private final class PostShareDownloaderStub: ImageDownloadServiceProtocol, @unchecked Sendable {
    /// 返す画像
    private let image: UIImage
    /// 投げるエラー（nil なら image を返す）
    private let error: Error?

    private let lock = NSLock()
    /// 受け取った読み方（受け取った順）
    private var receivedSourcesStorage: [PostImageSource] = []
    /// true なら、次の 1 回だけ `releaseHeldDownload()` まで止める（連打のテスト用）
    private var holdsNextDownload: Bool
    private var heldDownload: CheckedContinuation<Void, Never>?
    private var releaseRequested = false

    /// - Parameters:
    ///   - image: 返す画像
    ///   - error: 投げるエラー（nil なら image を返す）
    ///   - holdsFirstDownload: true なら、最初の 1 回だけ `releaseHeldDownload()` まで止める
    init(image: UIImage, error: Error? = nil, holdsFirstDownload: Bool = false) {
        self.image = image
        self.error = error
        holdsNextDownload = holdsFirstDownload
    }

    /// 受け取った読み方（受け取った順）
    var receivedSources: [PostImageSource] {
        lock.withLock { receivedSourcesStorage }
    }

    /// 取るのが実際に止まっているか
    var isHoldingDownload: Bool {
        lock.withLock { heldDownload != nil }
    }

    /// 止めていた取るのを再開する（まだ止まる前なら、止まらずに通すよう予約する）
    func releaseHeldDownload() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            releaseRequested = true
            defer { heldDownload = nil }
            return heldDownload
        }
        continuation?.resume()
    }

    func downloadImage(from source: PostImageSource) async throws -> UIImage {
        // ⚠️ 記録は止める・throw より前（止まっている間・失敗したときも「受け取った」ことを数える）
        let shouldHold: Bool = lock.withLock {
            receivedSourcesStorage.append(source)
            defer { holdsNextDownload = false }
            return holdsNextDownload
        }
        if shouldHold {
            await waitForRelease()
        }
        if let error {
            throw error
        }
        return image
    }

    /// releaseHeldDownload() が呼ばれるまで待つ
    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if releaseRequested { return true }
                heldDownload = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    // MARK: 使わないもの（呼ばれたら赤にする）

    func downloadImage(from _: String) async throws -> UIImage {
        XCTFail("シェアは URL の文字列版を使わない（PostImageSource 版を使う）")
        throw ImageDownloadError.invalidURL
    }

    func downloadImages(from _: [String]) async throws -> [UIImage] {
        XCTFail("シェアは複数枚を取らない")
        throw ImageDownloadError.invalidURL
    }

    func downloadAndSaveImages(from _: [String]) async throws -> Int {
        XCTFail("シェアは写真に保存しない")
        throw ImageDownloadError.invalidURL
    }

    func downloadImages(from _: [PostImageSource]) async throws -> [UIImage] {
        XCTFail("シェアは複数枚を取らない")
        throw ImageDownloadError.invalidURL
    }

    func downloadAndSaveImages(from _: [PostImageSource]) async throws -> Int {
        XCTFail("シェアは写真に保存しない")
        throw ImageDownloadError.invalidURL
    }

    func saveToPhotoLibrary(_: UIImage) async throws {
        XCTFail("シェアは写真に保存しない")
        throw ImageDownloadError.invalidURL
    }

    func saveToPhotoLibrary(_: [UIImage]) async throws {
        XCTFail("シェアは写真に保存しない")
        throw ImageDownloadError.invalidURL
    }

    func checkPhotoLibraryPermission() async -> Bool {
        XCTFail("シェアは写真の権限を見ない")
        return false
    }
}

/// シェアの計装を送らずに記録するだけの偽物
private final class PostShareEventLoggerStub: PostShareEventLogging {
    /// 送ったイベント 1 件
    struct Event {
        let name: String
        /// 渡された parameters そのまま（nil と空の辞書を区別しない確かめ方をするため、加工しない）
        let parameters: [String: Any]?
    }

    /// 送ったイベント（送った順）
    private(set) var events: [Event] = []

    func logEvent(_ name: String, parameters: [String: Any]?) {
        events.append(Event(name: name, parameters: parameters))
    }
}
