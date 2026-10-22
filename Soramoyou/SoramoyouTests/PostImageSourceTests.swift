//
//  PostImageSourceTests.swift
//  SoramoyouTests
//
//  投稿の画像を「URL で読むか・Storage のパスで読むか」の判定のテスト ⭐️（URL 側の C・C-1）
//
//  - 公開（パスの 3 つ目が public）のときだけ URL で読む
//  - それ以外は、URL が残っていても Storage のパスで読む（D-2 でトークンを消しても壊れないように）
//  - パスは storagePath（サムネイルは thumbnailStoragePath）を先に見る。無い古い投稿は URL から取り出す
//  期待する値は、ここにパスを直接書く（入力から作った値どうしを比べると、何もしない実装でも緑になるため）
//

@testable import Soramoyou
import XCTest

final class PostImageSourceTests: XCTestCase {
    // MARK: - 入力に使う URL（Firebase Storage のダウンロード URL の形）

    private let publicBodyURL = "https://firebasestorage.googleapis.com/v0/b/demo-bucket.appspot.com/o/posts%2Fu1%2Fpublic%2Fa.jpg?alt=media&token=t1"
    private let followersBodyURL = "https://firebasestorage.googleapis.com/v0/b/demo-bucket.appspot.com/o/posts%2Fu1%2Ffollowers%2Fa.jpg?alt=media&token=t2"
    private let privateBodyURL = "https://firebasestorage.googleapis.com/v0/b/demo-bucket.appspot.com/o/posts%2Fu1%2Fprivate%2Fa.jpg?alt=media&token=t3"
    private let publicThumbURL = "https://firebasestorage.googleapis.com/v0/b/demo-bucket.appspot.com/o/thumbnails%2Fu1%2Fpublic%2Fa_thumb.jpg?alt=media&token=t4"
    private let followersThumbURL = "https://firebasestorage.googleapis.com/v0/b/demo-bucket.appspot.com/o/thumbnails%2Fu1%2Ffollowers%2Fa_thumb.jpg?alt=media&token=t5"
    private let followersOriginalURL = "https://firebasestorage.googleapis.com/v0/b/demo-bucket.appspot.com/o/originals%2Fu1%2Ffollowers%2Fo.jpg?alt=media&token=t6"

    /// 判定に関係する 4 つだけを変えた画像の情報
    private func image(
        url: String,
        thumbnail: String? = nil,
        storagePath: String? = nil,
        thumbnailStoragePath: String? = nil
    ) -> ImageInfo {
        ImageInfo(
            url: url,
            thumbnail: thumbnail,
            width: 100,
            height: 100,
            order: 0,
            storagePath: storagePath,
            thumbnailStoragePath: thumbnailStoragePath
        )
    }

    // MARK: - 本体

