// ⭐️ 編集のプレビューとフィルターの見本・下書きの見本の画素を作る部品の契約（Kiro android-edit-tools タスク 2.3・K0・design.md:590-606）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit

/*
 * K0 はこのファイルの interface・型・定数だけを置く（design.md:353。形は K0 の後で変えない）。
 * 実装（DefaultEditPreviewRenderer）は A3 が作る（design.md:896-908）。K0 の時点では、本体のどこもこれを使わない。
 */

/** プレビューの絵（回転まで済ませ、長辺を縮めた、色を掛ける前の画素） */
class PreviewBase(val pixels: IntArray, val width: Int, val height: Int)

/** 画面に渡す、描いた絵（色を掛けた後の画素）。Android の型を持たないので、ViewModel の JVM の単体テストで扱える。画面の側が Bitmap にして描く */
class PreviewImage(val pixels: IntArray, val width: Int, val height: Int)

interface EditPreviewRenderer {
    suspend fun loadBase(photo: PickedPhoto, quarterTurns: Int, longEdge: Int = PREVIEW_LONG_EDGE): AppResult<PreviewBase>

    /** base の写しに recipe を掛けた画素（全体の絵。切り抜きは表示の側で範囲だけを描く） */
    suspend fun render(base: PreviewBase, recipe: ColorRecipe): IntArray

    /**
     * 下書きの一覧の見本の JPEG（編集を全部掛けた絵：回転→色→切り抜き。長辺は longEdge 以下・品質 80）。作れなければ null（記録する）。
     * 写真から作り直す（PreviewBase を受け取らない。ViewModel は表示中の写真とその両隣の PreviewBase しか持たず、1 枚目のものがあるとは限らないため）
     */
    suspend fun draftThumbnail(photo: PickedPhoto, edit: PhotoEdit, longEdge: Int = DRAFT_THUMBNAIL_EDGE): ByteArray?

    companion object {
        const val PREVIEW_LONG_EDGE = 1024
        const val FILTER_SAMPLE_EDGE = 112
        const val DRAFT_THUMBNAIL_EDGE = 256
    }
}
