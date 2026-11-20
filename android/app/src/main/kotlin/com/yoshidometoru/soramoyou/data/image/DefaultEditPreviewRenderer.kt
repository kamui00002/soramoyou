// ⭐️ 編集のプレビューの絵・フィルターの見本の絵・下書きの見本の JPEG を作る部品の実装（Kiro android-edit-tools タスク 13・A3・design.md:896-908）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.edit.ColorKernel
import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * [EditPreviewRenderer] の実装。画像の読み書きは焼き込み（[DefaultImagePipeline]）と同じ継ぎ目 [ImageCodec] を通し、
 * 色は [ColorKernel] だけが計算する（この部品は色の係数を持たない：要件 11.5）。
 *
 * - [loadBase]：大きさ → EXIF の向き → 間引いて復号 → 向きの直しと利用者の回転を 1 回の描画で掛ける（切り抜きは全体・色は掛けない）
 *   → 画素を読む。向きと回転の合成は焼き込みと同じ [thenQuarterTurns]（要件 10.3）
 * - [render]：受け取った絵の写しに [ColorKernel.render] を掛ける（範囲は全体、縦横比は絵の幅÷高さ）
 * - [draftThumbnail]：焼き込みと同じ部品を小さな寸法で通す。回転→（今の 6 種だけなら描画の中で行列）→切り抜き→（必要なら色）→品質 80 の JPEG
 *
 * 同時に持つ画像は焼き込みと同じく 2 枚まで（復号した絵と、描いた絵）。どの画像も、使い終えたら失敗・例外でも解放する。
 * コルーチンの取り消し（CancellationException）は失敗に写さず、記録もせずにそのまま伝える。
 *
 * 失敗の記録（`error_occurred`）は [draftThumbnail] だけが行う（発生箇所 `EditPreviewRenderer.draftThumbnail`：design.md「Monitoring」）。
 * 記録する失敗は `ImageUnreadable`（何枚目か）だけで、写真の場所や例外の本文は入れない。
 * [loadBase] は記録せず、失敗を `AppResult.Err` で呼ぶ側に返す（Monitoring の表に無いため。どう見せるかは呼ぶ側が決める）。
 *
 * @param analytics 下書きの見本を作れなかったときの記録の窓口
 * @param ioDispatcher 写真の読み込み・復号・JPEG への圧縮を行うスレッド。画面のスレッドで重い処理をしないよう、既定は IO
 * @param computeDispatcher 色の計算（[render]）を行うスレッド。画素ごとの計算なので、既定は Default
 */
