//
//  AccountStorageCleanerTests.swift
//  SoramoyouTests
//
//  退会で本人の Storage の写真とアイコン画像を消す処理のテスト ⭐️
//

@testable import Soramoyou
import XCTest

final class AccountStorageCleanerTests: XCTestCase {
    private let uid = "user-a"

    /// Firebase Storage SDK 12.6.0 の「ファイルが無い」エラー（FIRStorageErrorDomain・-13010）
    private var notFoundError: NSError {
        NSError(domain: "FIRStorageErrorDomain", code: -13010)
    }

    /// Firebase Storage SDK 12.6.0 の「権限が無い」エラー（FIRStorageErrorDomain・-13021）
    private var unauthorizedError: NSError {
        NSError(domain: "FIRStorageErrorDomain", code: -13021)
    }

    // MARK: - 置き場所を集める

    func testPostImagePathsCollectsStoredPaths() {
        // 本体・サムネイル・元画像の置き場所を、文書に書かれたとおりに集める
        let image: [String: Any] = [
            "url": "",
            "width": 1, "height": 1, "order": 0,
            "storagePath": "posts/user-a/private/p1.jpg",
            "thumbnailStoragePath": "thumbnails/user-a/private/p1_thumb.jpg",
        ]
        let original: [String: Any] = [
            "url": "",
            "width": 1, "height": 1, "order": 0,
            "storagePath": "originals/user-a/private/o1.jpg",
        ]
        let post: [String: Any] = ["images": [image], "originalImages": [original]]

        XCTAssertEqual(
            AccountStoragePaths.postImagePaths(postData: post, userId: uid),
            [
                "posts/user-a/private/p1.jpg",
                "thumbnails/user-a/private/p1_thumb.jpg",
                "originals/user-a/private/o1.jpg",
            ]
        )
    }

    func testPostImagePathsReadsDownloadURLWhenPathIsMissing() {
        // 置き場所が書かれていない文書は、ダウンロード URL から置き場所を取り出す
        let image: [String: Any] = [
            "url": "https://firebasestorage.googleapis.com/v0/b/bucket/o/posts%2Fuser-a%2Fpublic%2Fp2.jpg?alt=media&token=t",
            "thumbnail": "https://firebasestorage.googleapis.com/v0/b/bucket/o/thumbnails%2Fuser-a%2Fpublic%2Fp2_thumb.jpg?alt=media&token=t",
            "width": 1, "height": 1, "order": 0,
        ]
        let post: [String: Any] = ["images": [image]]

        XCTAssertEqual(
            AccountStoragePaths.postImagePaths(postData: post, userId: uid),
            ["posts/user-a/public/p2.jpg", "thumbnails/user-a/public/p2_thumb.jpg"]
        )
    }

    func testPostImagePathsDropsPathsThatAreNotOwnPostImages() {
        // ほかの人の置き場所・投稿の写真ではない置き場所・形の違う置き場所は集めない
        let paths = [
            "posts/user-b/public/x.jpg",
            "users/user-a/profile/profile.jpg",
            "posts/user-a/secret/x.jpg",
            "posts/user-a/public",
            "posts/user-a/public/a/b.jpg",
            "posts/user-a/public/",
        ]
        let images: [[String: Any]] = paths.map { path -> [String: Any] in
            ["url": "", "width": 1, "height": 1, "order": 0, "storagePath": path]
        }
        let post: [String: Any] = ["images": images]

        XCTAssertEqual(AccountStoragePaths.postImagePaths(postData: post, userId: uid), [])
    }

    func testPostImagePathsRemovesDuplicates() {
        // 同じ置き場所が 2 回書かれていても 1 回だけ集める
        let image: [String: Any] = [
            "url": "", "width": 1, "height": 1, "order": 0,
            "storagePath": "posts/user-a/public/p3.jpg",
        ]
        let post: [String: Any] = ["images": [image, image]]

        XCTAssertEqual(
            AccountStoragePaths.postImagePaths(postData: post, userId: uid),
            ["posts/user-a/public/p3.jpg"]
        )
    }

    func testLeftoverFoldersAreTheTenLeafFolders() {
        // 残り物を探すのは、投稿の写真の 9 個のフォルダとアイコンのフォルダ
        XCTAssertEqual(
            AccountStoragePaths.leftoverFolders(userId: uid),
            [
                "posts/user-a/public", "posts/user-a/followers", "posts/user-a/private",
                "thumbnails/user-a/public", "thumbnails/user-a/followers", "thumbnails/user-a/private",
                "originals/user-a/public", "originals/user-a/followers", "originals/user-a/private",
                "users/user-a/profile",
            ]
        )
    }

