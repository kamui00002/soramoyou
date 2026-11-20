// ⭐️ 写真の変換の実装：大きさ → 向き → 間引いて復号 → 回転・切り抜き・縮小・フィルター → 解放 → 色 → JPEG → 大きさの検査（タスク 16.1・22.1・Kiro android-edit-tools タスク 12・A1）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.EditGeometry
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.data.remote.write.StorageGateway
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * [ImagePipeline] の実装。1 枚ずつ、次の順で進める（投稿は Kiro android-edit-tools design.md:871-879 の 8 手順）。
 *
 * 1. 大きさ：[ImageCodec.readSize] で画素を復号せずに寸法だけを読む。読めない・0 なら `ImageUnreadable`
 * 2. 向き：EXIF の向きを読む。読めなければ「そのまま」とする（向きは画素の読み込みに必須ではない）。
 *    投稿では、EXIF の直しのあとに利用者の回転を足して 1 つの操作にする（[thenQuarterTurns]）
 * 3. 復号：長辺が規格の長辺を下回らない範囲で間引いて復号する（[sampleSizeFor]）。復号できなければ `ImageUnreadable`
 * 4. 正立の画像：回した後の寸法と切り抜きの範囲から、切り抜いた範囲の画素の寸法（[cropPixelSize]・四捨五入）を出し、
 *    長辺が規格以下になるよう縮小した大きさ（[fittedSize]・拡大しない）を出力の寸法にする。
 *    回転・反転・切り抜き・縮小・今の 6 種のフィルターを 1 回の描画で行う（[ImageCodec.transform]）。
 *    描き終えたら、成否によらず復号した画像を解放する。アイコンは切り抜き・利用者の回転・色を持たない（全体・0 回・フィルターなし）
 * 5. 色（投稿だけ）：編集の色（`ColorRecipe.of`）が中立でも「今の 6 種だけ」でもなければ、正立の画像に [ImageCodec.applyColor] で掛ける。
 *    位置の範囲は切り抜きの範囲、縦横比は回した後の全体の絵の 幅÷高さ（ビンテージの周辺減光の位置に使う）
 * 6. JPEG：正立の画像を規格の品質で JPEG にする。5MB 以上なら `ImageTooLarge`
 *    （`storage.rules` は「5MB 未満」。値は [StorageGateway.MAX_UPLOAD_BYTES] と共有）
 * 7. サムネイル（投稿だけ）：正立の画像（＝本体と同じ、色を掛けた後の画素）を長辺 [JpegSpec.POST_THUMBNAIL] 以下へ縮小し、品質 80 の JPEG にする。
 *    フィルターと色は 4・5 で掛け済みなので、もう掛けない。5MB の検査は本体と同じ。本体が大きすぎたら作らない
 *
 * 編集が無い（[PhotoEdit.NONE]）ときと、今の 6 種のフィルターだけのときは、[ImageCodec.transform] に渡る引数も描画も、
 * 編集の機能を入れる前と同じになる（design.md:882-883）。
 *
 * 同時に持つ画像は、4 の間は「復号した画像＋正立の画像」、5・6 の間は正立の画像だけ（5 はほかに 64 行の帯を 1 つ持つ）、
 * 7 の間は「正立の画像＋サムネイルの画像」の 2 枚までにする
 * （ほかに [ImageCodec.transform] の中で、モアレを防ぐための縮小の途中の画像を 1 枚持つことがある。タスク 25.4）
 * （要件「画像は 1 枚ずつ順に処理し、同時に持つ画像を最小にする」）。どの画像も、使い終えたら失敗・例外でも解放する。
 *
 * 窓口の例外（写真を開けない・権限が無い・圧縮できない）は `ImageUnreadable` に写す。
 * コルーチンの取り消し（CancellationException）は失敗に写さず、そのまま伝える。
 *
 * @param dispatcher 復号と圧縮を行うスレッド。画面のスレッドで重い処理をしないよう、既定は IO
 */