class DefaultEditPreviewRenderer internal constructor(
    private val codec: ImageCodec,
    private val analytics: AnalyticsFacade,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val computeDispatcher: CoroutineDispatcher = Dispatchers.Default,
) : EditPreviewRenderer {

    /**
     * 読めない・復号できない・窓口の例外は `ImageUnreadable(photo.index)`。
     * [longEdge] が 0 以下なのは呼ぶ側の誤りなので、失敗に写さずに例外にする（間引きの倍率が決まらないため）。
     */
    override suspend fun loadBase(photo: PickedPhoto, quarterTurns: Int, longEdge: Int): AppResult<PreviewBase> {
        require(longEdge > 0) { "longEdge は 1 以上: $longEdge" }
        return withContext(ioDispatcher) {
            guarded(photo) { readBase(photo, quarterTurns, longEdge) }
        }
    }

    override suspend fun render(base: PreviewBase, recipe: ColorRecipe): IntArray = withContext(computeDispatcher) {
        // 受け取った絵は書き換えない（同じ絵から何度も描き直すため）。写しに掛ける
        val pixels = base.pixels.copyOf()
        // 範囲は全体（切り抜きは表示の側が範囲だけを描く）。縦横比は、回転まで済んだ全体の絵の 幅÷高さ（周辺減光の位置に使う）
        val fullAspect = if (base.height > 0) base.width.toDouble() / base.height else 1.0
        ColorKernel.render(pixels, base.width, base.height, recipe, NormalizedRect.FULL, fullAspect)
        pixels
    }

    /**
     * 作れなければ null を返し、`EditPreviewRenderer.draftThumbnail` で記録する（下書きは見本なしで保存する）。
     * [longEdge] が 0 以下なのは呼ぶ側の誤りなので、null にせずに例外にする。
     */
    override suspend fun draftThumbnail(photo: PickedPhoto, edit: PhotoEdit, longEdge: Int): ByteArray? {
        require(longEdge > 0) { "longEdge は 1 以上: $longEdge" }
        return withContext(ioDispatcher) {
            when (val result = guarded(photo) { encodeThumbnail(photo, edit, longEdge) }) {
                is AppResult.Ok -> result.value
                is AppResult.Err -> {
                    analytics.logError(result.error, LOG_CONTEXT_DRAFT_THUMBNAIL)
                    null
                }
            }
        }
    }

    /** 窓口の例外を `ImageUnreadable` に写す。コルーチンの取り消しはそのまま伝える（[DefaultImagePipeline] と同じ写し方）。 */
    private inline fun <T> guarded(photo: PickedPhoto, block: () -> AppResult<T>): AppResult<T> =
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            AppResult.Err(AppError.ImageUnreadable(photo.index))
        }

    /**
     * [loadBase] の中身。大きさ → 向き → 間引いて復号 → 回転と縮小（色なし・切り抜きは全体）→ 画素を読む。
     * 復号した絵は描き終えたらすぐに解放し、描いた絵は画素を読んだら（失敗・例外でも）解放する。
     */
    private fun readBase(photo: PickedPhoto, quarterTurns: Int, longEdge: Int): AppResult<PreviewBase> {
        val unreadable = AppResult.Err(AppError.ImageUnreadable(photo.index))
        val stored = codec.readSize(photo.uri) ?: return unreadable
        if (stored.width <= 0 || stored.height <= 0) return unreadable

        // EXIF の向きの直しのあとに、利用者の回転を足した 1 つの操作（焼き込みと同じ合成：要件 10.3）
        val fix = orientationFixOf(readOrientationOrNone(photo.uri)).thenQuarterTurns(quarterTurns)
        // 長辺が longEdge を下回らない範囲で間引く（下回ると拡大になって粗くなる）
        val decoded = codec.decode(photo.uri, sampleSizeFor(stored.width, stored.height, longEdge)) ?: return unreadable
        // 回した後の寸法は、合成した操作で決める（EXIF の 6 に回転 1 を足すと 180 度になり、幅と高さは入れ替わらない）
        val turned = turnedSize(decoded, fix)
        val upright = try {
            codec.transform(decoded, fix, NormalizedRect.FULL, fittedSize(turned.width, turned.height, longEdge), legacyFilter = null)
        } finally {
            codec.release(decoded)
        }
        try {
            return AppResult.Ok(PreviewBase(codec.readPixels(upright), upright.width, upright.height))
        } finally {
            codec.release(upright)
        }
    }

    /**
     * [draftThumbnail] の中身（design.md:905）。大きさ → 向き → 間引いて復号 → 回転・切り抜き・縮小（今の 6 種だけなら行列も）
     * → 必要なら色 → 品質 80 の JPEG。
     *
     * - 間引きは焼き込みと同じく全体の寸法で決める（`sampleSizeFor(幅, 高さ, longEdge)`：design.md:874）
     * - 出力の寸法は、回した後の絵の切り抜いた範囲の寸法（[cropPixelSize]）を、長辺 [longEdge] 以下にしたもの（拡大しない）。
     *   そのため、小さく切り抜いた写真の見本は [longEdge] より小さくなることがある
     * - 色は、中立（`isIdentity`）でも今の 6 種だけ（`legacyMatrixOnly`）でもないときだけ [ImageCodec.applyColor] で掛ける。
     *   範囲は切り抜いた範囲、縦横比は回した後の全体の絵の 幅÷高さ（周辺減光の位置は切り抜きで変わらない）
     */
    private fun encodeThumbnail(photo: PickedPhoto, edit: PhotoEdit, longEdge: Int): AppResult<ByteArray> {
        val unreadable = AppResult.Err(AppError.ImageUnreadable(photo.index))
        val stored = codec.readSize(photo.uri) ?: return unreadable
        if (stored.width <= 0 || stored.height <= 0) return unreadable

        // EXIF の向きの直しのあとに、その写真の編集の回転を足した 1 つの操作（焼き込みと同じ合成）
        val fix = orientationFixOf(readOrientationOrNone(photo.uri)).thenQuarterTurns(edit.geometry.quarterTurns)
        // 切り抜く範囲（回した後の絵に対する割合）。描く範囲・出力の寸法・色の範囲は、どれもこの値から取る
        val crop = edit.geometry.crop
        val recipe = ColorRecipe.of(edit)
        val decoded = codec.decode(photo.uri, sampleSizeFor(stored.width, stored.height, longEdge)) ?: return unreadable
        val turned = turnedSize(decoded, fix)
        val output = try {
            val cropped = cropPixelSize(turned.width, turned.height, crop)
            codec.transform(decoded, fix, crop, fittedSize(cropped.width, cropped.height, longEdge), recipe.legacyMatrixOnly)
        } finally {
            codec.release(decoded)
        }
        try {
            if (!recipe.isIdentity && recipe.legacyMatrixOnly == null) {
                codec.applyColor(output, recipe, frame = crop, fullAspect = turned.width.toDouble() / turned.height)
            }
            return AppResult.Ok(codec.encodeJpeg(output, DRAFT_THUMBNAIL_QUALITY).bytes)
        } finally {
            codec.release(output)
        }
    }

    /** [image] を [fix] で回した後の寸法（90 度・270 度では幅と高さが入れ替わる）。 */
    private fun turnedSize(image: DecodedImage, fix: OrientationFix): ImageSize =
        if (fix.swapsAxes) ImageSize(image.height, image.width) else ImageSize(image.width, image.height)

    /** EXIF の向きを読む。読めなければ 0（向きの記録が無い＝そのまま）にする（[DefaultImagePipeline] と同じ扱い）。 */
    private fun readOrientationOrNone(uri: String): Int =
        try {
            codec.readExifOrientation(uri)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            0
        }

    internal companion object {
        /** 下書きの見本の JPEG の品質（design.md:949：長辺 256・品質 80）。 */
        const val DRAFT_THUMBNAIL_QUALITY = 80

        /** 下書きの見本を作れなかったときの記録の発生箇所（design.md「Monitoring」）。 */
        const val LOG_CONTEXT_DRAFT_THUMBNAIL = "EditPreviewRenderer.draftThumbnail"
    }
}
