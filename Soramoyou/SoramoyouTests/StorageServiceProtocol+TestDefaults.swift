//
//  StorageServiceProtocol+TestDefaults.swift
//  SoramoyouTests
//
//  ⭐️ テスト target 専用: StorageServiceProtocol のメソッド追加時に
//  既存モック（MockStorageServiceForProfile 等）が一斉にコンパイルエラーを起こすのを
//  防ぐためのデフォルト実装（FirestoreServiceProtocol+TestDefaults と同方針）。
//
//  URL 側の C-3 で「上げるだけ」と downloadURL(path:) を足したときに作った。
//  各モックはテストで必要なメソッドだけ上書きすればよく、
//  未使用メソッドは `fatalError("unimplemented")` のデフォルトで満たす。
//

import Foundation
@testable import Soramoyou
import UIKit

extension StorageServiceProtocol {
    func uploadImageWithoutURL(_: UIImage, path _: String) async throws {
        fatalError("MockStorageService.uploadImageWithoutURL は未実装です")
    }

    func uploadThumbnailWithoutURL(_: UIImage, path _: String) async throws {
        fatalError("MockStorageService.uploadThumbnailWithoutURL は未実装です")
    }

    func downloadURL(path _: String) async throws -> URL {
        fatalError("MockStorageService.downloadURL は未実装です")
    }

    // URL 側の E（再編集で原画像を別のフォルダへ写す）で足した 2 つ
    func downloadData(path _: String) async throws -> Data {
        fatalError("MockStorageService.downloadData は未実装です")
    }

    func uploadDataWithoutURL(_: Data, path _: String) async throws {
        fatalError("MockStorageService.uploadDataWithoutURL は未実装です")
    }
}
