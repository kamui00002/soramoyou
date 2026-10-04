//
//  SoratomoSkyServiceTests.swift
//  SoramoyouTests
//
//  そらとも投稿のサービス（SoratomoSkyService）の、Firestore に触らない部分のテスト ⭐️（tasks 11.2）
//
//  確かめるもの: 文書の項目 → SoratomoSky の変換と壊れた 1 件の読み飛ばし、続きの有無の判定、
//  投稿の作成で書く項目の組み立て（firestore.rules の isValidSoratomoSky に合わせた形）。
//  ⚠️ Firestore への実際の読み書き（トランザクションがオフラインで失敗して積まれないこと・
//     監視の isFromCache・count()）は、単体テストでは確かめられない。実機かシミュレータで確かめる。
//
//  項目名は、本番のコードの定数（SoratomoSkyService.Field）を使わず、文字列で書いている。
//  定数の打ち間違いを、テストで見つけるため（ルールの項目名と一致させる）。
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

final class SoratomoSkyServiceTests: XCTestCase {
    // MARK: - テスト用のデータ

    /// 作成日時（Firestore が返す Timestamp）
    private let createdAtTimestamp = Timestamp(seconds: 1_700_000_000, nanoseconds: 0)
    /// 上の Timestamp と同じ時刻
    private let createdAtDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// 正しい形の文書の項目
    private func validData() -> [String: Any] {
        [
            "authorId": "author1",
            "caption": "夕焼け",
            "width": 2048,
            "height": 1536,
            "createdAt": createdAtTimestamp,
        ]
    }

    /// 読み取った文書（パスは投稿 ID から作る）
    private func document(id: String, data: [String: Any]) -> SoratomoSkyService.SourceDocument {
        SoratomoSkyService.SourceDocument(id: id, path: "soratomoGroups/g1/skies/\(id)", data: data)
    }

    // MARK: - 文書 → SoratomoSky

    func testDecodeSkyReadsEveryField() throws {
        let sky = try SoratomoSkyService.decodeSky(id: "sky1", groupId: "g1", data: validData())
        XCTAssertEqual(
            sky,
            SoratomoSky(
                id: "sky1", groupId: "g1", authorId: "author1", caption: "夕焼け",
                pixelWidth: 2048, pixelHeight: 1536, createdAt: createdAtDate
            )
        )
    }

    func testDecodeSkyWithoutCaptionGivesNil() throws {
        var data = validData()
        data["caption"] = nil
        let sky = try SoratomoSkyService.decodeSky(id: "sky1", groupId: "g1", data: data)
        XCTAssertNil(sky.caption)
    }

    func testDecodeSkyThrowsMissingFieldForEachRequiredField() {
        for key in ["authorId", "width", "height", "createdAt"] {
            var data = validData()
            data[key] = nil
            XCTAssertThrowsError(
                try SoratomoSkyService.decodeSky(id: "sky1", groupId: "g1", data: data),
                "\(key) が無い文書は変換できない"
            ) { error in
                XCTAssertEqual(error as? SoratomoSkyService.DecodeError, .missingField(key))
            }
        }
    }

    func testDecodeSkyThrowsInvalidFieldForWrongTypesAndValues() {
        // (壊す項目, 壊した値)
        let cases: [(String, Any)] = [
            ("authorId", ""), // 空の投稿者
            ("authorId", 123), // 文字列でない
            ("width", "2048"), // 数でない
            ("width", 0), // 0 以下（縦横比を計算できない）
            ("height", -1),
            ("createdAt", Date(timeIntervalSince1970: 0)), // Timestamp でない
            ("caption", 5), // あるのに文字列でない
        ]
        for (key, value) in cases {
            var data = validData()
            data[key] = value
            XCTAssertThrowsError(
                try SoratomoSkyService.decodeSky(id: "sky1", groupId: "g1", data: data),
                "\(key)=\(value) は変換できない"
            ) { error in
                XCTAssertEqual(error as? SoratomoSkyService.DecodeError, .invalidField(key))
            }
        }
    }

    // MARK: - 壊れた 1 件の読み飛ばし

    func testDecodeSkiesSkipsOnlyTheBrokenDocumentAndReportsItsPath() {
        var broken = validData()
        broken["width"] = nil
        let documents = [
            document(id: "a", data: validData()),
            document(id: "b", data: broken),
            document(id: "c", data: validData()),
        ]
        var failures: [SoratomoSkyService.DecodeFailure] = []

        let skies = SoratomoSkyService.decodeSkies(documents, groupId: "g1") { failures.append($0) }

        XCTAssertEqual(skies.map(\.id), ["a", "c"], "壊れた b だけが落ち、並び順は元のまま")
        XCTAssertEqual(failures.map(\.path), ["soratomoGroups/g1/skies/b"], "壊れた文書のパスが残る")
        XCTAssertEqual(failures.first?.error, .missingField("width"))
    }

    func testDecodeSkiesReportsNothingWhenEveryDocumentIsValid() {
        var failureCount = 0
        let skies = SoratomoSkyService.decodeSkies(
            [document(id: "a", data: validData())], groupId: "g1"
        ) { _ in failureCount += 1 }
        XCTAssertEqual(skies.count, 1)
        XCTAssertEqual(failureCount, 0)
    }

    // MARK: - 続きの有無

