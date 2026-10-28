//
//  PostPhotoViewerMathTests.swift ⭐️
//  SoramoyouTests
//
//  投稿の詳細の写真を全画面で見るビューア（PostPhotoViewer.swift の PostPhotoViewerMath）の計算のテスト
//  1.18.0 PR-H「5b: 投稿の詳細の写真を全画面で見る」
//
//  ⚠️ 期待値は 1 つずつ直に書く（実装の式から期待値を作って比べると、式が間違っていても緑になる）。
//  ⚠️ 「等倍は 0」は、0 でないずらしを入れて 0 が返ることを見る。
//     0 を入れて 0 を確かめると、入力をそのまま返すだけの実装でも緑になってしまう。
//  ⚠️ 「上へ引いても閉じない」は、向きを見ない実装（abs で長さだけを見る）だと赤になる値にしてある。
//

@testable import Soramoyou
import XCTest

final class PostPhotoViewerMathTests: XCTestCase {
    // MARK: - 拡大率

    /// 拡大率は 1〜4 倍に収める（小さすぎ → 1・中 → そのまま・大きすぎ → 4）
    func testClampedScaleKeepsBetweenMinAndMax() {
        XCTAssertEqual(PostPhotoViewerMath.clampedScale(0.5), 1)
        XCTAssertEqual(PostPhotoViewerMath.clampedScale(2.5), 2.5)
        XCTAssertEqual(PostPhotoViewerMath.clampedScale(6), 4)
    }

    // MARK: - ドラッグの使い道

    /// 大きくしている → ずらす（ピンチ中でも）・等倍でピンチ中 → 何もしない・等倍 → 閉じる引っぱり
    func testDragModeForEachState() {
        XCTAssertEqual(PostPhotoViewerMath.dragMode(scale: 2, isPinching: false), .pan)
        XCTAssertEqual(PostPhotoViewerMath.dragMode(scale: 2, isPinching: true), .pan)
        XCTAssertEqual(PostPhotoViewerMath.dragMode(scale: 1, isPinching: true), .ignore)
        XCTAssertEqual(PostPhotoViewerMath.dragMode(scale: 1, isPinching: false), .dismiss)
    }

    // MARK: - 縦横比

    /// 縦横比は幅 ÷ 高さ・幅か高さが 0 なら出さない（nil）
    func testAspectRatio() {
        XCTAssertEqual(PostPhotoViewerMath.aspectRatio(width: 3000, height: 4000), 0.75)
        XCTAssertNil(PostPhotoViewerMath.aspectRatio(width: 0, height: 4000))
        XCTAssertNil(PostPhotoViewerMath.aspectRatio(width: 3000, height: 0))
    }

    // MARK: - 収まる大きさ

    /// 縦向きの画面・横向きの画面・横長の写真・比が分からない写真で、全体が収まる大きさになる
    func testFittedSize() {
        // 縦長の写真（0.75）を縦長の画面（400×800）に → 幅いっぱい
        let portraitInPortrait = PostPhotoViewerMath.fittedSize(aspectRatio: 0.75, in: CGSize(width: 400, height: 800))
        XCTAssertEqual(portraitInPortrait.width, 400, accuracy: 0.01)
        XCTAssertEqual(portraitInPortrait.height, 533.33, accuracy: 0.01)

        // 縦長の写真（0.75）を横長の画面（800×400）に → 高さいっぱい
        let portraitInLandscape = PostPhotoViewerMath.fittedSize(aspectRatio: 0.75, in: CGSize(width: 800, height: 400))
        XCTAssertEqual(portraitInLandscape.width, 300, accuracy: 0.01)
        XCTAssertEqual(portraitInLandscape.height, 400, accuracy: 0.01)

        // 横長の写真（2.0）を縦長の画面（400×800）に → 幅いっぱい
        let landscapeInPortrait = PostPhotoViewerMath.fittedSize(aspectRatio: 2.0, in: CGSize(width: 400, height: 800))
        XCTAssertEqual(landscapeInPortrait.width, 400, accuracy: 0.01)
        XCTAssertEqual(landscapeInPortrait.height, 200, accuracy: 0.01)

        // 比が分からない → 入れ物の大きさのまま
        XCTAssertEqual(
            PostPhotoViewerMath.fittedSize(aspectRatio: nil, in: CGSize(width: 400, height: 800)),
            CGSize(width: 400, height: 800)
        )
    }

