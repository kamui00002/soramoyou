//
//  PostViewModelRecipeCorpusTests.swift
//  SoramoyouTests
//
//  ⭐️ パーソナルAI編集の学習コーパス記録ロジックを直接検証する。
//  - recipesToRecordInCorpus(): 複数枚投稿で「最後の1枚のレシピしか記録されない」バグの回帰防止
//    （画像ごとの editRecipes を優先し、未指定時のみ従来の editRecipe 単数へフォールバックする）
//  - corpusSkyType: savePost() 内のローカル変数（(postKind == .collage) ? nil : effectiveSkyType）。
//    savePost() 自体は Firestore/Storage を伴う非同期処理のためユニットテストから直接は呼べない。
//    PostViewModel.swift のコメント（savePost 内 corpusSkyType 算出箇所）が明記する通り、この式は
//    createPost() が Post.skyType を決める式（isCollage ? nil : (editing?.skyType ?? effectiveSkyType)）と
//    意図的に揃えられている（editingContext は新規投稿＝corpus記録経路では常に nil なので両式は同値）。
//    そのため createPost() が返す Post.skyType を通じて、corpusSkyType と同一の決定式を
//    savePost() のフル実行なしで軽量に検証する。
//

@testable import Soramoyou
import UIKit
import XCTest

final class PostViewModelRecipeCorpusTests: XCTestCase {
    /// 1×1 のダミー画像
    private func dummyImage() -> UIImage {
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - recipesToRecordInCorpus()

    @MainActor
    func testRecipesToRecordInCorpus_usesPerImageRecipesWhenProvided() {
        let vm = PostViewModel(userId: "u1")
        let images = [dummyImage(), dummyImage(), dummyImage()]
        vm.setSelectedImages(images)

        // 互いに異なる非中立レシピ（EditRecipe.isNeutral の baseline と exposureEV/contrastCI が
        // 異なるため、いずれも中立判定に引っかからない）。
        var r1 = EditRecipe()
        r1.exposureEV = 0.5
        var rA = EditRecipe()
        rA.exposureEV = 1.0
        var rB = EditRecipe()
        rB.exposureEV = -1.0
        var rC = EditRecipe()
        rC.contrastCI = 1.3

        // editRecipes（画像ごとの独立レシピ）が渡された場合、旧経路の editRecipe（代表1枚）は無視される。
        vm.setEditedImages(images, editSettings: EditSettings(), editRecipe: r1, editRecipes: [rA, rB, rC])

        let recorded = vm.recipesToRecordInCorpus()
        // ★複数枚学習バグ回帰防止: 3枚とも学習コーパスへ記録される（旧実装は最後の1枚のみだった）
        XCTAssertEqual(recorded.count, 3, "画像ごとのレシピが3件とも記録されるべき")
        XCTAssertEqual(recorded, [rA, rB, rC])
    }

    @MainActor
    func testRecipesToRecordInCorpus_fallsBackToSingularEditRecipeWhenRecipesEmpty() {
        let vm = PostViewModel(userId: "u1")
        let images = [dummyImage()]
        vm.setSelectedImages(images)

        var r1 = EditRecipe()
        r1.exposureEV = 0.8

        // editRecipes を渡さない（下書き読込等の旧呼び出し経路を模す）＝既定値 [] のまま。
        vm.setEditedImages(images, editSettings: EditSettings(), editRecipe: r1)

        let recorded = vm.recipesToRecordInCorpus()
        XCTAssertEqual(recorded, [r1], "editRecipes未指定時は従来どおり editRecipe（代表1枚）にフォールバックする")
    }

    @MainActor
    func testRecipesToRecordInCorpus_excludesNeutralRecipes() {
        let vm = PostViewModel(userId: "u1")
        let images = [dummyImage(), dummyImage()]
        vm.setSelectedImages(images)

        let neutral = EditRecipe() // 未編集＝中立レシピ（isNeutral == true）
        var nonNeutral = EditRecipe()
        nonNeutral.exposureEV = 1.2

        vm.setEditedImages(images, editSettings: EditSettings(), editRecipes: [neutral, nonNeutral])

        let recorded = vm.recipesToRecordInCorpus()
        // 未編集（中立）レシピは学習データを薄めるため記録対象から除外される。
        XCTAssertEqual(recorded, [nonNeutral], "中立レシピは除外され、非中立レシピのみが残るべき")
    }

    // MARK: - corpusSkyType（savePost 内ローカル変数と同一式を createPost() 経由で検証）

    @MainActor
    func testCorpusSkyType_nilForCollage() throws {
        let vm = PostViewModel(userId: "u1")
        vm.setSelectedImages([dummyImage()])
        // effectiveSkyType を確実に non-nil にする（userSelectedSkyType が最優先で使われる）。
        vm.userSelectedSkyType = .clear

        let imageURLs = [UploadedImage(
            url: "https://e.com/s.jpg", thumbnail: "https://e.com/s_t.jpg",
            width: 800, height: 600, storagePath: "posts/u1/s.jpg", thumbnailStoragePath: "posts/u1/s_t.jpg"
        )]

        // 非collage: corpusSkyType と同じ式（isCollage ? nil : effectiveSkyType）は effectiveSkyType をそのまま使う。
        vm.postKind = .single
        let singlePost = try vm.createPost(imageURLs: imageURLs, originalImageURLs: nil)
        XCTAssertEqual(singlePost.skyType, .clear, "非collageではeffectiveSkyTypeがそのまま使われるべき")

        // collage: 複数素材の空タイプを1値で表せないため、effectiveSkyTypeがあってもnilになる
        // （corpusSkyTypeが学習データを汚染しないための同一ゲート）。
        vm.postKind = .collage
        let collagePost = try vm.createPost(imageURLs: imageURLs, originalImageURLs: nil)
        XCTAssertNil(collagePost.skyType, "collageではeffectiveSkyTypeの有無に関わらずnilになるべき")
    }
}
