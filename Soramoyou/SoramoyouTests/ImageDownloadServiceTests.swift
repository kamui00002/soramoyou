//
//  ImageDownloadServiceTests.swift
//  SoramoyouTests
//
//  投稿の画像を読み方（PostImageSource）から取る版（ImageDownloadService）のテスト ⭐️（URL 側の C・C-2 の土台）
//
//  - 期待する値（パス・キャッシュ・識別子）はここに直接書く（入力から作った値どうしを比べると、何もしない実装でも緑になるため）
//  - Kingfisher の retrieveImage は、渡した options を外から見せない。
//    → 読み先とキャッシュは `ImageDownloadService.storageRequest(for:)` で確かめる。
//    「downloadImage(from: PostImageSource) が storageRequest を使っていること」そのものは、テストで押さえられない（コードを読んで確かめる）
//  - Storage・ネットワークには行かない（実際に呼ぶのは、読みに行く前に止まる場合だけ）。
//    実際に取れるか・ルールに断られるかは手の確認（C-2 の 6）
//

import Kingfisher
@testable import Soramoyou
import XCTest

final class ImageDownloadServiceTests: XCTestCase {
    // MARK: - 部品

    /// 読み先が Storage のパスで読む提供元なら、そのパス（それ以外は nil）
    private func storagePath(of source: Source) -> String? {
        guard case let .provider(provider) = source else { return nil }
        return (provider as? PostStorageImageProvider)?.storagePath
    }

    // MARK: - Storage のパスで読むときの読み先と options（storageRequest）

    func testStorageRequestReadsByPathIntoDedicatedCache() {
        let request = ImageDownloadService.storageRequest(for: "originals/u1/followers/a.jpg")
        let options = KingfisherParsedOptionsInfo(request.options)

        // パスで読む（鍵はパスそのもの＝投稿詳細（KFImage.post）で入れた分がそのまま使える）。トークン付きの URL は持たない
        XCTAssertEqual(request.source.cacheKey, "originals/u1/followers/a.jpg")
        XCTAssertEqual(storagePath(of: request.source), "originals/u1/followers/a.jpg")
        XCTAssertNil(request.source.url)
        // 専用のキャッシュに入れる（付け忘れると標準のキャッシュに入り、サインアウトで消えない。取れた画像では見分けがつかない）
        XCTAssertIdentical(options.targetCache, PostStorageImageCache.shared, "専用のキャッシュが付いていない")
        // 加工を付けない（付けると鍵が「パス@加工の識別子」になる）。何もしない加工の識別子は空の文字列
        XCTAssertEqual(options.processor.identifier, "")
    }

    // MARK: - 読みに行く前に止まる場合

    func testUnavailableThrowsInvalidURLWithoutReading() async {
        // 読めないものは読みに行かず、URL 版で URL が空のときと同じエラー（「画像のURLが無効です」）
        do {
            _ = try await ImageDownloadService.shared.downloadImage(from: .unavailable)
            XCTFail("エラーにならなかった")
        } catch ImageDownloadError.invalidURL {
            // 期待どおり
        } catch {
            XCTFail("違うエラー: \(error)")
        }
    }

    func testRemoteGoesThroughSchemeCheckOfURLVersion() async {
        // 見張り役：公開の画像は今までの URL 版を通る（https/http 以外は読みに行かない）
        do {
            _ = try await ImageDownloadService.shared.downloadImage(from: .remote(URL(string: "file:///tmp/a.jpg")!))
            XCTFail("エラーにならなかった")
        } catch ImageDownloadError.unsafeURL {
            // 期待どおり
        } catch {
            XCTFail("違うエラー: \(error)")
        }
    }

    func testURLVersionAcceptsOnlyStorageImageURL() async {
        // URL 版は、決まり（StorageImageURL.live）に合う URL だけ読みに行く。
        // テスト中の決まりは Emulator（http・127.0.0.1:9199・demo-soramoyou-security.appspot.com）なので、ホストが localhost の URL は通さない
        do {
            _ = try await ImageDownloadService.shared.downloadImage(
                from: "http://localhost:9199/v0/b/demo-soramoyou-security.appspot.com/o/a.jpg"
            )
            XCTFail("エラーにならなかった")
        } catch ImageDownloadError.unsafeURL {
            // 期待どおり
        } catch {
            XCTFail("違うエラー: \(error)")
        }
    }

    func testDownloadImagesStopsAtUnavailable() async {
        // 再編集・「すべて保存」：読めない 1 枚があれば、そこで失敗する（URL 版で URL が空の 1 枚があるときと同じ）
        do {
            _ = try await ImageDownloadService.shared.downloadImages(from: [.unavailable])
            XCTFail("エラーにならなかった")
        } catch ImageDownloadError.invalidURL {
            // 期待どおり
        } catch {
            XCTFail("違うエラー: \(error)")
        }
    }

    func testNoSourcesThrowsNoImages() async {
        // 見張り役：空の配列は URL 版と同じ「保存する画像がありません」（写真ライブラリの許可を聞く前に止まる）
        do {
            _ = try await ImageDownloadService.shared.downloadImages(from: [PostImageSource]())
            XCTFail("downloadImages がエラーにならなかった")
        } catch ImageDownloadError.noImages {
            // 期待どおり
        } catch {
            XCTFail("downloadImages が違うエラー: \(error)")
        }

        do {
            _ = try await ImageDownloadService.shared.downloadAndSaveImages(from: [PostImageSource]())
            XCTFail("downloadAndSaveImages がエラーにならなかった")
        } catch ImageDownloadError.noImages {
            // 期待どおり
        } catch {
            XCTFail("downloadAndSaveImages が違うエラー: \(error)")
        }
    }
}
