// ⭐️ プレビュー（DefaultEditPreviewRenderer）と焼き込み（DefaultImagePipeline）の向きと切り抜きが一致することを、端末の本物の画像 API で確かめる（Kiro android-edit-tools タスク 13・A3・design.md:1151・要件 10.3）
package com.yoshidometoru.soramoyou.data.image

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.edit.EditGeometry
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import com.yoshidometoru.soramoyou.platform.ScreenName
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * プレビューの絵（[DefaultEditPreviewRenderer.loadBase]）と、投稿の焼き込み（[DefaultImagePipeline.preparePost]）が、
 * 同じ向きと同じ切り抜きの中身になること（要件 10.3。design.md:1151）を、端末の本物の窓口（[AndroidImageCodec]）で確かめる。
 * Firebase のエミュレータは使わない。実行は
 * `./gradlew :app:connectedEmulatorDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.yoshidometoru.soramoyou.data.image.EditPreviewRendererDeviceTest`
 * （仮想端末が要る）。切り抜きの描画と利用者の回転の焼き込みは A1（タスク 12）が入れるので、このテストは A1 の後に流す。
 *
 * ■ 絵の作り方
 * 保存された画素は 800×600（横長・正方形でない）の JPEG で、4×4 のます目をそれぞれ違う色（[PALETTE]・16 色）に塗る。
 * 左上のますが赤・右上が緑・左下が青・右下が黄。EXIF の向きを付ける（6＝時計回りに 90 度回して見る。5＝90 度回して左右に反転＝転置）。
 * 色はどれも、各色の値が 0・128・255 のどれかで、どの 2 色も少なくとも 1 つの色で 127 以上離れているので、
 * JPEG の誤差があっても、ますの真ん中の色を「いちばん近い色」で読めば取り違えない。
 *
 * ■ 期待値の作り方（本体の関数から作らない）
 * 保存されたますの位置を、手で書いた規則で動かす：EXIF の直し（6 は時計回りに 1 回、5 は時計回りに 1 回の後に左右に反転）の後に、
 * 利用者の回転（時計回りに quarterTurns 回）。時計回りに 1 回は (列, 行) → (3 − 行, 列)、左右に反転は (列, 行) → (3 − 列, 行)。
 * 本体の合成（`thenQuarterTurns`）は「反転の後の時計回り」を「反転の前の反時計回り」に読み替えるが、ここでは読み替えずに順に動かす。
 *
 * ■ 確かめること
 * 1. 回転 4 通りで、loadBase の赤い角と preparePost の赤い角が同じ位置にあり、どちらも 16 ますが期待のとおり
 *    （回転 1 と 3 を取り違えると、赤い角が反対側に来るので見分けられる。緑・青・黄の角で反転の取り違えも見分ける）
 * 2. 切り抜きを付けたとき、loadBase の絵の切り抜きの範囲と、preparePost の出力が同じ中身を指す
 * 3. draftThumbnail の JPEG が長辺 256 以下で、loadBase と同じ角が赤く、16 ますが期待のとおり
 */