    func testProfileIconPath() {
        XCTAssertEqual(AccountStoragePaths.profileIcon(userId: uid), "users/user-a/profile/profile.jpg")
    }

    // MARK: - 消す

    func testNotFoundCountsAsDeleted() async throws {
        // ファイルが無いときは、消せたものとして扱う
        let fake = FakeAccountStorageClient()
        fake.deleteErrors = ["posts/user-a/public/p1.jpg": notFoundError]

        try await makeCleaner(fake).deleteFiles(["posts/user-a/public/p1.jpg"])

        XCTAssertEqual(fake.attempted, ["posts/user-a/public/p1.jpg"])
    }

    func testOtherFailureTriesEveryFileThenThrows() async {
        // ほかの失敗があっても同じ段のファイルは全部試し、最後に失敗を投げる
        let paths = ["posts/user-a/public/a.jpg", "posts/user-a/public/b.jpg", "posts/user-a/public/c.jpg"]
        let fake = FakeAccountStorageClient()
        fake.deleteErrors = ["posts/user-a/public/b.jpg": unauthorizedError]

        do {
            try await makeCleaner(fake).deleteFiles(paths)
            XCTFail("権限が無い失敗を投げるはず")
        } catch {
            guard case AccountStorageCleanerError.deleteFailed = error else {
                return XCTFail("deleteFailed を投げるはず: \(error)")
            }
        }
        XCTAssertEqual(fake.attempted.sorted(), paths)
    }

    func testDeletesAtMostMaxConcurrentFilesAtOnce() async throws {
        // 同時に消すファイルの数は上限まで
        let paths = (0 ..< 10).map { "posts/user-a/public/\($0).jpg" }
        let fake = FakeAccountStorageClient()
        fake.deleteDelay = .milliseconds(20)

        try await makeCleaner(fake, maxConcurrent: 3).deleteFiles(paths)

        XCTAssertEqual(fake.attempted.sorted(), paths.sorted())
        XCTAssertLessThanOrEqual(fake.maxRunning, 3)
    }