    func testPublicBodyUsesURL() {
        // 公開は今までどおり URL で読む
        let info = image(url: publicBodyURL, storagePath: "posts/u1/public/a.jpg")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .remote(URL(string: publicBodyURL)!))
    }

    func testFollowersBodyUsesStoredPathEvenWithURL() {
        // フォロワー限定は、トークン付きの URL が残っていてもパスで読む
        let info = image(url: followersBodyURL, storagePath: "posts/u1/followers/a.jpg")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .storage("posts/u1/followers/a.jpg"))
    }

    func testPrivateBodyUsesStoredPathEvenWithURL() {
        // 非公開も同じ
        let info = image(url: privateBodyURL, storagePath: "posts/u1/private/a.jpg")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .storage("posts/u1/private/a.jpg"))
    }

    func testFollowersBodyWithEmptyURLUsesStoredPath() {
        // 新しい版が書く形（url は空・パスだけ）
        let info = image(url: "", storagePath: "posts/u1/followers/a.jpg")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .storage("posts/u1/followers/a.jpg"))
    }

    func testOldFollowersBodyWithoutStoredPathUsesPathFromURL() {
        // storagePath の無い古い投稿は、URL からパスを取り出して読む
        let info = image(url: followersBodyURL)
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .storage("posts/u1/followers/a.jpg"))
    }

    func testEmptyStoredPathIsTreatedAsMissing() {
        // 空の storagePath は無いのと同じ（URL から取り出す）
        let info = image(url: followersBodyURL, storagePath: "")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .storage("posts/u1/followers/a.jpg"))
    }

    func testStoredPathWinsOverPathInURL() {
        // storagePath と URL の中のパスが食い違うときは、storagePath を使う（URL の public を信じない）
        let info = image(url: publicBodyURL, storagePath: "posts/u1/followers/a.jpg")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .storage("posts/u1/followers/a.jpg"))
    }

    func testPublicPathWithEmptyURLUsesStoredPath() {
        // 公開のパスでも URL が空なら、パスで読む（公開のパスは誰でも読める）
        let info = image(url: "", storagePath: "posts/u1/public/a.jpg")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .storage("posts/u1/public/a.jpg"))
    }

    func testSegmentMustBeExactlyPublic() {
        // 3 つ目がちょうど public のときだけ URL（大文字・似た名前は公開扱いにしない）
        let info = image(url: publicBodyURL, storagePath: "posts/u1/Public/a.jpg")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .storage("posts/u1/Public/a.jpg"))
    }

    func testFollowersOriginalUsesStoredPath() {
        // 原画像（originals/）も同じ判定
        let info = image(url: followersOriginalURL, storagePath: "originals/u1/followers/o.jpg")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .storage("originals/u1/followers/o.jpg"))
    }

    func testURLWithoutStoragePathUsesURL() {
        // パスが無く、URL からも取り出せない（Storage の URL でない）ごく古いデータは URL で読む
        let info = image(url: "https://example.com/a.jpg")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .remote(URL(string: "https://example.com/a.jpg")!))
    }

    func testNothingIsUnavailable() {
        // URL もパスも無い
        let info = image(url: "")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: false), .unavailable)
    }

    // MARK: - サムネイル

    func testPublicThumbnailUsesThumbnailURL() {
        // 公開のサムネイルは、サムネイルの URL で読む
        let info = image(
            url: publicBodyURL,
            thumbnail: publicThumbURL,
            storagePath: "posts/u1/public/a.jpg",
            thumbnailStoragePath: "thumbnails/u1/public/a_thumb.jpg"
        )
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: true), .remote(URL(string: publicThumbURL)!))
    }

    func testPublicWithoutThumbnailFallsBackToBodyURL() {
        // サムネイルの無い公開の投稿は、本体の URL
        let info = image(url: publicBodyURL, storagePath: "posts/u1/public/a.jpg")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: true), .remote(URL(string: publicBodyURL)!))
    }

    func testFollowersThumbnailUsesStoredThumbnailPath() {
        // 新しい版が書く形（thumbnail は無く、thumbnailStoragePath だけ）
        let info = image(
            url: "",
            storagePath: "posts/u1/followers/a.jpg",
            thumbnailStoragePath: "thumbnails/u1/followers/a_thumb.jpg"
        )
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: true), .storage("thumbnails/u1/followers/a_thumb.jpg"))
    }

    func testStoredThumbnailPathWinsOverThumbnailURL() {
        // サムネイルの URL が残っていても、thumbnailStoragePath で読む
        let info = image(
            url: followersBodyURL,
            thumbnail: followersThumbURL,
            storagePath: "posts/u1/followers/a.jpg",
            thumbnailStoragePath: "thumbnails/u1/followers/a_thumb.jpg"
        )
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: true), .storage("thumbnails/u1/followers/a_thumb.jpg"))
    }

    func testStoredThumbnailPathWinsOverPathInThumbnailURL() {
        // サムネイルの URL の中のパスと thumbnailStoragePath が食い違うときは、thumbnailStoragePath を使う（URL の public を信じない）
        let info = image(
            url: "",
            thumbnail: publicThumbURL,
            storagePath: "posts/u1/followers/a.jpg",
            thumbnailStoragePath: "thumbnails/u1/followers/a_thumb.jpg"
        )
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: true), .storage("thumbnails/u1/followers/a_thumb.jpg"))
    }

    func testOldFollowersThumbnailUsesPathFromThumbnailURL() {
        // thumbnailStoragePath の無い古い投稿は、サムネイルの URL からパスを取り出す（本体に落とさない）
        let info = image(url: followersBodyURL, thumbnail: followersThumbURL)
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: true), .storage("thumbnails/u1/followers/a_thumb.jpg"))
    }

    func testFollowersWithoutThumbnailFallsBackToBodyPath() {
        // サムネイルの手がかりが何も無ければ、本体のパス
        let info = image(url: "", storagePath: "posts/u1/followers/a.jpg")
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: true), .storage("posts/u1/followers/a.jpg"))
    }

    func testPrivateThumbnailUsesStoredThumbnailPath() {
        // 非公開のサムネイルも同じ
        let info = image(
            url: "",
            storagePath: "posts/u1/private/a.jpg",
            thumbnailStoragePath: "thumbnails/u1/private/a_thumb.jpg"
        )
        XCTAssertEqual(PostImageSource.resolve(info, prefersThumbnail: true), .storage("thumbnails/u1/private/a_thumb.jpg"))
    }
}