    func testMayHaveMoreIsTrueWhenCountReachesLimit() {
        XCTAssertTrue(SoratomoSkyService.mayHaveMore(documentCount: 20, limit: 20))
        XCTAssertFalse(SoratomoSkyService.mayHaveMore(documentCount: 19, limit: 20))
        XCTAssertFalse(SoratomoSkyService.mayHaveMore(documentCount: 0, limit: 20))
    }

    func testTimelineSnapshotCountsReadDocumentsNotDecodedOnes() {
        // 3 件読んで 1 件が壊れていても、上限（3）に達しているので続きがありうる。
        // 変換後の件数（2）で判定すると「もう無い」になり、無限スクロールが止まってしまう
        var broken = validData()
        broken["height"] = nil
        let documents = [
            document(id: "a", data: validData()),
            document(id: "b", data: broken),
            document(id: "c", data: validData()),
        ]

        let snapshot = SoratomoSkyService.makeTimelineSnapshot(
            documents: documents, groupId: "g1", limit: 3, isFromCache: false
        ) { _ in }

        XCTAssertEqual(snapshot.skies.count, 2)
        XCTAssertTrue(snapshot.mayHaveMore)
    }

    func testTimelineSnapshotIsNotMoreWhenBelowLimit() {
        let snapshot = SoratomoSkyService.makeTimelineSnapshot(
            documents: [document(id: "a", data: validData())], groupId: "g1", limit: 20, isFromCache: false
        ) { _ in }
        XCTAssertFalse(snapshot.mayHaveMore)
    }

    func testTimelineSnapshotPassesIsFromCacheThrough() {
        for isFromCache in [true, false] {
            let snapshot = SoratomoSkyService.makeTimelineSnapshot(
                documents: [], groupId: "g1", limit: 20, isFromCache: isFromCache
            ) { _ in }
            XCTAssertEqual(snapshot.isFromCache, isFromCache)
        }
    }

    // MARK: - 監視の件数の上限と文書 ID

    func testEffectiveLimitIsAtLeastOne() {
        XCTAssertEqual(SoratomoSkyService.effectiveLimit(20), 20)
        XCTAssertEqual(SoratomoSkyService.effectiveLimit(60), 60)
        // Firestore の limit(to:) は 0 以下で例外になる
        XCTAssertEqual(SoratomoSkyService.effectiveLimit(0), 1)
        XCTAssertEqual(SoratomoSkyService.effectiveLimit(-5), 1)
    }

    func testIsUsableDocumentIdRejectsEmptyAndSlash() {
        XCTAssertTrue(SoratomoSkyService.isUsableDocumentId("AbC123xyz"))
        XCTAssertFalse(SoratomoSkyService.isUsableDocumentId(""))
        XCTAssertFalse(SoratomoSkyService.isUsableDocumentId("a/b"))
    }

    // MARK: - 投稿の作成で書く項目

    func testCreateFieldsHasExactlyTheFiveRuleKeysWithCaption() {
        let fields = SoratomoSkyService.makeCreateFields(for: draft(caption: "夕焼け"))
        // firestore.rules の hasOnly(['authorId','caption','width','height','createdAt'])
        XCTAssertEqual(Set(fields.keys), ["authorId", "caption", "width", "height", "createdAt"])
    }

    func testCreateFieldsIncludesCaptionWhenPresent() {
        let fields = SoratomoSkyService.makeCreateFields(for: draft(caption: "夕焼け"))
        XCTAssertEqual(fields["caption"] as? String, "夕焼け")
    }

    func testCreateFieldsOmitsCaptionWhenNil() {
        let fields = SoratomoSkyService.makeCreateFields(for: draft(caption: nil))
        // 項目ごと省く（null も空文字も、ルールの isValidSoratomoCaption が拒否する）
        XCTAssertNil(fields["caption"])
        XCTAssertEqual(Set(fields.keys), ["authorId", "width", "height", "createdAt"])
    }

    func testCreateFieldsOmitsEmptyCaption() {
        let fields = SoratomoSkyService.makeCreateFields(for: draft(caption: ""))
        XCTAssertNil(fields["caption"])
    }

    func testCreateFieldsMapsDraftValuesToRuleNames() {
        let fields = SoratomoSkyService.makeCreateFields(for: draft(caption: nil))
        XCTAssertEqual(fields["authorId"] as? String, "author1")
        // アプリの pixelWidth / pixelHeight は、Firestore では width / height
        XCTAssertEqual(fields["width"] as? Int, 2048)
        XCTAssertEqual(fields["height"] as? Int, 1536)
    }

    func testCreateFieldsUsesServerTimestampForCreatedAt() {
        let fields = SoratomoSkyService.makeCreateFields(for: draft(caption: nil))
        // FieldValue.serverTimestamp() は共有の 1 つのインスタンスを返すので、同一かどうかで確かめられる。
        // 端末の時刻（Timestamp・Date）や別の FieldValue（delete など）だと、ルールの createdAt == request.time で拒否される
        XCTAssertTrue((fields["createdAt"] as? FieldValue) === FieldValue.serverTimestamp())
    }

    // MARK: - ヘルパー

    private func draft(caption: String?) -> SoratomoSkyDraft {
        SoratomoSkyDraft(
            groupId: "g1", skyId: "sky1", authorId: "author1", caption: caption,
            pixelWidth: 2048, pixelHeight: 1536
        )
    }
}