    func testDeleteThatDoesNotAnswerTimesOut() async {
        // 返事の無い削除は、待つ時間の上限で打ち切って失敗にする
        // （偽物はキャンセルされても止まり続け、3 秒後にだけ返事をする）
        let path = "posts/user-a/public/slow.jpg"
        let fake = FakeAccountStorageClient()
        fake.hangingPaths = [path]
        Task {
            try? await Task.sleep(for: .seconds(3))
            fake.releaseHanging()
        }
        let start = ContinuousClock.now

        do {
            try await makeCleaner(fake, timeout: .milliseconds(100)).deleteFiles([path])
            XCTFail("時間切れを投げるはず")
        } catch {
            guard case let AccountStorageCleanerError.deleteFailed(_, underlying) = error,
                  case AccountStorageCleanerError.timedOut = underlying
            else {
                return XCTFail("deleteFailed（timedOut）を投げるはず: \(error)")
            }
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testDeletePostImagesDeletesPathsFromEveryPost() async throws {
        // 全部の投稿の文書から集めた置き場所を消す
        let first: [String: Any] = [
            "url": "", "width": 1, "height": 1, "order": 0,
            "storagePath": "posts/user-a/public/a.jpg",
        ]
        let second: [String: Any] = [
            "url": "", "width": 1, "height": 1, "order": 0,
            "storagePath": "posts/user-a/followers/b.jpg",
            "thumbnailStoragePath": "thumbnails/user-a/followers/b_thumb.jpg",
        ]
        let posts: [[String: Any]] = [["images": [first]], ["images": [second]]]
        let fake = FakeAccountStorageClient()

        try await makeCleaner(fake).deletePostImages(postData: posts, userId: uid)

        XCTAssertEqual(
            Set(fake.attempted),
            ["posts/user-a/public/a.jpg", "posts/user-a/followers/b.jpg", "thumbnails/user-a/followers/b_thumb.jpg"]
        )
    }

    func testDeleteProfileIconDeletesTheIconPath() async throws {
        let fake = FakeAccountStorageClient()

        try await makeCleaner(fake).deleteProfileIcon(userId: uid)

        XCTAssertEqual(fake.attempted, ["users/user-a/profile/profile.jpg"])
    }

    func testLeftoversListsEachFolderOneByOneAndDeletesTheFiles() async throws {
        // 10 個のフォルダを 1 つずつ一覧して、見つかったファイルを消す
        let fake = FakeAccountStorageClient()
        fake.files = [
            "posts/user-a/private": ["posts/user-a/private/z.jpg"],
            "users/user-a/profile": ["users/user-a/profile/profile.jpg"],
        ]

        try await makeCleaner(fake).deleteLeftovers(userId: uid)

        XCTAssertEqual(fake.listedFolders, AccountStoragePaths.leftoverFolders(userId: uid))
        XCTAssertEqual(Set(fake.attempted), ["posts/user-a/private/z.jpg", "users/user-a/profile/profile.jpg"])
    }

    func testLeftoversListFailureStillListsOtherFoldersThenThrows() async {
        // 一覧に失敗したフォルダがあっても残りのフォルダは全部試し、最後に失敗を投げる
        let fake = FakeAccountStorageClient()
        fake.listErrors = ["posts/user-a/public": unauthorizedError]
        fake.files = ["users/user-a/profile": ["users/user-a/profile/profile.jpg"]]

        do {
            try await makeCleaner(fake).deleteLeftovers(userId: uid)
            XCTFail("一覧の失敗を投げるはず")
        } catch {
            guard case AccountStorageCleanerError.listFailed = error else {
                return XCTFail("listFailed を投げるはず: \(error)")
            }
        }
        XCTAssertEqual(fake.listedFolders, AccountStoragePaths.leftoverFolders(userId: uid))
        XCTAssertEqual(fake.attempted, ["users/user-a/profile/profile.jpg"])
    }

    // MARK: - Helpers

    private func makeCleaner(
        _ client: FakeAccountStorageClient,
        maxConcurrent: Int = AccountStorageCleaner.defaultMaxConcurrent,
        timeout: Duration = .seconds(5)
    ) -> AccountStorageCleaner {
        AccountStorageCleaner(client: client, maxConcurrent: maxConcurrent, timeout: timeout)
    }
}

// MARK: - FakeAccountStorageClient

/// 退会の Storage の削除のテスト用の偽物
/// - 試した削除と一覧を記録する
/// - 設定に合わせて、失敗・遅れ・返事をしない削除を返す
private final class FakeAccountStorageClient: AccountStorageClient, @unchecked Sendable {
    /// 削除で投げるエラー（置き場所ごと）
    var deleteErrors: [String: Error] = [:]
    /// 返事をしない削除の置き場所
    var hangingPaths: Set<String> = []
    /// 1 回の削除にかける時間
    var deleteDelay: Duration?
    /// 一覧で返すファイル（フォルダごと）
    var files: [String: [String]] = [:]
    /// 一覧で投げるエラー（フォルダごと）
    var listErrors: [String: Error] = [:]

    private let lock = NSLock()
    private var attemptedPaths: [String] = []
    private var listed: [String] = []
    private var running = 0
    private var peak = 0
    private var hanging: [CheckedContinuation<Void, Never>] = []

    /// 削除を試した置き場所
    var attempted: [String] { locked { attemptedPaths } }
    /// 一覧したフォルダ（順番どおり）
    var listedFolders: [String] { locked { listed } }
    /// 同時に動いていた削除の数の最大
    var maxRunning: Int { locked { peak } }

    func delete(path: String) async throws {
        locked {
            attemptedPaths.append(path)
            running += 1
            peak = max(peak, running)
        }
        defer { locked { running -= 1 } }

        if hangingPaths.contains(path) {
            await withCheckedContinuation { continuation in
                locked { hanging.append(continuation) }
            }
        }
        if let deleteDelay {
            try? await Task.sleep(for: deleteDelay)
        }
        if let error = deleteErrors[path] {
            throw error
        }
    }

    func listFiles(folder: String) async throws -> [String] {
        locked { listed.append(folder) }
        if let error = listErrors[folder] {
            throw error
        }
        return files[folder] ?? []
    }

    /// 返事をしていない削除に返事をする
    func releaseHanging() {
        let waiting = locked { () -> [CheckedContinuation<Void, Never>] in
            let all = hanging
            hanging = []
            return all
        }
        waiting.forEach { $0.resume() }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
