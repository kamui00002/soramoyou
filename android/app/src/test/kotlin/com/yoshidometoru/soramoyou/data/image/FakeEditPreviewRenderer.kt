// ⭐️ 編集のプレビューの絵を作る部品（EditPreviewRenderer）の偽物。メモリの中だけで、呼ばれた引数を控え、結果をテストが決める（Kiro android-edit-tools タスク 2.4・K0・design.md:777）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import kotlinx.coroutines.CompletableDeferred

/**
 * 写真を読まず、色も計算しない偽物（色の計算 ColorKernel は呼ばない）。
 *
 * - 呼ばれた順と引数を [calls] に控える。[PreviewBase] は data class でないので、[Call.Render] どうしの等しさは
 *   同じ [PreviewBase] の実体かで決まる
 * - 返すものは [loadBaseResult]・[renderResult]・[draftThumbnailResult] でテストが決める。既定は、[loadBaseResult] が
 *   幅 4 × 高さ 3 の、どれも [BASE_COLOR] の絵（呼ぶたびに新しい実体）、[renderResult] が base の画素の写し（色を変えない）、
 *   [draftThumbnailResult] が [THUMBNAIL_JPEG] の写し
 * - [loadBaseGate]・[renderGate]・[draftThumbnailGate] を置くと、その呼び出しは記録した後、ゲートが完了するまで戻らない
 *   （描いている途中に次の値が来たとき、などを見るため）。ゲートは 1 回きりで、完了させると後の呼び出しも待たずに通る
 */
class FakeEditPreviewRenderer : EditPreviewRenderer {

    /** 呼ばれた 1 回分。 */
    sealed interface Call {
        data class LoadBase(val photo: PickedPhoto, val quarterTurns: Int, val longEdge: Int) : Call
        data class Render(val base: PreviewBase, val recipe: ColorRecipe) : Call
        data class DraftThumbnail(val photo: PickedPhoto, val edit: PhotoEdit, val longEdge: Int) : Call
    }

    val calls = mutableListOf<Call>()
    var loadBaseResult: (photo: PickedPhoto, quarterTurns: Int, longEdge: Int) -> AppResult<PreviewBase> = { _, _, _ ->
        AppResult.Ok(PreviewBase(IntArray(BASE_WIDTH * BASE_HEIGHT) { BASE_COLOR }, BASE_WIDTH, BASE_HEIGHT))
    }
    var renderResult: (base: PreviewBase, recipe: ColorRecipe) -> IntArray = { base, _ -> base.pixels.copyOf() }
    var draftThumbnailResult: (photo: PickedPhoto, edit: PhotoEdit, longEdge: Int) -> ByteArray? = { _, _, _ -> THUMBNAIL_JPEG.copyOf() }
    var loadBaseGate: CompletableDeferred<Unit>? = null
    var renderGate: CompletableDeferred<Unit>? = null
    var draftThumbnailGate: CompletableDeferred<Unit>? = null

    override suspend fun loadBase(photo: PickedPhoto, quarterTurns: Int, longEdge: Int): AppResult<PreviewBase> {
        calls += Call.LoadBase(photo, quarterTurns, longEdge)
        loadBaseGate?.await()
        return loadBaseResult(photo, quarterTurns, longEdge)
    }

    override suspend fun render(base: PreviewBase, recipe: ColorRecipe): IntArray {
        calls += Call.Render(base, recipe)
        renderGate?.await()
        return renderResult(base, recipe)
    }

    override suspend fun draftThumbnail(photo: PickedPhoto, edit: PhotoEdit, longEdge: Int): ByteArray? {
        calls += Call.DraftThumbnail(photo, edit, longEdge)
        draftThumbnailGate?.await()
        return draftThumbnailResult(photo, edit, longEdge)
    }

    companion object {
        const val BASE_WIDTH = 4
        const val BASE_HEIGHT = 3

        /** 既定の絵の色（不透明の灰 128）。 */
        const val BASE_COLOR: Int = 0xFF808080.toInt()

        /** 既定の見本の JPEG のバイト（中身に意味は無い。読むたびに同じ値）。 */
        val THUMBNAIL_JPEG: ByteArray get() = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xD9.toByte())
    }
}
