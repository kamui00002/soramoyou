//
//  AccountStorageCleaner.swift
//  Soramoyou
//
//  退会のときに、本人の Storage の写真とアイコン画像を消す ⭐️
//

import FirebaseStorage
import Foundation

// MARK: - AccountStorageClient

/// 退会の削除で使う Storage の操作
protocol AccountStorageClient: Sendable {
    /// 1 つのファイルを消す
    func delete(path: String) async throws
    /// フォルダの直下にあるファイルの置き場所を、全ページ分返す
    func listFiles(folder: String) async throws -> [String]
}

/// Firebase Storage を使う `AccountStorageClient`
/// - Storage は呼ばれたときに取りに行く（作った時点では触らない）
struct FirebaseAccountStorageClient: AccountStorageClient {
    func delete(path: String) async throws {
        try await Storage.storage().reference().child(path).delete()
    }

    /// `listAll()` は SDK の中で全ページを読み、ファイル（items）とフォルダ（prefixes）を返す。ファイルだけを使う
    func listFiles(folder: String) async throws -> [String] {
        try await Storage.storage().reference().child(folder).listAll().items.map(\.fullPath)
    }
}

// MARK: - AccountStoragePaths

/// 退会で消す Storage の置き場所を決める
enum AccountStoragePaths {
    /// 投稿の写真を置く 3 つの場所（本体・サムネイル・元画像）
    static let postRoots = ["posts", "thumbnails", "originals"]
    /// 公開範囲ごとのフォルダ
    static let visibilityFolders = ["public", "followers", "private"]

    /// アイコン画像の置き場所
    static func profileIcon(userId: String) -> String {
        "users/\(userId)/profile/profile.jpg"
    }

    /// 残り物を探す 10 個のフォルダ（投稿の写真の 9 個と、アイコンのフォルダ）
    static func leftoverFolders(userId: String) -> [String] {
        postRoots.flatMap { root in
            visibilityFolders.map { "\(root)/\(userId)/\($0)" }
        } + ["users/\(userId)/profile"]
    }

    /// 投稿の文書から、本人の投稿の写真の置き場所を集める
    /// - `images` の本体とサムネイル、`originalImages` の本体を集める
    /// - 置き場所が書かれていないときは、ダウンロード URL から取り出す
    /// - 本人の投稿の写真の形でない置き場所は外し、同じ置き場所は 1 つにまとめる
    static func postImagePaths(postData: [String: Any], userId: String) -> [String] {
        var candidates: [String] = []
        for image in imageDictionaries(postData["images"]) {
            candidates.append(contentsOf: [
                path(stored: image["storagePath"], url: image["url"]),
                path(stored: image["thumbnailStoragePath"], url: image["thumbnail"]),
            ].compactMap { $0 })
        }
        for image in imageDictionaries(postData["originalImages"]) {
            if let original = path(stored: image["storagePath"], url: image["url"]) {
                candidates.append(original)
            }
        }

        var seen = Set<String>()
        return candidates.filter { isOwnedPostImagePath($0, userId: userId) && seen.insert($0).inserted }
    }

    /// 置き場所が `{posts|thumbnails|originals}/{userId}/{public|followers|private}/{ファイル名}` の形かどうか
    static func isOwnedPostImagePath(_ path: String, userId: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 4
            && postRoots.contains(parts[0])
            && parts[1] == userId
            && visibilityFolders.contains(parts[2])
            && !parts[3].isEmpty
    }

