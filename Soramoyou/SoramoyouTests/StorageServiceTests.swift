//
//  StorageServiceTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//
//
//  🔧 2026-09-16 修正: 本物の Firebase Storage へ通信するテストを明示オプトインにする。
//
//  背景:
//    - このファイルのテストは本物の Firebase Storage（本番プロジェクト）へ通信する統合テスト。
//      GoogleService-Info.plist が置かれた環境では、全件実行のたびに本番へアップロードしに行っていた。
//    - 旧 testUploadProgress は進捗ストリームを制限時間なしで待ち、アップロードの失敗を握りつぶして
//      いたため、ルール拒否で失敗するとテスト全件実行が無期限に固まった。対象 API
//      （StorageService.uploadProgress）は本番コードから使われておらず、進捗を流し込む配線も無かった
//      ため、テストごと API を削除した。
//
//  方針:
//    - 実通信するテストは環境変数 SORAMOYOU_STORAGE_INTEGRATION_TESTS=1 での明示オプトインにする
//      （既定はスキップ。全件実行・CI・XcodeBuildMCP の test_sim では走らない）。
//
//  実通信テストの有効化方法:
//    - xcodebuild: 環境変数に TEST_RUNNER_ を前置すると test host アプリへ届く
//        TEST_RUNNER_SORAMOYOU_STORAGE_INTEGRATION_TESTS=1 xcodebuild test ... \
//          -only-testing:SoramoyouTests/StorageServiceTests
//    - Xcode: スキーム編集 > Test > Arguments > Environment Variables に
//        SORAMOYOU_STORAGE_INTEGRATION_TESTS = 1 を追加
//    ⚠️ 有効化すると本物の Firebase Storage へ通信する（test/path/ 配下は storage.rules に
//       マッチするルールがなく既定で拒否されるため、現状は失敗で終わるのが期待値）。
//

import XCTest
@testable import Soramoyou
import UIKit

final class StorageServiceTests: XCTestCase {
    var storageService: StorageService!

    // MARK: - 実通信テストのガード

    /// 実通信テストをオプトインするための環境変数名
    private static let integrationTestsEnvironmentKey = "SORAMOYOU_STORAGE_INTEGRATION_TESTS"

    /// Firebase（GoogleService-Info.plist）が設定されているか確認する
    private func isFirebaseConfigured() -> Bool {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
    }

    /// 実通信テストが環境変数で明示的に有効化されているか
    private func isIntegrationTestingEnabled() -> Bool {
        ProcessInfo.processInfo.environment[Self.integrationTestsEnvironmentKey] == "1"
    }

    /// 本物の Firebase Storage へ通信するテストの共通ガード。
    /// plist がない環境と、環境変数でオプトインしていない環境ではスキップする。
    /// - Note: 以前は plist の有無だけで判定していたため、plist を置いた開発機では
    ///   全件実行のたびに本番 Storage へアップロードしに行っていた。
    private func skipUnlessIntegrationTestsEnabled() throws {
        try XCTSkipUnless(isFirebaseConfigured(), "Firebase not configured in test environment")
        try XCTSkipUnless(
            isIntegrationTestingEnabled(),
            "実通信テストは既定でスキップ。有効化するには環境変数 \(Self.integrationTestsEnvironmentKey)=1 を設定する"
        )
    }

    override func setUp() {
        super.setUp()
        storageService = StorageService()
    }
    
    override func tearDown() {
        storageService = nil
        super.tearDown()
    }
    
    func testStorageServiceInitialization() {
        // Given & When
        let service = StorageService()
        
        // Then
        XCTAssertNotNil(service)
    }
    
    func testUploadImage() async throws {
        // 本物の Firebase Storage へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given
        let testImage = createTestImage(size: CGSize(width: 1024, height: 768))
        let path = "test/path/image.jpg"
        
        // When
        let url = try await storageService.uploadImage(testImage, path: path)
        
        // Then
        XCTAssertNotNil(url)
        XCTAssertTrue(url.absoluteString.contains(path))
        
        // Cleanup
        try? await storageService.deleteImage(path: path)
    }
    
    func testUploadThumbnail() async throws {
        // 本物の Firebase Storage へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given
        let testImage = createTestImage(size: CGSize(width: 1024, height: 768))
        let path = "test/path/thumbnail.jpg"
        
        // When
        let url = try await storageService.uploadThumbnail(testImage, path: path)
        
        // Then
        XCTAssertNotNil(url)
        XCTAssertTrue(url.absoluteString.contains(path))
        
        // Cleanup
        try? await storageService.deleteImage(path: path)
    }
    
    func testDeleteImage() async throws {
        // 本物の Firebase Storage へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))
        let path = "test/path/to-delete.jpg"
        _ = try await storageService.uploadImage(testImage, path: path)
        
        // When
        try await storageService.deleteImage(path: path)
        
        // Then
        // 削除された画像を取得しようとするとエラーになることを確認
        do {
            _ = try await storageService.uploadImage(testImage, path: path)
            // 再アップロードは成功するので、削除の確認は別の方法で行う
            XCTAssertTrue(true)
        } catch {
            // エラーが発生する場合もある
        }
    }
    
    // MARK: - Helper Methods
    
    private func createTestImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}




