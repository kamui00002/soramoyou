//
//  PostViewModelCapturedAtTests.swift
//  SoramoyouTests
//
//  ⭐️ 撮影日時（capturedAt / timeOfDay）が ExternalEditInfo（EXIF → PHAsset.creationDate）から
//  決まることと、createPost で単写真には付き・合成投稿（collage / panorama）には付かないことを検証する。
//  抽出は `setSelectedImages(_:externalEditInfos:)` が起動する Task で行われるため、
//  `imageInfoExtractionTask` を await して完了を待つ。
//

import XCTest
import UIKit
@testable import Soramoyou

@MainActor
final class PostViewModelCapturedAtTests: XCTestCase {

    /// EXIF 由来の撮影日時（2026-03-16T07:30:00Z）
    private let exifDate = Date(timeIntervalSince1970: 1_773_646_200)
    /// 写真ライブラリの作成日時（EXIF より後＝保存時刻を模す）
    private let assetDate = Date(timeIntervalSince1970: 1_773_650_000)

    /// 1×1 のダミー画像（抽出はモックが受けるので中身は問わない）
    private func dummyImage() -> UIImage {
        let size = CGSize(width: 1, height: 1)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// 画像解析と分類器をモックに差し替えた ViewModel。
    /// 実物の SkyTypeClassifier は Vision を使うため、テストを決定的・軽量に保つ目的で差し替える。
    private func makeViewModel() -> PostViewModel {
        PostViewModel(
            userId: "u1",
            imageService: MockImageService(),
            firestoreService: MockFirestoreService(),
            skyTypeClassifier: StubSkyTypeClassifier()
        )
    }

    /// 抽出 Task を起動し、完了まで待つ
    private func setImagesAndWait(_ vm: PostViewModel, externalEditInfos: [ExternalEditInfo?]) async {
        vm.setSelectedImages([dummyImage()], externalEditInfos: externalEditInfos)
        await vm.imageInfoExtractionTask?.value
    }

    // MARK: - 出所の優先順位

    func testExtractUsesExifCapturedAtWhenBothPresent() async throws {
        let vm = makeViewModel()
        await setImagesAndWait(vm, externalEditInfos: [
            ExternalEditInfo(hasAdjustments: false, creationDate: assetDate, exifCapturedAt: exifDate)
        ])

        let info = try XCTUnwrap(vm.extractedInfo)
        XCTAssertEqual(info.capturedAt, exifDate, "EXIF が写真ライブラリの作成日時より優先される")
        XCTAssertEqual(info.capturedAtSource, .exif)
        XCTAssertEqual(info.timeOfDay, TimeOfDay.from(date: exifDate))
    }

    func testExtractFallsBackToAssetCreationDate() async throws {
        let vm = makeViewModel()
        await setImagesAndWait(vm, externalEditInfos: [
            ExternalEditInfo(hasAdjustments: false, creationDate: assetDate)
        ])

        let info = try XCTUnwrap(vm.extractedInfo)
        XCTAssertEqual(info.capturedAt, assetDate, "EXIF が無ければ作成日時に補完する（スクリーンショット等）")
        XCTAssertEqual(info.capturedAtSource, .asset)
        XCTAssertEqual(info.timeOfDay, TimeOfDay.from(date: assetDate))
    }

    func testExtractWithoutExternalEditInfoHasNoCapturedAt() async throws {
        let vm = makeViewModel()
        await setImagesAndWait(vm, externalEditInfos: [])

        let info = try XCTUnwrap(vm.extractedInfo)
        XCTAssertNil(info.capturedAt)
        XCTAssertNil(info.timeOfDay)
        XCTAssertEqual(info.capturedAtSource, .none)
        // 撮影日時が無くても色・色温度の抽出は従来どおり完了している
        XCTAssertFalse(info.skyColors.isEmpty)
    }

    func testSkyTypeSelectionKeepsCapturedAtSource() async throws {
        let vm = makeViewModel()
        await setImagesAndWait(vm, externalEditInfos: [
            ExternalEditInfo(hasAdjustments: false, exifCapturedAt: exifDate)
        ])

        // 手動選択で extractedInfo が再構築されても出所（計装用）を落とさない
        vm.selectSkyType(.sunset)

        XCTAssertEqual(vm.extractedInfo?.skyType, .sunset)
        XCTAssertEqual(vm.extractedInfo?.capturedAtSource, .exif)
    }

    // MARK: - createPost

    private func uploadedImage() -> UploadedImage {
        UploadedImage(
            url: "https://e.com/s.jpg", thumbnail: "https://e.com/s_t.jpg",
            width: 800, height: 600, storagePath: "posts/u1/s.jpg", thumbnailStoragePath: "posts/u1/s_t.jpg"
        )
    }

    func testCreatePostSingleCarriesCapturedAtAndExifInExternalEditInfo() async throws {
        let vm = makeViewModel()
        vm.postKind = .single
        await setImagesAndWait(vm, externalEditInfos: [
            ExternalEditInfo(hasAdjustments: false, creationDate: assetDate, exifCapturedAt: exifDate)
        ])

        let post = try vm.createPost(imageURLs: [uploadedImage()], originalImageURLs: nil)

        XCTAssertEqual(post.capturedAt, exifDate)
        XCTAssertEqual(post.timeOfDay, TimeOfDay.from(date: exifDate))
        XCTAssertEqual(post.images[0].externalEditInfo?.exifCapturedAt, exifDate, "画像ごとに出所を後追いできるよう永続化する")
    }

    func testCreatePostCompositeDropsCapturedAt() async throws {
        // 合成画像は端末内生成で特定の素材 1 枚に紐づかないため、素材の撮影日時を付けない
        for kind in [PostKind.collage, PostKind.panorama] {
            let vm = makeViewModel()
            vm.postKind = kind
            await setImagesAndWait(vm, externalEditInfos: [
                ExternalEditInfo(hasAdjustments: false, creationDate: assetDate, exifCapturedAt: exifDate)
            ])
            // 合成投稿は抽出の時点で撮影日時を持たない＝画面表示・コーパス・計装に漏らさない
            // `capturedAtSource` は `CapturedAtSource?` に対する `.none` が Optional.none と
            // 曖昧になるため、XCTUnwrap で non-optional にしてから比較する（列挙の `.none` を指す）。
            let info = try XCTUnwrap(vm.extractedInfo)
            XCTAssertNil(info.capturedAt, "合成投稿は抽出の時点で撮影日時を持たない＝画面表示・コーパス・計装に漏らさない")
            XCTAssertEqual(info.capturedAtSource, .none, "合成投稿は抽出の時点で撮影日時を持たない＝画面表示・コーパス・計装に漏らさない")

            let post = try vm.createPost(imageURLs: [uploadedImage()], originalImageURLs: nil)

            XCTAssertNil(post.capturedAt, "\(kind) は撮影日時を付けない")
            XCTAssertNil(post.timeOfDay, "\(kind) は時間帯を付けない")
        }
    }

    // MARK: - capturedAtSourceForEvent（post_completed.captured_at_source の決定規則）

    /// `has_captured_at` の元になる保存値を起点にするため、
    /// 「保存値あり・抽出結果は出所を持つ」新規投稿では抽出結果の出所（exif）がそのまま出る。
    func testCapturedAtSourceForEventNewPostUsesExtractedExif() {
        let source = PostViewModel.capturedAtSourceForEvent(
            savedCapturedAt: exifDate,
            isReedit: false,
            extractedSource: .exif
        )
        XCTAssertEqual(source, .exif)
    }

    /// 出所が asset（写真ライブラリの作成日時に補完）でも、新規投稿ならそのまま出る。
    func testCapturedAtSourceForEventNewPostUsesExtractedAsset() {
        let source = PostViewModel.capturedAtSourceForEvent(
            savedCapturedAt: assetDate,
            isReedit: false,
            extractedSource: .asset
        )
        XCTAssertEqual(source, .asset)
    }

    /// 合成投稿の想定: 保存値が nil なら、抽出結果に出所があっても `.none` にする
    /// （`has_captured_at == false` と矛盾させない）。
    func testCapturedAtSourceForEventNilSavedValueIsAlwaysNone() {
        let source = PostViewModel.capturedAtSourceForEvent(
            savedCapturedAt: nil,
            isReedit: false,
            extractedSource: .exif
        )
        XCTAssertEqual(source, .none)
    }

    /// 再編集は抽出をやり直さないため、保存値があれば出所を `.preserved` にする
    /// （抽出結果が `.none` でも、保存値があるので `.none` にはしない）。
    func testCapturedAtSourceForEventReeditPreservesSource() {
        // `extractedSource:` の型は `CapturedAtSource?` なので `.none` は Optional.none と
        // 曖昧になる。ここでは列挙の `CapturedAtSource.none`（=「抽出結果はあるが出所なし」）を
        // 明示的に渡し、Optional.none（=「抽出結果自体が無い」）と区別する。
        let source = PostViewModel.capturedAtSourceForEvent(
            savedCapturedAt: exifDate,
            isReedit: true,
            extractedSource: CapturedAtSource.none
        )
        XCTAssertEqual(source, .preserved)
    }

    /// 再編集でも保存値が nil（元投稿が撮影日時を持たない）なら `.none`。
    func testCapturedAtSourceForEventReeditWithoutSavedValueIsNone() {
        let source = PostViewModel.capturedAtSourceForEvent(
            savedCapturedAt: nil,
            isReedit: true,
            extractedSource: nil
        )
        XCTAssertEqual(source, .none)
    }

    /// 保存値はあるのに抽出結果が nil（想定外の組み合わせ）でも、フォールバックで `.none` にする。
    func testCapturedAtSourceForEventNewPostWithNilExtractedSourceFallsBackToNone() {
        let source = PostViewModel.capturedAtSourceForEvent(
            savedCapturedAt: exifDate,
            isReedit: false,
            extractedSource: nil
        )
        XCTAssertEqual(source, .none)
    }
}

// MARK: - Stub SkyTypeClassifier

/// 常に `.clear` を返す分類器。抽出 Task を Vision 依存なしで完走させるためのスタブ。
private final class StubSkyTypeClassifier: SkyTypeClassifierProtocol {
    func classify(_: UIImage, timeOfDay: TimeOfDay?) async throws -> SkyTypeClassificationResult {
        SkyTypeClassificationResult(
            skyType: .clear,
            confidence: 1.0,
            dominantColors: [],
            usedTimeOfDay: timeOfDay != nil,
            details: "stub"
        )
    }
}