    /// 文書の画像の配列を、辞書の配列として読む（形が合わない項目は外す）
    private static func imageDictionaries(_ value: Any?) -> [[String: Any]] {
        (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    /// 書かれた置き場所を返す。無ければダウンロード URL から取り出す
    private static func path(stored: Any?, url: Any?) -> String? {
        if let stored = stored as? String, !stored.isEmpty {
            return stored
        }
        guard let text = url as? String, let downloadURL = URL(string: text) else {
            return nil
        }
        return StorageService.storagePathFromDownloadURL(downloadURL)
    }
}

// MARK: - AccountStorageCleaner

/// 退会のときに、本人の Storage のファイルを消す ⭐️
/// - ファイルが無い（not found）ときは、消せたものとして扱う
/// - ほかの失敗があっても同じ段のファイルは全部試し、最後に最初の失敗を投げる
/// - 同時に消すファイルの数と、1 つの操作（削除・フォルダの一覧）を待つ時間に上限を付ける
struct AccountStorageCleaner: Sendable {
    /// 同時に消すファイルの数の上限
    static let defaultMaxConcurrent = 8
    /// 1 つの操作を待つ時間の上限
    static let defaultTimeout: Duration = .seconds(30)

    private let client: AccountStorageClient
    private let maxConcurrent: Int
    private let timeout: Duration

    init(
        client: AccountStorageClient = FirebaseAccountStorageClient(),
        maxConcurrent: Int = AccountStorageCleaner.defaultMaxConcurrent,
        timeout: Duration = AccountStorageCleaner.defaultTimeout
    ) {
        self.client = client
        self.maxConcurrent = max(1, maxConcurrent)
        self.timeout = timeout
    }

    /// 投稿の文書に書かれた写真（本体・サムネイル・元画像）を消す
    /// - Parameters:
    ///   - postData: 本人の投稿の文書の中身
    ///   - userId: 本人のユーザー ID
    func deletePostImages(postData: [[String: Any]], userId: String) async throws {
        var seen = Set<String>()
        let paths = postData
            .flatMap { AccountStoragePaths.postImagePaths(postData: $0, userId: userId) }
            .filter { seen.insert($0).inserted }
        try await deleteFiles(paths)
    }

    /// アイコン画像を消す
    func deleteProfileIcon(userId: String) async throws {
        try await deleteFiles([AccountStoragePaths.profileIcon(userId: userId)])
    }

    /// 10 個のフォルダを 1 つずつ一覧して、残っているファイルを消す
    /// - 一覧や削除に失敗したフォルダがあっても残りのフォルダは全部試し、最後に最初の失敗を投げる
    func deleteLeftovers(userId: String) async throws {
        var firstError: Error?
        for folder in AccountStoragePaths.leftoverFolders(userId: userId) {
            let paths: [String]
            do {
                paths = try await withTimeout { try await client.listFiles(folder: folder) }
            } catch {
                firstError = firstError ?? AccountStorageCleanerError.listFailed(folder: folder, underlying: error)
                continue
            }
            do {
                try await deleteFiles(paths)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    /// ファイルをまとめて消す
    /// - 同時に消すのは `maxConcurrent` 本まで。1 本終わるたびに次の 1 本を始める
    /// - 全部試したあと、失敗があれば最初の失敗を投げる
    func deleteFiles(_ paths: [String]) async throws {
        var firstError: Error?
        var nextIndex = 0
        await withTaskGroup(of: Error?.self) { group in
            // 最初に上限の本数だけ始める
            while nextIndex < min(maxConcurrent, paths.count) {
                let path = paths[nextIndex]
                group.addTask { await deleteOne(path) }
                nextIndex += 1
            }
            // 1 本終わるたびに結果を受け取り、残りがあれば次を始める
            while let result = await group.next() {
                if let error = result, firstError == nil {
                    firstError = error
                }
                if nextIndex < paths.count {
                    let path = paths[nextIndex]
                    group.addTask { await deleteOne(path) }
                    nextIndex += 1
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    /// エラーが「ファイルが無い」を表すかどうか
    static func isNotFound(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == StorageErrorDomain
            && nsError.code == StorageErrorCode.objectNotFound.rawValue
    }

    /// 1 つのファイルを消す。消せたか、もともと無かったときは nil を返し、ほかの失敗はエラーを返す
    private func deleteOne(_ path: String) async -> Error? {
        do {
            try await withTimeout { try await client.delete(path: path) }
            return nil
        } catch {
            if Self.isNotFound(error) {
                return nil
            }
            return AccountStorageCleanerError.deleteFailed(path: path, underlying: error)
        }
    }

    /// 操作の返事を `timeout` まで待つ。過ぎたら `AccountStorageCleanerError.timedOut` を投げる
    /// - 操作と時計を別々の Task で動かし、先に終わった方の結果を 1 回だけ返す
    /// - 時間切れのあとも操作の Task は止めない（返事は捨てる）
    private func withTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let timer = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                once.resume(with: .failure(AccountStorageCleanerError.timedOut))
            }
            Task {
                defer { timer.cancel() }
                do {
                    try await once.resume(with: .success(operation()))
                } catch {
                    once.resume(with: .failure(error))
                }
            }
        }
    }
}

// MARK: - ResumeOnce

/// continuation を 1 回だけ再開する
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// 最初の呼び出しだけ continuation を再開する。2 回目以降は何もしない
    func resume(with result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

// MARK: - AccountStorageCleanerError

/// 退会の Storage の削除の失敗
/// - 画面に出す文には置き場所（ユーザー ID を含む）を入れない
enum AccountStorageCleanerError: LocalizedError {
    /// 待つ時間の上限を過ぎた
    case timedOut
    /// ファイルを消せなかった
    case deleteFailed(path: String, underlying: Error)
    /// フォルダを一覧できなかった
    case listFailed(folder: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "時間内に応答がありませんでした"
        case .deleteFailed:
            "写真またはアイコン画像を削除できませんでした"
        case .listFailed:
            "写真の一覧を取得できませんでした"
        }
    }
}
