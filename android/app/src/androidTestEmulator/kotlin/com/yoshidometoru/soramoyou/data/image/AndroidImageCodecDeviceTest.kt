// ⭐️ 写真の変換の本番の窓口（AndroidImageCodec）を、端末の本物の画像 API で確かめる（タスク 22.1・要件 7.1・7.2・7.4）
package com.yoshidometoru.soramoyou.data.image

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.net.Uri
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.edit.ColorKernel
import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.EditGeometry
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.edit.ToolValues
import com.yoshidometoru.soramoyou.contract.model.FilterId
import java.io.ByteArrayInputStream
import java.io.File
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * JVM の単体テストでは Android の画像 API が動かないので、窓口の本番の実装が「頼んだとおりの画素」を作ることを端末で確かめる。
 * Firebase のエミュレータは使わない。実行は
 * `./gradlew :app:connectedEmulatorDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.yoshidometoru.soramoyou.data.image.AndroidImageCodecDeviceTest`
 * （仮想端末が要る。終わると検証用のアプリ〔.emulator〕は端末から消える。本番用のアプリには触れない）。
 *
 * 1. 色の変換の尺度（出力側）：一様な色の写真に 6 種のフィルターを掛けた本体とサムネイルの中央の色が、[FilterId.legacyMatrix] を
 *    5 列目が 0〜255 の尺度として掛けた値と一致する（プレビュー側はタスク 21.2 で実測済み）。サムネイルにフィルターが二重に掛かっていないことも兼ねる。
 *    行列を持たない 4 種（ナチュラル・ウォーム・クール・ビンテージ）は、`ColorKernel.renderColor` をその位置で計算して四捨五入した値
 *    （Kiro android-edit-tools タスク 12・A1。K0 の時点の「入力の色のまま」から置き換えた。JPEG を通すので許し幅は [TOLERANCE]）
 * 2. 向き：4 色に塗り分けた画像に 8 通りの [OrientationFix] を掛け、4 隅の色が「時計回りに回してから左右に反転」の結果になる
 *    （Canvas は createBitmap と違い、回して負になった座標を自動で戻さない。戻し忘れると隅が黒くなる）
 * 3. 入口から通しで：EXIF の向き 6・撮影位置・撮影日時の付いた 3000×2000 の写真が、正立の縦長（長辺 2048・サムネイル 512）になり、出力に EXIF が無い
 * 4. サムネイルの縮小でモアレが出ない：細かい縦縞をサムネイルの寸法へ縮めても、うなりの帯にならない（タスク 25.4。本体は 1 回の双線形のまま）
 *
 * 以下は Kiro android-edit-tools タスク 12・A1（design.md:1150 の②〜⑤。①は上の 1〜4 が切り抜きなし・回転なしのまま緑であること）。
 * 5・7・8・9 は窓口から画素をそのまま読む（JPEG を通さない）。6 は入口から通すので JPEG を通す。
 * 5. 切り抜き（②）：左上を赤く塗った 4×4 の色の格子に、回転 4 通り×反転の有無×切り抜きの位置×縮める・縮めないを掛け、
 *    出力のどの画素も「回した後の絵の切り抜いた範囲」の同じ位置の色になり、4 辺の端の 1 画素も黒くない
 * 6. 入口から通しで（②）：利用者の回転 4 通りと切り抜きを付けて投稿にすると、本体が切り抜いた寸法になり、中身が同じ位置の色になる
 * 7. 今の 6 種（③）：[AndroidImageCodec.applyColor]（ColorKernel）で掛けた画素と、描画の中で行列を掛けた画素の差が各色 1 階調以内
 * 8. 帯の境目（④）：一様な絵にビンテージを掛けると、どの画素も「全体の絵の中の位置」で `ColorKernel.renderColor` を計算した値と
 *    1 階調以内（帯の境目に線が出ない）。64 行の帯を 3 回またぐ高さで、範囲が全体のときと切り抜いた範囲のときの 2 通り
 * 9. 焼き込みが ColorKernel を呼ぶこと（⑤・11.5）：一様な絵に、露出＋0.5・明るさ・コントラスト・色温度の入ったレシピなどを本物の
 *    [AndroidImageCodec.applyColor] で掛けた画素が、`ColorKernel.renderColor` の四捨五入と各色 1 階調以内
 */