    // MARK: - ずらしの上限

    /// 等倍のときは、どちらの向きにもずらさない（0 でないずらしを入れても 0 になる）
    func testClampedOffsetAtMinScaleIsZero() {
        let result = PostPhotoViewerMath.clampedOffset(
            CGSize(width: 50, height: 50),
            scale: 1,
            contentSize: CGSize(width: 400, height: 200),
            containerSize: CGSize(width: 400, height: 800)
        )
        XCTAssertEqual(result, CGSize(width: 0, height: 0))
    }

    /// 2 倍（写真 400×200 → 800×400・画面 400×800）では、横は片側 200 で止まり、縦ははみ出していないので 0
    func testClampedOffsetStopsAtEdges() {
        XCTAssertEqual(
            PostPhotoViewerMath.clampedOffset(
                CGSize(width: 250, height: 30),
                scale: 2,
                contentSize: CGSize(width: 400, height: 200),
                containerSize: CGSize(width: 400, height: 800)
            ),
            CGSize(width: 200, height: 0)
        )
        XCTAssertEqual(
            PostPhotoViewerMath.clampedOffset(
                CGSize(width: -250, height: -30),
                scale: 2,
                contentSize: CGSize(width: 400, height: 200),
                containerSize: CGSize(width: 400, height: 800)
            ),
            CGSize(width: -200, height: 0)
        )
    }

    /// 上限の内側のずらしは、そのまま
    func testClampedOffsetInsideBoundsIsUnchanged() {
        XCTAssertEqual(
            PostPhotoViewerMath.clampedOffset(
                CGSize(width: 100, height: 0),
                scale: 2,
                contentSize: CGSize(width: 400, height: 200),
                containerSize: CGSize(width: 400, height: 800)
            ),
            CGSize(width: 100, height: 0)
        )
    }

    // MARK: - 閉じるかどうか

    /// 下へ 120pt 以上引っぱって離したら閉じる（130pt）
    func testShouldDismissWhenDraggedFarEnough() {
        XCTAssertTrue(PostPhotoViewerMath.shouldDismiss(translationHeight: 130, predictedEndTranslationHeight: 130))
    }

    /// 引っぱりが短くても（50pt）、下への勢いで 240pt 先まで進みそう（300pt）なら閉じる
    func testShouldDismissWhenFlungDown() {
        XCTAssertTrue(PostPhotoViewerMath.shouldDismiss(translationHeight: 50, predictedEndTranslationHeight: 300))
    }

    /// 引っぱりが短く（50pt）、勢いも足りない（100pt）なら閉じない
    func testShouldNotDismissWhenShortAndSlow() {
        XCTAssertFalse(PostPhotoViewerMath.shouldDismiss(translationHeight: 50, predictedEndTranslationHeight: 100))
    }

    /// 上へ引っぱったら（−200pt・勢い −400pt）、長くても閉じない（下向きだけ）
    func testShouldNotDismissWhenDraggedUp() {
        XCTAssertFalse(PostPhotoViewerMath.shouldDismiss(translationHeight: -200, predictedEndTranslationHeight: -400))
    }

    // MARK: - 引っぱり中の縮み

    /// 0pt → 1・200pt → 0.925・400pt → 0.85・それより先も 0.85・上へ → 1
    func testDismissDragScale() {
        XCTAssertEqual(PostPhotoViewerMath.dismissDragScale(translationHeight: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(PostPhotoViewerMath.dismissDragScale(translationHeight: 200), 0.925, accuracy: 0.0001)
        XCTAssertEqual(PostPhotoViewerMath.dismissDragScale(translationHeight: 400), 0.85, accuracy: 0.0001)
        XCTAssertEqual(PostPhotoViewerMath.dismissDragScale(translationHeight: 800), 0.85, accuracy: 0.0001)
        XCTAssertEqual(PostPhotoViewerMath.dismissDragScale(translationHeight: -100), 1, accuracy: 0.0001)
    }

    // MARK: - 計装

    /// 計装の parameters は「何枚目か」と「全部で何枚か」だけ
    func testOpenedEventParameters() {
        XCTAssertEqual(
            PostPhotoViewerMath.openedEventParameters(imageIndex: 1, imageCount: 3),
            ["image_index": 1, "image_count": 3]
        )
    }
}