class DefaultImagePipeline internal constructor(
    private val codec: ImageCodec,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : ImagePipeline {

    override suspend fun prepare(photo: PickedPhoto, spec: JpegSpec): AppResult<PreparedImage> = guarded(photo) {
        // アイコンは編集を持たない：切り抜きは全体・利用者の回転は 0 回・フィルターなし（描画は編集の機能を入れる前と同じ）
        withUpright(photo, spec, EditGeometry.NONE, legacyFilter = null) { upright, _ ->
            val jpeg = codec.encodeJpeg(upright, spec.quality)
            tooLarge(photo, jpeg) ?: AppResult.Ok(PreparedImage(jpeg.bytes, jpeg.width, jpeg.height))
        }
    }

    /**
     * 投稿用の本体とサムネイル（Kiro android-edit-tools タスク 12・A1・design.md:871-879 の手順）。
     * [edit] の回転・切り抜き（[PhotoEdit.geometry]）を描画で掛け、色は `ColorRecipe.of(edit)` で決める：
     * - 中立（[PhotoEdit.NONE]・ナチュラル）：色を掛けない
     * - 今の 6 種のフィルターだけ（`legacyMatrixOnly`）：今の行列を描画の中で掛ける（[ImageCodec.transform] の `legacyFilter`）。色の段は通らない
     * - それ以外（新しい 3 種・ツールが 1 つでも付いた）：描画では行列を掛けず（`legacyFilter = null`）、描いた後に [ImageCodec.applyColor] で
     *   レシピ全体（今の 6 種の行列も含む）を掛ける
     */
    override suspend fun preparePost(photo: PickedPhoto, edit: PhotoEdit): AppResult<PreparedPostImage> = guarded(photo) {
        val recipe = ColorRecipe.of(edit)
        withUpright(photo, JpegSpec.POST_BODY, edit.geometry, recipe.legacyMatrixOnly) { upright, fullAspect ->
            // 色（上の説明の 5・design.md:877）：中立でも「今の 6 種だけ」でもなければ、出力の絵をその場で書き換える（位置の範囲は切り抜きの範囲）
            if (!recipe.isIdentity && recipe.legacyMatrixOnly == null) {
                codec.applyColor(upright, recipe, frame = edit.geometry.crop, fullAspect = fullAspect)
            }
            val body = codec.encodeJpeg(upright, JpegSpec.POST_BODY.quality)
            tooLarge(photo, body)?.let { return@withUpright it }

            // サムネイルは本体と同じ画素から作る。向きは直してあり、切り抜き・フィルター・色も掛けてあるので、縮小だけをする
            val thumbnailSize = fittedSize(upright.width, upright.height, JpegSpec.POST_THUMBNAIL.longEdge)
            val small = codec.transform(upright, OrientationFix.NONE, NormalizedRect.FULL, thumbnailSize, legacyFilter = null)
            val thumbnail = try {
                codec.encodeJpeg(small, JpegSpec.POST_THUMBNAIL.quality)
            } finally {
                codec.release(small)
            }
            tooLarge(photo, thumbnail) ?: AppResult.Ok(PreparedPostImage(body.bytes, body.width, body.height, thumbnail.bytes))
        }
    }

    /** 両方の入口に共通の失敗の写し方：窓口の例外は `ImageUnreadable`、コルーチンの取り消しはそのまま伝える。 */
    private suspend fun <T> guarded(photo: PickedPhoto, block: () -> AppResult<T>): AppResult<T> = withContext(dispatcher) {
        try {
            block()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            AppResult.Err(AppError.ImageUnreadable(photo.index))
        }
    }

    /**
     * 手順 1〜4（大きさ → 向き → 間引いて復号 → 正立の画像）を行い、正立の画像と、回した後の全体の絵の 幅÷高さ を [use] に渡す。
     * [geometry] の回転は EXIF の直しのあとに足し、切り抜きは回した後の絵に対して掛ける。[legacyFilter] は描画の中で掛ける今の行列。
     * 復号した画像は正立の画像を描き終えたらすぐに解放し、正立の画像は [use] から戻ったら（失敗・例外でも）解放する。
     */
    private inline fun <T> withUpright(
        photo: PickedPhoto,
        spec: JpegSpec,
        geometry: EditGeometry,
        legacyFilter: FilterId?,
        use: (upright: DecodedImage, fullAspect: Double) -> AppResult<T>,
    ): AppResult<T> {
        val unreadable = AppResult.Err(AppError.ImageUnreadable(photo.index))
        val stored = codec.readSize(photo.uri) ?: return unreadable
        if (stored.width <= 0 || stored.height <= 0) return unreadable

        // 手順 2：EXIF の向きの直しのあとに、利用者の回転を足した 1 つの操作（0 回なら EXIF の直しそのもの）
        val fix = orientationFixOf(readOrientationOrNone(photo.uri)).thenQuarterTurns(geometry.quarterTurns)
        val decoded = codec.decode(photo.uri, sampleSizeFor(stored.width, stored.height, spec.longEdge)) ?: return unreadable
        // 90 度・270 度の回転では、正立に直した後の幅と高さが入れ替わる（回した後の全体の絵の寸法）
        val turned = if (fix.swapsAxes) ImageSize(decoded.height, decoded.width) else ImageSize(decoded.width, decoded.height)
        val upright = try {
            // 手順 4：切り抜いた範囲の画素の寸法（四捨五入・各辺 1 以上。全体なら回した後の寸法そのまま）
            val cropped = cropPixelSize(turned.width, turned.height, geometry.crop)
            codec.transform(decoded, fix, geometry.crop, fittedSize(cropped.width, cropped.height, spec.longEdge), legacyFilter)
        } finally {
            codec.release(decoded)
        }
        try {
            return use(upright, turned.width.toDouble() / turned.height)
        } finally {
            codec.release(upright)
        }
    }

    /** [jpeg] が 5MB 以上なら、何枚目かとバイト数を載せた `ImageTooLarge`。未満なら null。 */
    private fun tooLarge(photo: PickedPhoto, jpeg: EncodedJpeg): AppResult.Err? =
        if (jpeg.bytes.size >= StorageGateway.MAX_UPLOAD_BYTES) {
            AppResult.Err(AppError.ImageTooLarge(photo.index, jpeg.bytes.size.toLong()))
        } else {
            null
        }

    /** EXIF の向きを読む。読めなければ 0（向きの記録が無い＝そのまま）にする。 */
    private fun readOrientationOrNone(uri: String): Int =
        try {
            codec.readExifOrientation(uri)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            0
        }
}
