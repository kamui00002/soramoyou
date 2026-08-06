//
//  PostViewModelRecipeCorpusTests.swift
//  SoramoyouTests
//
//  ⭐️ パーソナルAI編集の学習コーパス記録ロジックを直接検証する。
//  - recipesToRecordInCorpus(): 複数枚投稿で「最後の1枚のレシピしか記録されない」バグの回帰防止
//    （画像ごとの editRecipes を優先し、未指定時のみ従来の editRecipe 単数へフォールバックする）
//  - recipesToRecordInCorpus() の重複除去: 同一レシピをN枚に適用した投稿がN件記録されると
//    「あなたの定番」の減衰重み付き平均（savedAt 降順に 0.8^k）で上位ランクを独占してしまうため、
//    PersonalDefaultCandidateProvider.isSimilar で"ほぼ同じ"と判定される連続レコードは1件に畳む
//    （collage の畳み込み後1枚に対しNパネル分が記録される問題＝G2 も同時解消）。
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

    @MainActor
    func testRecipesToRecordInCorpus_dedupesNearIdenticalRecipes() {
        let vm = PostViewModel(userId: "u1")
        let images = [dummyImage(), dummyImage(), dummyImage()]
        vm.setSelectedImages(images)

        // 3枚とも「見た目上ほぼ同じ」編集（isSimilar の全閾値内に収まる差分のみ）。
        // exposureEV の差は最大 0.07（閾値 0.15 未満）、他フィールドは全て既定値のまま
        // （saturationCI/contrastCI 差 0、warmthNorm/style2D 系は nil 同士で差 0）なので確実に similar 判定になる。
        var r1 = EditRecipe()
        r1.exposureEV = 1.0
        var r2 = EditRecipe()
        r2.exposureEV = 1.05
        var r3 = EditRecipe()
        r3.exposureEV = 0.98

        vm.setEditedImages(images, editSettings: EditSettings(), editRecipes: [r1, r2, r3])

        let recorded = vm.recipesToRecordInCorpus()
        // 同一レシピを3枚に適用しても学習コーパスへの寄与は1件分に畳まれるべき
        // （減衰重み付き平均で上位ランクを独占し、過去の学習を1回の投稿で上書きしてしまうのを防ぐ）。
        XCTAssertEqual(recorded.count, 1, "ほぼ同一の3件は1件に畳まれるべき")
        XCTAssertEqual(recorded, [r1], "最初に採用された（先頭の）レシピが残るべき")
    }

    @MainActor
    func testRecipesToRecordInCorpus_keepsDistinctRecipes() {
        let vm = PostViewModel(userId: "u1")
        let images = [dummyImage(), dummyImage(), dummyImage()]
        vm.setSelectedImages(images)

        // isSimilar の閾値（exposureEV 差 0.15）を確実に超える3件。画像ごとに本当に異なる編集は
        // 全件記録されるべき（重複除去が過剰に畳んでしまわないことの回帰防止）。
        var r1 = EditRecipe()
        r1.exposureEV = 0.5
        var r2 = EditRecipe()
        r2.exposureEV = 1.5
        var r3 = EditRecipe()
        r3.exposureEV = -1.0

        vm.setEditedImages(images, editSettings: EditSettings(), editRecipes: [r1, r2, r3])

        let recorded = vm.recipesToRecordInCorpus()
        XCTAssertEqual(recorded.count, 3, "明確に異なる3件は畳まれず全件残るべき")
        XCTAssertEqual(recorded, [r1, r2, r3])
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
