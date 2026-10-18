//
//  StorageServiceTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//
//
//  🔧 2026-09-16 修正: テスト全件実行が testUploadProgress で無期限に固まる不具合の再発防止。
//
//  背景:
//    - このファイルのテストは本物の Firebase Storage（本番プロジェクト）へ通信する統合テスト。
//      GoogleService-Info.plist が置かれた環境では、全件実行のたびに本番へアップロードしに行っていた。
//    - testUploadProgress は進捗ストリームを制限時間なしで待ち、アップロード Task の失敗を
//      握りつぶしていたため、未認証・ルール拒否で失敗するとストリームが終わらず永久に待った。
//    - さらに StorageService.uploadProgress(path:) は現状 uploadImage から進捗を流し込む経路が
//      配線されていない（setupProgressObserver の呼び出し元がない）ため、アップロードが成功しても
//      ストリームは終わらない。
//
//  方針:
//    1. 実通信するテストは環境変数 SORAMOYOU_STORAGE_INTEGRATION_TESTS=1 での明示オプトインにする
//       （既定はスキップ。全件実行・CI・XcodeBuildMCP の test_sim では走らない）。
//    2. 進捗待ちは上限時間付きにし、アップロード Task の失敗はテスト失敗として即座に抜ける。
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

    /// 進捗ストリームを待つ上限（これを超えたらテスト失敗として抜ける）
    private static let progressTimeout: Duration = .seconds(60)

    /// アップロード成功後、進捗ストリームの終了を待つ猶予
    /// （成功したのにストリームが終わらない＝進捗が配線されていない状態を検出する）
    private static let progressGraceAfterUpload: Duration = .seconds(5)

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
    
    func testUploadProgress() async throws {
        // 本物の Firebase Storage へ通信するため、明示オプトイン時のみ実行
        try skipUnlessIntegrationTestsEnabled()

        // Given
        let testImage = createTestImage(size: CGSize(width: 2048, height: 2048))
        let path = "test/path/progress.jpg"
        
        // When
        let progressStream = storageService.uploadProgress(path: path)
        
        // アップロードを開始し、結果（成功/失敗）を一度だけ流すストリームに載せる。
        // 旧実装は `Task { _ = try await ... }` で結果を捨てていたため、アップロードが失敗しても
        // テストは気付けず、進捗ストリームの終了を永久に待っていた。
        let (uploadOutcome, uploadOutcomeContinuation) = Self.makeUploadOutcomeStream()
        let service: StorageService = storageService
        let uploadTask = Task {
            let outcome: Result<URL, Error>
            do {
                outcome = .success(try await service.uploadImage(testImage, path: path))
            } catch {
                outcome = .failure(error)
            }
            uploadOutcomeContinuation.yield(outcome)
            uploadOutcomeContinuation.finish()
        }
        // 途中で抜けた場合もアップロード側の待ち（ダウンロード URL 取得のリトライ sleep 等）を早めに止める
        defer { uploadTask.cancel() }

        // Then
        // 進捗が0.0から1.0の間で更新されることを確認（上限時間付き・アップロード失敗で即抜け）
        let progressValues = try await Self.collectProgress(
            from: progressStream,
            uploadOutcome: uploadOutcome,
            timeout: Self.progressTimeout,
            graceAfterUpload: Self.progressGraceAfterUpload
        )
        
        XCTAssertFalse(progressValues.isEmpty)
        XCTAssertTrue(progressValues.contains { $0 >= 0.0 && $0 <= 1.0 })
        
        // Cleanup
        try? await storageService.deleteImage(path: path)
    }
    
    // MARK: - Helper Methods
    
    /// 進捗待ちで抜けた理由（テストの失敗メッセージに出す）
    private enum ProgressWaitError: LocalizedError {
        /// 上限時間を超えても進捗が 1.0 に達しなかった
        case timeout(Duration)
        /// アップロードは成功したのに、猶予時間内に進捗ストリームが終了しなかった
        case streamNotFinishedAfterUpload(Duration)

        var errorDescription: String? {
            switch self {
            case .timeout(let limit):
                return "進捗ストリームが \(limit) 以内に完了しなかった（アップロードも終わっていない）"
            case .streamNotFinishedAfterUpload(let grace):
                return "アップロードは成功したが、その後 \(grace) 待っても進捗ストリームが終了しなかった"
                    + "（StorageService.uploadProgress に進捗が流し込まれていない可能性）"
            }
        }
    }

    /// アップロード結果を一度だけ流すストリームと、その書き込み口を作る。
    /// - Note: `AsyncStream.makeStream` は iOS 17+ のため、iOS 16 でも使える初期化子で同等の組を作る
    ///   （初期化子の build クロージャは同期的に即時呼ばれるので continuation は必ず入る）。
    private static func makeUploadOutcomeStream()
        -> (AsyncStream<Result<URL, Error>>, AsyncStream<Result<URL, Error>>.Continuation) {
        var continuation: AsyncStream<Result<URL, Error>>.Continuation!
        let stream = AsyncStream<Result<URL, Error>> { continuation = $0 }
        return (stream, continuation)
    }

    /// 進捗ストリームを上限時間付きで収集する。次のいずれかが最初に起きた時点で抜ける:
    ///   1. 進捗が 1.0 に達した／ストリームが終了した → 収集した値を返す
    ///   2. アップロードが失敗した → そのエラーを投げる（握りつぶさない）
    ///   3. アップロードは成功したのに猶予時間内にストリームが終了しない → エラーを投げる
    ///   4. 上限時間を超えた → エラーを投げる
    /// - Note: 3 つの子タスクを競争させ、最初に終わった結果を採用して残りはキャンセルする。
    ///   子タスクはいずれも AsyncStream の for-await か Task.sleep で待つため、キャンセルで即座に抜ける
    ///   （`Task.value` を直接 await すると待つ側をキャンセルしても抜けられず、上限時間が SDK 任せになる）。
    private static func collectProgress(
        from progressStream: AsyncStream<Double>,
        uploadOutcome: AsyncStream<Result<URL, Error>>,
        timeout: Duration,
        graceAfterUpload: Duration
    ) async throws -> [Double] {
        try await withThrowingTaskGroup(of: [Double].self) { group in
            // 1. 進捗の収集（1.0 到達またはストリーム終了で戻る）
            group.addTask {
                var values: [Double] = []
                for await progress in progressStream {
                    values.append(progress)
                    if progress >= 1.0 {
                        break
                    }
                }
                return values
            }
            // 2./3. アップロード結果の監視（失敗なら即 throw、成功なら猶予後に throw）
            group.addTask {
                for await outcome in uploadOutcome {
                    switch outcome {
                    case .failure(let error):
                        throw error
                    case .success:
                        try await Task.sleep(for: graceAfterUpload)
                        throw ProgressWaitError.streamNotFinishedAfterUpload(graceAfterUpload)
                    }
                }
                // 値が来る前にストリームが終わるのはキャンセル時だけ。空配列で「勝って」しまわないよう投げる
                throw CancellationError()
            }
            // 4. 上限時間
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProgressWaitError.timeout(timeout)
            }

            // 最初に終わった子タスクの結果（成功値または例外）を採用し、残りは止める
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                return []
            }
            return first
        }
    }

    private func createTestImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}




