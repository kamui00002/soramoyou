//
//  CameraCaptureServiceTests.swift ⭐️
//  SoramoyouTests
//
//  空カメラの撮影結果を本体へつなぐ部分（向きの焼き込み・ExternalEditInfo 生成・計装の写像）を
//  純関数の範囲で検証する。写真ライブラリ保存とセッションは実機・E2E の担当。
//

import XCTest
import SkyCamera
@testable import Soramoyou

final class CameraCaptureServiceTests: XCTestCase {

    // MARK: - Helpers

    /// 指定サイズ・指定 orientation のテスト画像を作る。
    private func makeImage(width: Int, height: Int, orientation: UIImage.Orientation) -> UIImage {
        let size = CGSize(width: width, height: height)
        // 画面倍率（iPhone 17 Pro は 3x）に引きずられないよう scale を 1 に固定する。
        // そうしないと cgImage のピクセル数が 3 倍になり、期待値と噛み合わない。
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let base = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        guard let cgImage = base.cgImage else {
            XCTFail("テスト画像の生成に失敗")
            return base
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }

    /// 撮影結果のダミー（純関数の検証用。photoData は使われない経路のみを対象にする）。
    private func makeCapture(
        shutterDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        gridEnabled: Bool = true,
        horizonEnabled: Bool = true,
        aeAfLocked: Bool = false,
        isLevel: Bool = true,
        rollDegrees: Double? = 0.4,
        usedDeferredStart: Bool = true
    ) -> SkyCameraCapture {
        SkyCameraCapture(
            photoData: Data(),
            metadata: [:],
            gridEnabled: gridEnabled,
            horizonEnabled: horizonEnabled,
            aeAfLocked: aeAfLocked,
            isLevel: isLevel,
            rollDegrees: rollDegrees,
            usedDeferredStart: usedDeferredStart,
            shutterDate: shutterDate
        )
    }

    // MARK: - 向きの焼き込み

    /// ⭐️ `.right`（縦撮りでよく出る）の画像は、ピクセルに向きを焼き込んで `.up` にする。
    ///    既存の resize / 空マスクが `.up` 前提のため、ここで揃えないと回転事故になる。
    func testBakeOrientationConvertsRightToUp() {
        // cgImage は 40x20。`.right` を付けると UIImage.size は幅高さが入れ替わって 20x40 になる。
        let rotated = makeImage(width: 40, height: 20, orientation: .right)
        XCTAssertEqual(rotated.imageOrientation, .right, "前提: 入力は .right")
        XCTAssertEqual(rotated.size, CGSize(width: 20, height: 40), "前提: .right では size が入れ替わる")

        let baked = CameraCaptureService.bakeOrientation(rotated)

        XCTAssertEqual(baked.imageOrientation, .up, "焼き込み後は必ず .up")
        XCTAssertEqual(baked.size, CGSize(width: 20, height: 40), "見た目の幅高さは変わらない")
        XCTAssertEqual(baked.cgImage?.width, 20, "ピクセル側も入れ替わっている（= 実際に回転済み）")
        XCTAssertEqual(baked.cgImage?.height, 40)
    }

    /// 既に `.up` の画像は作り直さない（無駄な再描画をしない）。
    func testBakeOrientationKeepsUpImageAsIs() {
        let upright = makeImage(width: 30, height: 10, orientation: .up)

        let baked = CameraCaptureService.bakeOrientation(upright)

        XCTAssertEqual(baked.imageOrientation, .up)
        XCTAssertEqual(baked.size, CGSize(width: 30, height: 10))
    }

    // MARK: - ExternalEditInfo

    /// 撮影直後は「未編集」で、撮影日時はシャッター時刻。
    /// ⚠️ EXIF 由来の撮影日時は別 PR（EXIF 経路の是正）の担当。ここでは足さない。
    func testExternalEditInfoFromCapture() {
        let shutterDate = Date(timeIntervalSince1970: 1_700_000_000)
        let info = CameraCaptureService.makeExternalEditInfo(from: makeCapture(shutterDate: shutterDate))

        XCTAssertEqual(info.creationDate, shutterDate, "creationDate はシャッター時刻")
        XCTAssertFalse(info.hasAdjustments, "撮ったばかりの写真は未編集")
        XCTAssertNil(info.formatIdentifier)
        XCTAssertFalse(info.isPanorama)
    }

    // MARK: - 計装の写像

    /// `camera_opened` は権限状態を snake_case で載せる。
    func testAnalyticsPayloadForOpened() {
        let payload = CameraCaptureService.analyticsPayload(for: .opened(authorization: .notDetermined))

        XCTAssertEqual(payload.name, "camera_opened")
        XCTAssertEqual(payload.parameters["authorization"] as? String, "not_determined")
    }

    /// 権限が許可済みのときの表記。
    func testAnalyticsPayloadForOpenedAuthorized() {
        let payload = CameraCaptureService.analyticsPayload(for: .opened(authorization: .authorized))

        XCTAssertEqual(payload.name, "camera_opened")
        XCTAssertEqual(payload.parameters["authorization"] as? String, "authorized")
    }

    /// 失敗はクラッシュしない不具合として別イベントで拾う。
    func testAnalyticsPayloadForFailed() {
        let payload = CameraCaptureService.analyticsPayload(for: .failed(reason: "configuration_failed"))

        XCTAssertEqual(payload.name, "camera_error")
        XCTAssertEqual(payload.parameters["reason"] as? String, "configuration_failed")
    }

    /// `camera_capture` の属性は Bool と整数のみ（PII なし）。
    func testCaptureParameters() {
        let capture = makeCapture(
            gridEnabled: true,
            horizonEnabled: false,
            aeAfLocked: true,
            isLevel: false,
            rollDegrees: 4.6,
            usedDeferredStart: true
        )

        let parameters = CameraCaptureService.captureParameters(capture: capture, savedToLibrary: false)

        XCTAssertEqual(parameters["grid_enabled"] as? Bool, true)
        XCTAssertEqual(parameters["horizon_enabled"] as? Bool, false)
        XCTAssertEqual(parameters["ae_af_locked"] as? Bool, true)
        XCTAssertEqual(parameters["is_level"] as? Bool, false)
        XCTAssertEqual(parameters["roll_deg"] as? Int, 5, "傾きは整数の度数へ丸める")
        XCTAssertEqual(parameters["saved_to_library"] as? Bool, false)
        XCTAssertEqual(parameters["deferred_start"] as? Bool, true)
    }

    /// 真上を向いていて傾きが取れなかった場合（nil）も属性は落とさず 0 にする。
    func testCaptureParametersWithUnknownRoll() {
        let parameters = CameraCaptureService.captureParameters(
            capture: makeCapture(rollDegrees: nil),
            savedToLibrary: true
        )

        XCTAssertEqual(parameters["roll_deg"] as? Int, 0)
        XCTAssertEqual(parameters["saved_to_library"] as? Bool, true)
    }

    // MARK: - photo_source

    /// 判定ゲートに使う属性値の写像（camera / library）。
    func testPhotoSourceRawValues() {
        XCTAssertEqual(PhotoSource.camera.rawValue, "camera")
        XCTAssertEqual(PhotoSource.library.rawValue, "library")
    }

    /// 合成投稿（配置写真・広角合成）は必ずライブラリ由来。
    /// `PostViewModel` の既定値が `.library` であることで担保されている。
    @MainActor
    func testCompositePostDefaultsToLibrarySource() {
        let viewModel = PostViewModel(userId: "test-user")
        viewModel.postKind = .panorama

        XCTAssertEqual(viewModel.photoSource, .library, "合成投稿は常に library")
        XCTAssertEqual(viewModel.photoSource.rawValue, "library")
    }
}