@RunWith(AndroidJUnit4::class)
class EditPreviewRendererDeviceTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val codec = AndroidImageCodec(context.contentResolver)
    private val pipeline = DefaultImagePipeline(codec)
    private val analytics = RecordingAnalytics()
    private val renderer = DefaultEditPreviewRenderer(codec, analytics)
    private val dir = File(context.cacheDir, "edit-preview-renderer-device-test").apply { mkdirs() }

    @After
    fun deletePhotos() {
        dir.deleteRecursively()
    }

    // ── 1. 回転 4 通りの向き ──

    @Test
    fun 回転4通りで_loadBaseとpreparePostの赤い角が同じ位置にあり_どちらもます目が手で求めた並びになる() = runBlocking<Unit> {
        val mismatches = mutableListOf<String>()
        for (orientation in listOf(ExifInterface.ORIENTATION_ROTATE_90, ExifInterface.ORIENTATION_TRANSPOSE)) {
            val uri = writeGridJpeg("grid-$orientation", orientation)
            for (turns in 0..3) {
                val label = "向き $orientation・回転 $turns"
                val expected = expectedGrid(orientation, turns)
                val base = renderer.loadBase(PickedPhoto(uri, 0), turns).okValue()
                val post = pipeline.preparePost(PickedPhoto(uri, 0), PhotoEdit(geometry = EditGeometry(quarterTurns = turns))).okValue()
                val baseGrid = gridOf(base)
                val postGrid = decodeJpeg(post.body) { gridOf(it) }

                // 800×600 は 1024 にも 2048 にも収まるので、どちらも縮めない。寸法も同じになる
                if (base.width to base.height != post.bodyWidth to post.bodyHeight) {
                    mismatches += "$label：寸法 loadBase ${base.width}x${base.height}・preparePost ${post.bodyWidth}x${post.bodyHeight}"
                }
                if (redCorner(baseGrid) != redCorner(postGrid)) {
                    mismatches += "$label：赤い角 loadBase ${redCorner(baseGrid)}・preparePost ${redCorner(postGrid)}"
                }
                if (redCorner(baseGrid) != redCorner(expected)) {
                    mismatches += "$label：赤い角 loadBase ${redCorner(baseGrid)}・期待 ${redCorner(expected)}"
                }
                if (baseGrid != expected) mismatches += "$label：loadBase のます目 $baseGrid・期待 $expected"
                if (postGrid != expected) mismatches += "$label：preparePost のます目 $postGrid・期待 $expected"
            }
        }
        assertEquals("ずれ: $mismatches", emptyList<String>(), mismatches)
    }

    // ── 2. 切り抜きの範囲の中身 ──

    @Test
    fun 切り抜きを付けると_preparePostの出力はloadBaseの絵の同じ範囲と同じ中身になる() = runBlocking<Unit> {
        // 回した後の絵の右寄りの横長の範囲（列 1〜3・行 1〜2 のますの真ん中を含む。左右も上下も対称でない）
        val crop = NormalizedRect(0.25, 0.25, 1.0, 0.75)
        val uri = writeGridJpeg("grid-crop", ExifInterface.ORIENTATION_ROTATE_90)
        val mismatches = mutableListOf<String>()
        var compared = 0
        for (turns in 0..3) {
            val label = "回転 $turns"
            val expected = expectedGrid(ExifInterface.ORIENTATION_ROTATE_90, turns)
            val base = renderer.loadBase(PickedPhoto(uri, 0), turns).okValue()
            val post = pipeline.preparePost(PickedPhoto(uri, 0), PhotoEdit(geometry = EditGeometry(turns, crop))).okValue()
            decodeJpeg(post.body) { output ->
                for (row in 0 until GRID) {
                    for (col in 0 until GRID) {
                        // loadBase の絵（全体）の中の、ますの真ん中の位置（割合）
                        val fx = (col + 0.5) / GRID
                        val fy = (row + 0.5) / GRID
                        if (fx <= crop.left || fx >= crop.right || fy <= crop.top || fy >= crop.bottom) continue
                        // 同じ点の、切り抜いた出力の中の位置（割合）
                        val ux = (fx - crop.left) / crop.width
                        val uy = (fy - crop.top) / crop.height
                        val inBase = classify(base.pixels[pixelIndex(fy, base.height) * base.width + pixelIndex(fx, base.width)])
                        val inPost = classify(output.getPixel(pixelIndex(ux, output.width), pixelIndex(uy, output.height)))
                        compared++
                        if (inBase != inPost) mismatches += "$label：ます ($col, $row) loadBase $inBase・preparePost $inPost"
                        if (inBase != expected[row * GRID + col]) mismatches += "$label：ます ($col, $row) loadBase $inBase・期待 ${expected[row * GRID + col]}"
                    }
                }
            }
        }
        // 前提（空振りを防ぐ）：回転ごとに 3×2 のますを比べた
        assertEquals("比べたますの数", 4 * 6, compared)
        assertEquals("ずれ: $mismatches", emptyList<String>(), mismatches)
    }

    // ── 3. 下書きの見本 ──

    @Test
    fun draftThumbnailのJPEGは長辺256以下で_loadBaseと同じ角が赤い() = runBlocking<Unit> {
        val mismatches = mutableListOf<String>()
        for (orientation in listOf(ExifInterface.ORIENTATION_ROTATE_90, ExifInterface.ORIENTATION_TRANSPOSE)) {
            val uri = writeGridJpeg("grid-thumb-$orientation", orientation)
            for (turns in 0..3) {
                val label = "向き $orientation・回転 $turns"
                val expected = expectedGrid(orientation, turns)
                val base = renderer.loadBase(PickedPhoto(uri, 0), turns).okValue()
                // 回転だけの編集（色は変えない）
                val jpeg = checkNotNull(renderer.draftThumbnail(PickedPhoto(uri, 0), PhotoEdit(geometry = EditGeometry(quarterTurns = turns)))) {
                    "$label：見本を作れなかった（記録: ${analytics.errors}）"
                }
                decodeJpeg(jpeg) { thumbnail ->
                    if (maxOf(thumbnail.width, thumbnail.height) > EditPreviewRenderer.DRAFT_THUMBNAIL_EDGE) {
                        mismatches += "$label：見本の寸法 ${thumbnail.width}x${thumbnail.height} が長辺 256 を超える"
                    }
                    // 向き（縦長か横長か）が loadBase と同じ
                    if ((thumbnail.width > thumbnail.height) != (base.width > base.height)) {
                        mismatches += "$label：見本 ${thumbnail.width}x${thumbnail.height}・loadBase ${base.width}x${base.height} の向きが違う"
                    }
                    val thumbnailGrid = gridOf(thumbnail)
                    val baseGrid = gridOf(base)
                    if (redCorner(thumbnailGrid) != redCorner(baseGrid)) {
                        mismatches += "$label：赤い角 見本 ${redCorner(thumbnailGrid)}・loadBase ${redCorner(baseGrid)}"
                    }
                    if (thumbnailGrid != expected) mismatches += "$label：見本のます目 $thumbnailGrid・期待 $expected"
                }
            }
        }
        assertEquals("ずれ: $mismatches", emptyList<String>(), mismatches)
        assertTrue("見本の失敗の記録: ${analytics.errors}", analytics.errors.isEmpty())
    }

    // ── 道具 ──

    /**
     * 800×600 の、4×4 のます目を [PALETTE] で塗った絵を JPEG（品質 95）で書き、EXIF の向き [exifOrientation] を付けて、file の URI を返す。
     * 保存されたます (列, 行) の色は `PALETTE[列 + 4×行]`。
     */
    private fun writeGridJpeg(name: String, exifOrientation: Int): String {
        val bitmap = Bitmap.createBitmap(STORED_WIDTH, STORED_HEIGHT, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint()
        val cellWidth = STORED_WIDTH / GRID
        val cellHeight = STORED_HEIGHT / GRID
        for (row in 0 until GRID) {
            for (col in 0 until GRID) {
                paint.color = PALETTE[col + GRID * row].toColorInt()
                canvas.drawRect(
                    (col * cellWidth).toFloat(),
                    (row * cellHeight).toFloat(),
                    ((col + 1) * cellWidth).toFloat(),
                    ((row + 1) * cellHeight).toFloat(),
                    paint,
                )
            }
        }
        val file = File(dir, "$name.jpg")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        bitmap.recycle()
        ExifInterface(file).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, exifOrientation.toString())
            saveAttributes()
        }
        // 前提の確認：向きが書けている（書けていないと、向きの直しを確かめられない）
        assertEquals(exifOrientation, ExifInterface(file).getAttributeInt(ExifInterface.TAG_ORIENTATION, 0))
        return Uri.fromFile(file).toString()
    }

    /**
     * 出力の 4×4 のます (列, 行) に来る色の番号（[PALETTE] の位置）を、行優先で並べた期待値。
     * 保存されたますを、EXIF の直し → 利用者の回転（時計回りに [turns] 回）の順に、手で書いた規則で動かす（説明は class の KDoc）。
     */
    private fun expectedGrid(exifOrientation: Int, turns: Int): List<Int> {
        val grid = IntArray(GRID * GRID) { -1 }
        for (row in 0 until GRID) {
            for (col in 0 until GRID) {
                var c = col
                var r = row
                when (exifOrientation) {
                    // 6：時計回りに 90 度回して見る
                    ExifInterface.ORIENTATION_ROTATE_90 -> {
                        val next = rotateClockwise(c, r); c = next.first; r = next.second
                    }
                    // 5（転置）：時計回りに 90 度回してから、左右に反転する
                    ExifInterface.ORIENTATION_TRANSPOSE -> {
                        val next = rotateClockwise(c, r); c = GRID - 1 - next.first; r = next.second
                    }
                    else -> error("この試験で使わない向き: $exifOrientation")
                }
                repeat(turns) { val next = rotateClockwise(c, r); c = next.first; r = next.second }
                grid[r * GRID + c] = col + GRID * row
            }
        }
        check(grid.none { it < 0 }) { "期待値のます目に穴がある: ${grid.toList()}" }
        return grid.toList()
    }

    /** 4×4 のます目を時計回りに 90 度回したときの、ます (列, 行) の行き先：(3 − 行, 列)。 */
    private fun rotateClockwise(col: Int, row: Int): Pair<Int, Int> = (GRID - 1 - row) to col

    /** 赤（[PALETTE] の 0 番）のますがある角の名前。4 隅のどこにも無ければ「無し」。 */
    private fun redCorner(grid: List<Int>): String {
        val corners = listOf(
            "左上" to grid[0],
            "右上" to grid[GRID - 1],
            "右下" to grid[GRID * GRID - 1],
            "左下" to grid[GRID * (GRID - 1)],
        )
        return corners.filter { it.second == RED_INDEX }.joinToString("・") { it.first }.ifEmpty { "無し" }
    }

    /** プレビューの絵の 4×4 のますの真ん中の色の番号（行優先）。 */
    private fun gridOf(base: PreviewBase): List<Int> = (0 until GRID * GRID).map { i ->
        val x = pixelIndex((i % GRID + 0.5) / GRID, base.width)
        val y = pixelIndex((i / GRID + 0.5) / GRID, base.height)
        classify(base.pixels[y * base.width + x])
    }

    /** 画像の 4×4 のますの真ん中の色の番号（行優先）。 */
    private fun gridOf(bitmap: Bitmap): List<Int> = (0 until GRID * GRID).map { i ->
        classify(bitmap.getPixel(pixelIndex((i % GRID + 0.5) / GRID, bitmap.width), pixelIndex((i / GRID + 0.5) / GRID, bitmap.height)))
    }

    /** 割合 [fraction] の位置の画素の番号（0〜[length]−1）。 */
    private fun pixelIndex(fraction: Double, length: Int): Int = (fraction * length).toInt().coerceIn(0, length - 1)

    /** [color] にいちばん近い [PALETTE] の色の番号（赤・緑・青の差の 2 乗の和で比べる）。 */
    private fun classify(color: Int): Int {
        val r = Color.red(color)
        val g = Color.green(color)
        val b = Color.blue(color)
        return PALETTE.indices.minBy { i ->
            val p = PALETTE[i]
            (p.r - r) * (p.r - r) + (p.g - g) * (p.g - g) + (p.b - b) * (p.b - b)
        }
    }

    /** JPEG を復号して [use] に渡し、終わったら解放する。 */
    private fun <T> decodeJpeg(bytes: ByteArray, use: (Bitmap) -> T): T {
        val bitmap = checkNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size)) { "JPEG を復号できない" }
        try {
            return use(bitmap)
        } finally {
            bitmap.recycle()
        }
    }

    private fun <T> AppResult<T>.okValue(): T = when (this) {
        is AppResult.Ok -> value
        is AppResult.Err -> throw AssertionError("変換に失敗した: $error")
    }

    private data class Rgb(val r: Int, val g: Int, val b: Int) {
        fun toColorInt() = Color.rgb(r, g, b)
    }

    /** 下書きの見本の失敗の記録を控える分析の窓口の偽物（`src/test` の偽物は端末のテストから見えないので、ここに置く）。 */
    private class RecordingAnalytics : AnalyticsFacade {
        val errors = mutableListOf<Pair<AppError, String>>()
        override fun logEvent(name: EventName, params: Map<String, ParamValue>) = Unit
        override fun logScreen(name: ScreenName) = Unit
        override fun logError(error: AppError, context: String) {
            errors += error to context
        }
        override fun setUserId(uid: Uid?) = Unit
    }

    private companion object {
        /** 保存された画素の寸法（横長・正方形でない）。 */
        const val STORED_WIDTH = 800
        const val STORED_HEIGHT = 600

        /** ます目の縦横の数。 */
        const val GRID = 4

        /** 赤のますの色の番号（保存された絵の左上）。 */
        const val RED_INDEX = 0

        /**
         * ますの色（保存されたます (列, 行) は `PALETTE[列 + 4×行]`）。0 番＝左上が赤、3 番＝右上が緑、12 番＝左下が青、15 番＝右下が黄。
         * 各色の値は 0・128・255 のどれかで、どの 2 色も少なくとも 1 つの色で 127 以上離れている。
         */
        val PALETTE = listOf(
            Rgb(255, 0, 0), Rgb(128, 128, 128), Rgb(0, 128, 128), Rgb(0, 255, 0),
            Rgb(255, 255, 255), Rgb(0, 0, 0), Rgb(128, 0, 128), Rgb(255, 128, 0),
            Rgb(0, 255, 255), Rgb(128, 128, 0), Rgb(0, 0, 128), Rgb(255, 0, 255),
            Rgb(0, 0, 255), Rgb(128, 0, 0), Rgb(0, 128, 0), Rgb(255, 255, 0),
        )
    }
}
