//
//  ExternalEditInfoTests.swift
//  SoramoyouTests
//
//  ⭐️ ExternalEditInfo の `exifCapturedAt`（元ファイル EXIF の撮影日時）を検証する。
//  - Firestore 往復（Timestamp で保存・復元）
//  - 旧形式（キー無し）ドキュメントとの後方互換
//  - `resolvedCapturedAt` の優先順位（EXIF → 写真ライブラリの作成日時 → nil）
//

import XCTest
import FirebaseFirestore
@testable import Soramoyou

final class ExternalEditInfoTests: XCTestCase {

    /// EXIF 由来の撮影日時（2026-03-16T07:30:00Z）
    private let exifDate = Date(timeIntervalSince1970: 1_773_646_200)
    /// 写真ライブラリの作成日時（EXIF より後＝保存時刻を模す）
    private let assetDate = Date(timeIntervalSince1970: 1_773_650_000)

    // MARK: - Firestore 往復

    func testFirestoreRoundTripKeepsExifCapturedAt() throws {
        let info = ExternalEditInfo(hasAdjustments: false, creationDate: assetDate, exifCapturedAt: exifDate)

        let data = info.toFirestoreData()
        XCTAssertTrue(data["exifCapturedAt"] is Timestamp, "Firestore には creationDate と同じく Timestamp で保存する")

        let restored = try XCTUnwrap(ExternalEditInfo(from: data))
        XCTAssertEqual(
            try XCTUnwrap(restored.exifCapturedAt).timeIntervalSince1970,
            exifDate.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(restored.creationDate).timeIntervalSince1970,
            assetDate.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testToFirestoreDataOmitsExifCapturedAtWhenNil() {
        let data = ExternalEditInfo(hasAdjustments: false, creationDate: assetDate).toFirestoreData()

        XCTAssertNil(data["exifCapturedAt"], "nil は省略し、旧ドキュメントと同じ形状を保つ")
    }

    // MARK: - 後方互換

    func testInitFromLegacyDocumentWithoutExifCapturedAt() throws {
        // 本 PR 以前に保存されたドキュメント（exifCapturedAt キーが無い）
        let legacy: [String: Any] = [
            "hasAdjustments": false,
            "isHDR": true,
            "creationDate": Timestamp(date: assetDate)
        ]

        let info = try XCTUnwrap(ExternalEditInfo(from: legacy))

        XCTAssertNil(info.exifCapturedAt)
        XCTAssertTrue(info.isHDR, "既存フィールドの復元は従来どおり")
        XCTAssertEqual(info.resolvedCapturedAt?.source, .asset, "EXIF が無ければ作成日時に補完する")
    }

    func testInitFromDocumentAcceptsDateValue() throws {
        // Timestamp ではなく Date が入っている場合も creationDate と同様に受け付ける
        let data: [String: Any] = ["hasAdjustments": false, "exifCapturedAt": exifDate]

        let info = try XCTUnwrap(ExternalEditInfo(from: data))

        XCTAssertEqual(info.exifCapturedAt, exifDate)
    }

    // MARK: - resolvedCapturedAt

    func testResolvedCapturedAtPrefersExifOverAsset() {
        let both = ExternalEditInfo(hasAdjustments: false, creationDate: assetDate, exifCapturedAt: exifDate)
        XCTAssertEqual(both.resolvedCapturedAt?.date, exifDate)
        XCTAssertEqual(both.resolvedCapturedAt?.source, .exif)

        let assetOnly = ExternalEditInfo(hasAdjustments: false, creationDate: assetDate)
        XCTAssertEqual(assetOnly.resolvedCapturedAt?.date, assetDate)
        XCTAssertEqual(assetOnly.resolvedCapturedAt?.source, .asset)

        let none = ExternalEditInfo(hasAdjustments: false)
        XCTAssertNil(none.resolvedCapturedAt)
    }
}