@RunWith(AndroidJUnit4::class)
class AndroidImageCodecDeviceTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val codec = AndroidImageCodec(context.contentResolver)
    private val pipeline = DefaultImagePipeline(codec)
    private val dir = File(context.cacheDir, "image-codec-device-test").apply { mkdirs() }

    @After
    fun deletePhotos() {
        dir.deleteRecursively()
    }

    // ── 1. 色の変換の尺度 ──

    @Test
    fun 本体とサムネイルの色は_フィルターの行列を0から255の尺度で1回だけ掛けた値になる() = runBlocking {
        // 3000×2000 は、サムネイルが途中の画像（本体の半分）を経て縮む経路を通る。フィルターが二重に掛からないことを見る（タスク 25.4）
        val inputs = listOf(
            Triple("gray128", Rgb(128, 128, 128), 600 to 400),
            Triple("color200_100_50", Rgb(200, 100, 50), 600 to 400),
            Triple("color200_100_50_3000", Rgb(200, 100, 50), 3000 to 2000),
        )
        // 行列で比べるのは行列を持つ今の 6 種だけ。名前を書いておく（legacyMatrix() が null かどうかで分けると、行列が誤って消えても通ってしまう）。
        // 「なし」は入力の色のまま。行列を持たない新しい 4 種（ナチュラル・ウォーム・クール・ビンテージ）は、焼き込みが applyColor（ColorKernel）で
        // 掛けるので、ColorKernel.renderColor をその画素の位置で計算して四捨五入した値（Kiro android-edit-tools タスク 12・A1。
        // 実測 M1〜M3 の本物の中身を通るので、K1② の前後のどちらでも、焼き込みと同じ式の値になる）。
        // ここは JPEG を通した画素なので許し幅は今と同じ TOLERANCE。1 階調以内の比べは、JPEG を通さないテスト 7〜9 で見る
        val legacy: Set<FilterId?> = setOf(FilterId.CLEAR, FilterId.DRAMA, FilterId.SOFT, FilterId.MONOCHROME, FilterId.PASTEL, FilterId.VIVID)
        val mismatches = mutableListOf<String>()
        for ((name, input, dimensions) in inputs) {
            val uri = writePng(name, dimensions.first, dimensions.second) { it.drawColor(input.toColorInt()) }
            // 切り抜きも回転も無いので、回した後の全体の絵＝この写真（縦横比 3:2）
            val fullAspect = dimensions.first.toDouble() / dimensions.second
            for (filter in listOf<FilterId?>(null) + FilterId.entries) {
                val edit = if (filter == null) PhotoEdit.NONE else PhotoEdit(filter = filter)
                val prepared = pipeline.preparePost(PickedPhoto(uri, 0), edit).okValue()
                val body = centerOf(prepared.body)
                val thumbnail = centerOf(prepared.thumbnail)
                // 期待値は、読んだ画素の位置（その絵の中の画素の中心の割合）で作る（位置で変わるのはビンテージの周辺減光だけ）
                fun expectedAt(center: Center): Rgb = when {
                    filter in legacy -> input.times(checkNotNull(filter?.legacyMatrix()) { "$filter の行列が無い" })
                    filter == null -> input
                    else -> kernelRgb(input, ColorRecipe.of(edit), center.nx, center.ny, fullAspect)
                }
                val bodyExpected = expectedAt(body)
                val thumbnailExpected = expectedAt(thumbnail)
                // 記録用（期待値と実測を残す）。JPEG の誤差は ±TOLERANCE まで許す
                Log.i(TAG, "$name\t${filter?.raw}\texpected=$bodyExpected/$thumbnailExpected\tbody=${body.rgb}\tthumbnail=${thumbnail.rgb}")
                if (!body.rgb.near(bodyExpected)) mismatches += "$name/${filter?.raw} 本体 期待 $bodyExpected 実測 ${body.rgb}"
                if (!thumbnail.rgb.near(thumbnailExpected)) mismatches += "$name/${filter?.raw} サムネイル 期待 $thumbnailExpected 実測 ${thumbnail.rgb}"
            }
        }
        assertEquals("ずれ: $mismatches", emptyList<String>(), mismatches)
    }

    // ── 2. 向き ──

    @Test
    fun 向きの直し方8通りで_4隅の色が時計回りに回してから左右に反転した位置に来る() {
        // 左上 赤・右上 緑・左下 青・右下 白（保存された画素の並び）
        val quadrants = mapOf((0 to 0) to Color.RED, (1 to 0) to Color.GREEN, (0 to 1) to Color.BLUE, (1 to 1) to Color.WHITE)
        val uri = writePng("quadrants", 300, 200) { canvas ->
            val paint = Paint()
            for ((q, color) in quadrants) {
                paint.color = color
                canvas.drawRect(q.first * 150f, q.second * 100f, (q.first + 1) * 150f, (q.second + 1) * 100f, paint)
            }
        }
        val mismatches = mutableListOf<String>()
        for (rotation in listOf(0, 90, 180, 270)) {
            for (mirror in listOf(false, true)) {
                val fix = OrientationFix(rotation, mirror)
                val decoded = checkNotNull(codec.decode(uri, 1))
                val size = if (fix.swapsAxes) ImageSize(200, 300) else ImageSize(300, 200)
                val upright = codec.transform(decoded, fix, NormalizedRect.FULL, size, null)
                codec.release(decoded)
                val jpeg = try { codec.encodeJpeg(upright, 90) } finally { codec.release(upright) }
                val out = BitmapFactory.decodeByteArray(jpeg.bytes, 0, jpeg.bytes.size)
                assertEquals("$fix の寸法", size.width to size.height, out.width to out.height)
                for ((q, color) in quadrants) {
                    val moved = moveQuadrant(q, fix)
                    // 隅から 10px 内側（縁の 1px は双線形の混ざりを受けうるので避ける）。隅が黒ければ、平行移動の戻し忘れ
                    val x = if (moved.first == 0) 10 else out.width - 11
                    val y = if (moved.second == 0) 10 else out.height - 11
                    val actual = Rgb.of(out.getPixel(x, y))
                    if (!actual.near(Rgb.of(color))) mismatches += "$fix: 元の $q → $moved に ${Rgb.of(color)} のはずが $actual"
                }
                out.recycle()
            }
        }
        assertEquals("ずれ: $mismatches", emptyList<String>(), mismatches)
    }

    // ── 3. 入口から通しで ──

    @Test
    fun EXIFの向き6と撮影位置の付いた写真は_正立の縦長になり_出力にEXIFが無い() = runBlocking {
        val file = File(dir, "exif6.jpg")
        // 保存された画素は横長で、上半分が赤・下半分が青。向き 6（時計回りに 90 度回して見る）なので、正立では左が青・右が赤になる
        val source = Bitmap.createBitmap(3000, 2000, Bitmap.Config.ARGB_8888)
        Canvas(source).apply {
            drawColor(Color.RED)
            drawRect(0f, 1000f, 3000f, 2000f, Paint().apply { color = Color.BLUE })
        }
        file.outputStream().use { source.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        source.recycle()
        ExifInterface(file).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            setLatLong(35.6812, 139.7671)
            setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2026:10:09 07:30:00")
            saveAttributes()
        }
        // 前提の確認（陽性対照）：出力を調べるのと同じ読み方（バイト列から読む）で、入力には EXIF が読める
        ExifInterface(ByteArrayInputStream(file.readBytes())).let { input ->
            assertEquals(ExifInterface.ORIENTATION_ROTATE_90, input.getAttributeInt(ExifInterface.TAG_ORIENTATION, 0))
            assertTrue("入力に撮影位置がある", input.latLong != null)
            assertTrue("入力に撮影日時がある", input.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL) != null)
        }
        assertTrue("入力のバイト列に EXIF の区画がある", hasExifSegment(file.readBytes()))

        val prepared = pipeline.preparePost(PickedPhoto(Uri.fromFile(file).toString(), 0), PhotoEdit.NONE).okValue()

        assertEquals(1365 to 2048, prepared.bodyWidth to prepared.bodyHeight)
        val body = BitmapFactory.decodeByteArray(prepared.body, 0, prepared.body.size)
        val thumbnail = BitmapFactory.decodeByteArray(prepared.thumbnail, 0, prepared.thumbnail.size)
        assertEquals(1365 to 2048, body.width to body.height)
        assertEquals(341 to 512, thumbnail.width to thumbnail.height)
        for ((name, image) in listOf("本体" to body, "サムネイル" to thumbnail)) {
            val y = image.height / 2
            assertTrue("$name の左は青", Rgb.of(image.getPixel(image.width / 4, y)).near(Rgb(0, 0, 255)))
            assertTrue("$name の右は赤", Rgb.of(image.getPixel(image.width * 3 / 4, y)).near(Rgb(255, 0, 0)))
        }
        for ((name, bytes) in listOf("本体" to prepared.body, "サムネイル" to prepared.thumbnail)) {
            // ExifInterface の既定値に頼らない直接の検査：EXIF の区画そのものが無い
            assertTrue("$name のバイト列に EXIF の区画が無い", !hasExifSegment(bytes))
            val exif = ExifInterface(ByteArrayInputStream(bytes))
            assertNull("$name に撮影位置が無い", exif.latLong)
            assertNull("$name に撮影日時が無い", exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL))
            // ExifInterface は向きの記録が無いと null でなく既定値 0（UNDEFINED）を返す（2026-10-09 に端末で実測）。
            // 入力の 6 が残っていない（＝表示する側が二重に回さない）ことを見る
            assertEquals("$name の向きは指定なし（画素に焼き込み済み）", ExifInterface.ORIENTATION_UNDEFINED,
                exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, -1))
        }
    }

    // ── 4. サムネイルの縮小でモアレが出ない ──

    @Test
    fun 細かい縞をサムネイルの寸法へ縮めると_ほぼ一様な灰色になり_うなりの帯が出ない() = runBlocking {
        // 2048×1536 の、1 画素あたり 0.26 周期の明るさの縦縞（本体は縮めずにそのまま。サムネイルは 512 へ 1/4）。
        // 1 回の双線形で 1/4 に縮めると、4 画素おきの標本が縞に対して少しずつずれて、約 25 画素ごとに暗〜明を行き来する
        // 帯（元に無い模様＝モアレ）になる。0.5 倍の段を重ねて縮めれば、どこも 128 前後の灰色になる
        val uri = writePng("stripes", 2048, 1536) { canvas ->
            val paint = Paint()
            for (x in 0 until 2048) {
                val v = (128 + 127 * cos(2 * PI * 0.26 * x)).roundToInt()
                paint.color = Color.rgb(v, v, v)
                canvas.drawRect(x.toFloat(), 0f, x + 1f, 1536f, paint)
            }
        }
        val prepared = pipeline.preparePost(PickedPhoto(uri, 0), PhotoEdit.NONE).okValue()
        val thumbnail = BitmapFactory.decodeByteArray(prepared.thumbnail, 0, prepared.thumbnail.size)
        assertEquals(512 to 384, thumbnail.width to thumbnail.height)
        // 中央の行の 200 画素（帯なら約 8 周期分）の明るさ（緑）の幅。JPEG の誤差を含む
        val y = thumbnail.height / 2
        val greens = (thumbnail.width / 2 - 100 until thumbnail.width / 2 + 100).map { Color.green(thumbnail.getPixel(it, y)) }
        thumbnail.recycle()
        Log.i(TAG, "stripes\tmin=${greens.min()}\tmax=${greens.max()}")
        assertTrue("うなりの帯：明るさが ${greens.min()}〜${greens.max()}", greens.max() - greens.min() <= 40)
    }

    // ── 5. 切り抜き（Kiro android-edit-tools タスク 12・A1・design.md:1150 の②）──

    @Test
    fun 回転4通りと反転と切り抜きの位置で_出力のどの画素も切り抜いた範囲の同じ位置の色になり_端の1画素も黒くない() {
        // 左上が赤の 4×4 の色の格子（800×600・升は 200×150）。どの升の色も、どれかの色が 128 以上（混ざっても黒にならない）
        val uri = writeGridPng("grid")
        val decoded = checkNotNull(codec.decode(uri, 1))
        val mismatches = mutableListOf<String>()
        var strictChecks = 0
        try {
            for (rotation in listOf(0, 90, 180, 270)) {
                for (mirror in listOf(false, true)) {
                    val fix = OrientationFix(rotation, mirror)
                    val uprightWidth = if (fix.swapsAxes) GRID_HEIGHT else GRID_WIDTH
                    val uprightHeight = if (fix.swapsAxes) GRID_WIDTH else GRID_HEIGHT
                    for (crop in GRID_CROPS) {
                        val cropped = cropPixelSize(uprightWidth, uprightHeight, crop)
                        // 縮めない（倍率がほぼ 1）と、長辺 157 へ縮める（途中の縮小の段も入る）の 2 通り
                        for (size in listOf(cropped, fittedSize(cropped.width, cropped.height, 157))) {
                            val out = codec.transform(decoded, fix, crop, size, null)
                            val pixels = try {
                                assertEquals("$fix・$crop の寸法", size.width to size.height, out.width to out.height)
                                codec.readPixels(out)
                            } finally {
                                codec.release(out)
                            }
                            strictChecks += checkCropped(pixels, size, fix, crop, uprightWidth, uprightHeight, mismatches)
                        }
                    }
                }
            }
        } finally {
            codec.release(decoded)
        }
        Log.i(TAG, "crop\tstrictChecks=$strictChecks\tmismatches=${mismatches.size}")
        // 空振りしない：升の境目から離れた画素を、色まで比べた数が十分にある
        assertTrue("色まで比べた画素が少なすぎる: $strictChecks", strictChecks > 10_000)
        assertTrue("ずれ（${mismatches.size} 件のうち先頭 20 件）: ${mismatches.take(20)}", mismatches.isEmpty())
    }

    // ── 6. 入口から通しで、利用者の回転と切り抜き（②）──

    @Test
    fun 入口から通しで_利用者の回転と切り抜きを付けた本体は_切り抜いた寸法になり_回した後の範囲の中身になる() = runBlocking {
        val uri = writeGridPng("grid_post")
        val crop = NormalizedRect(0.123, 0.217, 0.871, 0.689)
        val mismatches = mutableListOf<String>()
        var strictChecks = 0
        for (quarterTurns in 0..3) {
            val prepared = pipeline.preparePost(PickedPhoto(uri, 0), PhotoEdit(geometry = EditGeometry(quarterTurns, crop))).okValue()
            // 写真に EXIF の向きは無いので、操作は利用者の回転だけ。800×600 は長辺 2048 以下なので、切り抜いた寸法のまま
            val fix = OrientationFix.NONE.thenQuarterTurns(quarterTurns)
            val uprightWidth = if (fix.swapsAxes) GRID_HEIGHT else GRID_WIDTH
            val uprightHeight = if (fix.swapsAxes) GRID_WIDTH else GRID_HEIGHT
            val size = cropPixelSize(uprightWidth, uprightHeight, crop)
            assertEquals("$quarterTurns 回の本体の寸法", size.width to size.height, prepared.bodyWidth to prepared.bodyHeight)
            val body = BitmapFactory.decodeByteArray(prepared.body, 0, prepared.body.size)
            assertEquals("$quarterTurns 回の JPEG の寸法", size.width to size.height, body.width to body.height)
            val pixels = IntArray(body.width * body.height).also { body.getPixels(it, 0, body.width, 0, 0, body.width, body.height) }
            body.recycle()
            // JPEG は 16 画素の升ごとに圧縮するので、升の境目から 24 画素より離れた所だけ色まで比べる
            strictChecks += checkCropped(pixels, size, fix, crop, uprightWidth, uprightHeight, mismatches, minMargin = 24.0)
        }
        Log.i(TAG, "crop_post\tstrictChecks=$strictChecks\tmismatches=${mismatches.size}")
        assertTrue("色まで比べた画素が少なすぎる: $strictChecks", strictChecks > 1_000)
        assertTrue("ずれ（${mismatches.size} 件のうち先頭 20 件）: ${mismatches.take(20)}", mismatches.isEmpty())
    }

    // ── 7. 今の 6 種：applyColor と描画の中の行列（③）──

    @Test
    fun 今の6種は_applyColorで掛けた画素と描画の中で行列を掛けた画素の差が各色1階調以内() {
        // いろいろな色を通すため、位置ごとに違う色の絵（256×96）。縮めない（画素はそのまま写る）ので、違いは色の計算だけ
        val width = 256
        val height = 96
        val uri = writePixelsPng("colors", width, height) { x, y -> Color.rgb(x, (x * 7 + y * 13) and 0xFF, (y * 8 + x / 3) and 0xFF) }
        val decoded = checkNotNull(codec.decode(uri, 1))
        val size = ImageSize(width, height)
        val mismatches = mutableListOf<String>()
        try {
            val input = codec.readPixels(decoded)
            for (filter in LEGACY_SIX) {
                val drawn = codec.transform(decoded, OrientationFix.NONE, NormalizedRect.FULL, size, filter)
                val byMatrix = try { codec.readPixels(drawn) } finally { codec.release(drawn) }
                val plain = codec.transform(decoded, OrientationFix.NONE, NormalizedRect.FULL, size, null)
                val byKernel = try {
                    codec.applyColor(plain, ColorRecipe.of(PhotoEdit(filter = filter)), NormalizedRect.FULL, width.toDouble() / height)
                    codec.readPixels(plain)
                } finally {
                    codec.release(plain)
                }
                var worst = 0
                var changed = 0
                for (i in byMatrix.indices) {
                    worst = maxOf(worst, Rgb.of(byMatrix[i]).maxDiff(Rgb.of(byKernel[i])))
                    if (Rgb.of(byMatrix[i]).maxDiff(Rgb.of(input[i])) > 1) changed++
                }
                Log.i(TAG, "legacy\t${filter.raw}\tworst=$worst\tchanged=$changed")
                // 空振りしない：行列が絵を変えている（両方とも入力のままなら、差が 0 でも何も確かめていない）。
                // 灰に近い画素は彩度の行列でほとんど変わらないので、見るのは 1 割以上の画素が 1 階調より大きく変わったこと
                if (changed < byMatrix.size / 10) mismatches += "${filter.raw}: 行列で変わった画素が少なすぎる（$changed）"
                if (worst > 1) mismatches += "${filter.raw}: applyColor と描画の中の行列が最大 $worst 階調ずれた"
            }
        } finally {
            codec.release(decoded)
        }
        assertEquals("ずれ: $mismatches", emptyList<String>(), mismatches)
    }

    // ── 8. 帯の境目（④）──

    @Test
    fun 一様な絵にビンテージを掛けると_どの画素も全体の絵の中の位置で計算した値と1階調以内で_帯の境目に線が出ない() {
        // 高さ 200 は 64 行の帯を 3 回またぎ、最後の帯は 8 行（64 の倍数にしない）
        val width = 120
        val height = 200
        val uri = writePixelsPng("uniform_vintage", width, height) { _, _ -> Color.rgb(200, 150, 100) }
        val recipe = ColorRecipe.of(PhotoEdit(filter = FilterId.VINTAGE))
        // 範囲が全体のときと、この絵が全体の絵の (0.1, 0.3)〜(0.7, 0.8) を切り抜いたものとみなすとき
        val frames = listOf(NormalizedRect.FULL, NormalizedRect(0.1, 0.3, 0.7, 0.8))
        val decoded = checkNotNull(codec.decode(uri, 1))
        val mismatches = mutableListOf<String>()
        try {
            for (frame in frames) {
                // 全体の絵の 幅÷高さ（この絵の寸法を範囲の割合で割り戻したもの）
                val fullAspect = (width / frame.width) / (height / frame.height)
                val image = codec.transform(decoded, OrientationFix.NONE, NormalizedRect.FULL, ImageSize(width, height), null)
                val (input, output) = try {
                    val before = codec.readPixels(image)
                    codec.applyColor(image, recipe, frame, fullAspect)
                    before to codec.readPixels(image)
                } finally {
                    codec.release(image)
                }
                var worst = 0
                var worstAt = ""
                // 帯の範囲を全体の範囲のままにした（壊れた）形の期待値と、正しい期待値が 1 階調より大きく違う画素の数
                var distinguishable = 0
                for (y in 0 until height) {
                    // 画素の中心の、全体の絵の中の位置（ColorKernel の「画素の位置」の式を、絵の全体について書いたもの）
                    val ny = frame.top + (y + 0.5) / height * frame.height
                    // 壊れた形：帯の中の行の位置を、範囲全体に当てはめたもの
                    val bandRows = minOf(BAND_ROWS, height - y / BAND_ROWS * BAND_ROWS)
                    val brokenNy = frame.top + (y % BAND_ROWS + 0.5) / bandRows * frame.height
                    for (x in 0 until width) {
                        val i = y * width + x
                        val nx = frame.left + (x + 0.5) / width * frame.width
                        val source = Rgb.of(input[i])
                        val expected = kernelRgb(source, recipe, nx, ny, fullAspect)
                        val diff = expected.maxDiff(Rgb.of(output[i]))
                        if (diff > worst) {
                            worst = diff
                            worstAt = "($x, $y) 期待 $expected 実測 ${Rgb.of(output[i])}"
                        }
                        if (kernelRgb(source, recipe, nx, brokenNy, fullAspect).maxDiff(expected) > 1) distinguishable++
                    }
                }
                // 記録用：帯の境目の前後の行（中央の列）の値
                val column = width / 2
                val seams = (BAND_ROWS until height step BAND_ROWS).joinToString { y ->
                    "$y:${Rgb.of(output[(y - 1) * width + column])}→${Rgb.of(output[y * width + column])}"
                }
                Log.i(TAG, "vintage_band\t$frame\tworst=$worst\tdistinguishable=$distinguishable\tseams=$seams")
                // 空振りしない：帯の範囲を取り違えたら分かるだけの、位置による違いがある
                if (distinguishable < width) mismatches += "$frame: 帯の範囲を取り違えても見分けられない（$distinguishable 画素）"
                if (worst > 1) mismatches += "$frame: 最大 $worst 階調ずれた $worstAt"
            }
        } finally {
            codec.release(decoded)
        }
        assertEquals("ずれ: $mismatches", emptyList<String>(), mismatches)
    }

    // ── 9. 焼き込みが ColorKernel を呼ぶこと（⑤・要件 11.5）──

    @Test
    fun 一様な絵にツールの入ったレシピを本物のapplyColorで掛けると_ColorKernelのrenderColorの四捨五入と各色1階調以内() {
        val width = 96
        val height = 72
        val inputColor = Rgb(120, 90, 60)
        val uri = writePixelsPng("uniform_tools", width, height) { _, _ -> inputColor.toColorInt() }
        // 最初の 1 つが設計の例（露出＋0.5・明るさ・コントラスト・色温度）。残りは新しい 3 種と、今の 6 種にツールを足したもの
        val recipes = listOf(
            "露出プラス0点5と明るさとコントラストと色温度" to ColorRecipe.of(
                PhotoEdit(tools = tools(EditTool.EXPOSURE to 50, EditTool.BRIGHTNESS to 20, EditTool.CONTRAST to 30, EditTool.COLOR_TEMPERATURE to 40)),
            ),
            "ウォーム" to ColorRecipe.of(PhotoEdit(filter = FilterId.WARM)),
            "クール" to ColorRecipe.of(PhotoEdit(filter = FilterId.COOL)),
            "ビンテージに露出" to ColorRecipe.of(PhotoEdit(filter = FilterId.VINTAGE, tools = tools(EditTool.EXPOSURE to -20))),
            "ドラマに彩度" to ColorRecipe.of(PhotoEdit(filter = FilterId.DRAMA, tools = tools(EditTool.SATURATION to 40))),
        )
        val fullAspect = width.toDouble() / height
        val decoded = checkNotNull(codec.decode(uri, 1))
        val mismatches = mutableListOf<String>()
        try {
            for ((name, recipe) in recipes) {
                val image = codec.transform(decoded, OrientationFix.NONE, NormalizedRect.FULL, ImageSize(width, height), null)
                val (input, output) = try {
                    val before = codec.readPixels(image)
                    codec.applyColor(image, recipe, NormalizedRect.FULL, fullAspect)
                    before to codec.readPixels(image)
                } finally {
                    codec.release(image)
                }
                var worst = 0
                var worstAt = ""
                for (y in 0 until height) {
                    for (x in 0 until width) {
                        val i = y * width + x
                        val expected = kernelRgb(Rgb.of(input[i]), recipe, (x + 0.5) / width, (y + 0.5) / height, fullAspect)
                        val diff = expected.maxDiff(Rgb.of(output[i]))
                        if (diff > worst) {
                            worst = diff
                            worstAt = "($x, $y) 期待 $expected 実測 ${Rgb.of(output[i])}"
                        }
                    }
                }
                val center = kernelRgb(inputColor, recipe, 0.5, 0.5, fullAspect)
                Log.i(TAG, "kernel\t$name\tworst=$worst\tinput=$inputColor\tcenterExpected=$center")
                if (worst > 1) mismatches += "$name: 最大 $worst 階調ずれた $worstAt"
            }
            // 空振りしない：設計の例のレシピは絵を 1 階調より大きく変える（掛けなかったら、上の比べが赤になる）
            val designExample = kernelRgb(inputColor, recipes.first().second, 0.5, 0.5, fullAspect)
            assertTrue("設計の例のレシピが色を変えない: $designExample", designExample.maxDiff(inputColor) > 1)
        } finally {
            codec.release(decoded)
        }
        assertEquals("ずれ: $mismatches", emptyList<String>(), mismatches)
    }

    // ── 道具 ──

    /** [draw] で描いた [width]×[height] の画像を PNG（劣化なし）で書き、file の URI を返す。 */
    private fun writePng(name: String, width: Int, height: Int, draw: (Canvas) -> Unit): String {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        draw(Canvas(bitmap))
        val file = File(dir, "$name.png")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        return Uri.fromFile(file).toString()
    }

    /**
     * JPEG の先頭のマーカーの並びに、EXIF の区画（APP1 = 0xFFE1 で、中身が "Exif\u0000\u0000" で始まる）があるか。
     * 画素の始まり（SOS = 0xFFDA）より前だけを見る。
     */
    private fun hasExifSegment(jpeg: ByteArray): Boolean {
        var i = 2   // 先頭の SOI（0xFFD8）の次から
        while (i + 4 <= jpeg.size && jpeg[i] == 0xFF.toByte()) {
            val marker = jpeg[i + 1].toInt() and 0xFF
            if (marker == 0xDA) return false
            val length = ((jpeg[i + 2].toInt() and 0xFF) shl 8) or (jpeg[i + 3].toInt() and 0xFF)
            if (marker == 0xE1 && i + 10 <= jpeg.size && String(jpeg, i + 4, 6, Charsets.ISO_8859_1) == "Exif\u0000\u0000") return true
            i += 2 + length
        }
        return false
    }

    private fun <T> AppResult<T>.okValue(): T = when (this) {
        is AppResult.Ok -> value
        is AppResult.Err -> throw AssertionError("変換に失敗した: $error")
    }

    /** JPEG の中央の画素の色と、その画素の中心の位置（絵の中の割合。ビンテージの期待値を位置で作るため） */
    private class Center(val rgb: Rgb, val nx: Double, val ny: Double)

    private fun centerOf(jpeg: ByteArray): Center {
        val bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
        val x = bitmap.width / 2
        val y = bitmap.height / 2
        return Center(Rgb.of(bitmap.getPixel(x, y)), (x + 0.5) / bitmap.width, (y + 0.5) / bitmap.height).also { bitmap.recycle() }
    }

    /** 画素ごとの色を [colorAt]（x, y → 不透明の ARGB）で決めた [width]×[height] の画像を PNG（劣化なし）で書き、file の URI を返す。 */
    private fun writePixelsPng(name: String, width: Int, height: Int, colorAt: (Int, Int) -> Int): String {
        val pixels = IntArray(width * height) { colorAt(it % width, it / width) }
        val bitmap = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
        val file = File(dir, "$name.png")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        return Uri.fromFile(file).toString()
    }

    /** 左上が赤の 4×4 の色の格子（[GRID_WIDTH]×[GRID_HEIGHT]・升は [CELL_WIDTH]×[CELL_HEIGHT]）を PNG で書き、file の URI を返す。 */
    private fun writeGridPng(name: String): String =
        writePixelsPng(name, GRID_WIDTH, GRID_HEIGHT) { x, y -> GRID_COLORS[y / CELL_HEIGHT][x / CELL_WIDTH] }

    /** スライダーの値（百分の 1）を並べたツールの値。 */
    private fun tools(vararg values: Pair<EditTool, Int>): ToolValues =
        values.fold(ToolValues.NONE) { acc, (tool, value) -> acc.with(tool, value) }

    /**
     * [input] に [recipe] を、全体の絵の中の位置（[nx], [ny]）で `ColorKernel.renderColor` で掛け、255 倍して四捨五入した色。
     * 焼き込みの期待値（`ColorKernel.render` は同じ式を通り、最後に同じく四捨五入する）。
     */
    private fun kernelRgb(input: Rgb, recipe: ColorRecipe, nx: Double, ny: Double, fullAspect: Double): Rgb {
        val c = ColorKernel.renderColor(input.r / 255.0, input.g / 255.0, input.b / 255.0, recipe, nx, ny, fullAspect)
        return Rgb((c[0] * 255.0).roundToInt(), (c[1] * 255.0).roundToInt(), (c[2] * 255.0).roundToInt())
    }

    /**
     * 格子の絵を [fix] で回し、回した後の絵（[uprightWidth]×[uprightHeight]）の [crop] の範囲を [size] に描いた画素 [pixels] を確かめ、
     * 色まで比べた画素の数を返す。ずれは [mismatches] に足す。
     *
     * - 見るのは、4 辺の全画素と、内側の 4 画素おきの画素
     * - どれも黒くない（格子のどの升の色も、どれかの色が 128 以上なので、双線形で混ざっても黒くはならない。描かれずに残った所だけが黒い）
     * - 出力の画素の中心が元の絵のどこに当たるかを座標の式で独立に計算し（本体の行列は使わない）、升の境目から
     *   [minMargin] と「双線形と途中の縮小が混ぜる範囲」の広い方より離れていれば、その升の色と ±[TOLERANCE]
     */
    private fun checkCropped(
        pixels: IntArray,
        size: ImageSize,
        fix: OrientationFix,
        crop: NormalizedRect,
        uprightWidth: Int,
        uprightHeight: Int,
        mismatches: MutableList<String>,
        minMargin: Double = 0.0,
    ): Int {
        val label = "$fix・$crop・${size.width}x${size.height}"
        // 出力の 1 画素が、元の絵の何画素ぶんに当たるか（回転では変わらない）
        val sourcePerOutput = maxOf(uprightWidth * crop.width / size.width, uprightHeight * crop.height / size.height)
        val margin = maxOf(minMargin, 3.0 * sourcePerOutput + 2.0)
        var strict = 0
        fun check(ox: Int, oy: Int, onEdge: Boolean) {
            val actual = Rgb.of(pixels[oy * size.width + ox])
            if (actual.isDark()) mismatches += "$label: ${if (onEdge) "端" else "内側"}の ($ox, $oy) が黒い $actual"
            // 出力の画素の中心 → 回した後の絵の位置（切り抜く範囲の左上から、範囲の寸法÷出力の寸法 の刻みで進む）
            val ux = uprightWidth * crop.left + (ox + 0.5) * uprightWidth * crop.width / size.width
            val uy = uprightHeight * crop.top + (oy + 0.5) * uprightHeight * crop.height / size.height
            val (sx, sy) = sourcePointOf(ux, uy, fix, uprightWidth)
            if (distanceToCellBorder(sx, sy) < margin) return
            strict++
            val expected = Rgb.of(gridColorAt(sx, sy))
            if (!actual.near(expected)) {
                mismatches += "$label: ($ox, $oy) は元の (${sx.roundToInt()}, ${sy.roundToInt()}) の $expected のはずが $actual"
            }
        }
        for (ox in 0 until size.width) {
            check(ox, 0, onEdge = true)
            check(ox, size.height - 1, onEdge = true)
        }
        for (oy in 0 until size.height) {
            check(0, oy, onEdge = true)
            check(size.width - 1, oy, onEdge = true)
        }
        for (oy in 2 until size.height - 2 step 4) {
            for (ox in 2 until size.width - 2 step 4) check(ox, oy, onEdge = false)
        }
        return strict
    }

    /**
     * 回した後の絵の位置（[ux], [uy]）が、元の格子の絵のどこに当たるか。
     * [OrientationFix] は「時計回りに回してから左右に反転」なので、反転を先に戻し（幅 [uprightWidth] の中で左右を戻す）、次に回転を戻す。
     */
    private fun sourcePointOf(ux: Double, uy: Double, fix: OrientationFix, uprightWidth: Int): Pair<Double, Double> {
        val rx = if (fix.mirror) uprightWidth - ux else ux
        val ry = uy
        return when (fix.rotationDegrees) {
            0 -> rx to ry
            // 時計回りに 90 度：元の (x, y) は (高さ − y, x) へ動く
            90 -> ry to (GRID_HEIGHT - rx)
            // 180 度：元の (x, y) は (幅 − x, 高さ − y) へ動く
            180 -> (GRID_WIDTH - rx) to (GRID_HEIGHT - ry)
            // 時計回りに 270 度：元の (x, y) は (y, 幅 − x) へ動く
            270 -> (GRID_WIDTH - ry) to rx
            else -> error("回転は 90 度刻み: ${fix.rotationDegrees}")
        }
    }

    /** 元の格子の位置から、いちばん近い升の境目（絵の外周は境目でない）までの距離（画素） */
    private fun distanceToCellBorder(sx: Double, sy: Double): Double {
        val dx = (1 until GRID_COLUMNS).minOf { abs(sx - it * CELL_WIDTH) }
        val dy = (1 until GRID_ROWS).minOf { abs(sy - it * CELL_HEIGHT) }
        return minOf(dx, dy)
    }

    /** 元の格子の位置の升の色 */
    private fun gridColorAt(sx: Double, sy: Double): Int {
        val column = floor(sx / CELL_WIDTH).toInt().coerceIn(0, GRID_COLUMNS - 1)
        val row = floor(sy / CELL_HEIGHT).toInt().coerceIn(0, GRID_ROWS - 1)
        return GRID_COLORS[row][column]
    }

    /** 象限 [q]（x, y が 0 か 1）が、時計回りに [OrientationFix.rotationDegrees] 度回してから、[OrientationFix.mirror] なら左右に反転した後に来る象限。 */
    private fun moveQuadrant(q: Pair<Int, Int>, fix: OrientationFix): Pair<Int, Int> {
        var (x, y) = q
        repeat(fix.rotationDegrees / 90) { val nx = 1 - y; y = x; x = nx }   // 時計回りに 90 度：(x, y) → (1 − y, x)
        if (fix.mirror) x = 1 - x
        return x to y
    }

    private data class Rgb(val r: Int, val g: Int, val b: Int) {
        fun toColorInt() = Color.rgb(r, g, b)

        fun near(other: Rgb) = abs(r - other.r) <= TOLERANCE && abs(g - other.g) <= TOLERANCE && abs(b - other.b) <= TOLERANCE

        /** 3 色のうち、いちばん大きい差（階調） */
        fun maxDiff(other: Rgb) = maxOf(abs(r - other.r), abs(g - other.g), abs(b - other.b))

        /** どの色も 40 未満（黒か、黒に近い） */
        fun isDark() = maxOf(r, g, b) < 40

        /** 4×5 の行列 [m]（5 列目は 0〜255 の尺度）を掛け、0〜255 に収めて四捨五入する。不透明度は 255。 */
        fun times(m: FloatArray): Rgb {
            fun row(i: Int) = (m[i * 5] * r + m[i * 5 + 1] * g + m[i * 5 + 2] * b + m[i * 5 + 3] * 255 + m[i * 5 + 4])
                .coerceIn(0f, 255f).roundToInt()
            return Rgb(row(0), row(1), row(2))
        }

        companion object {
            fun of(color: Int) = Rgb(Color.red(color), Color.green(color), Color.blue(color))
        }
    }

    private companion object {
        const val TAG = "ImageCodecDeviceTest"

        /** JPEG（品質 90）の色の誤差の許容。5 列目の尺度を取り違えると、少なくとも 6 ずれる（クリアの灰 128 で 134） */
        const val TOLERANCE = 3

        /**
         * 本体の applyColor の帯の行数（AndroidImageCodec の BAND_ROWS と同じ 64：design.md:885）。
         * 帯の境目のテストが「帯の範囲を全体の範囲のままにした」壊れた形の期待値を作るのに使う（本体の値は読まない）
         */
        const val BAND_ROWS = 64

        /** 行列を持つ今の 6 種 */
        val LEGACY_SIX = listOf(FilterId.CLEAR, FilterId.DRAMA, FilterId.SOFT, FilterId.MONOCHROME, FilterId.PASTEL, FilterId.VIVID)

        /** 切り抜きのテストの格子の絵の寸法と升の数（升は 200×150） */
        const val GRID_WIDTH = 800
        const val GRID_HEIGHT = 600
        const val GRID_COLUMNS = 4
        const val GRID_ROWS = 4
        const val CELL_WIDTH = GRID_WIDTH / GRID_COLUMNS
        const val CELL_HEIGHT = GRID_HEIGHT / GRID_ROWS

        /** 格子の升の色（行ごと）。左上は赤。どの色も、どれかの色が 128 以上で、どの 2 つも少なくとも 1 色で 100 以上違う */
        val GRID_COLORS: List<List<Int>> = listOf(
            listOf(Color.rgb(255, 0, 0), Color.rgb(0, 255, 0), Color.rgb(0, 0, 255), Color.rgb(255, 255, 0)),
            listOf(Color.rgb(0, 255, 255), Color.rgb(255, 0, 255), Color.rgb(255, 128, 0), Color.rgb(128, 0, 255)),
            listOf(Color.rgb(0, 128, 255), Color.rgb(128, 255, 0), Color.rgb(255, 0, 128), Color.rgb(0, 255, 128)),
            listOf(Color.rgb(255, 255, 255), Color.rgb(128, 128, 255), Color.rgb(255, 128, 128), Color.rgb(128, 255, 128)),
        )

        /**
         * 切り抜きの範囲（回した後の絵に対する割合）。どれも左と上が 0 でない（切り抜きの平行移動を外すと、どれでも違う中身になる）。
         * 升の境目にそろう範囲・端数の出る内側の範囲・赤い角を含む範囲・右と下の端に接する範囲
         */
        val GRID_CROPS = listOf(
            NormalizedRect(0.5, 0.25, 1.0, 0.75),
            NormalizedRect(0.25, 0.5, 0.75, 1.0),
            NormalizedRect(0.123, 0.217, 0.871, 0.689),
            NormalizedRect(0.1, 0.1, 0.6, 0.6),
            NormalizedRect(0.3, 0.4, 1.0, 1.0),
        )
    }
}
