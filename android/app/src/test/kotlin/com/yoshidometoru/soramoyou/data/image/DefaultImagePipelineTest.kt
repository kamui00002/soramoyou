// ⭐️ 写真の変換の入口の単体テスト：アイコン（prepare）の部分（タスク 16.1・22.1・要件 6.9・7.1・7.5・10.8）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlinx.coroutines.runBlocking

/**
 * 入口が、大きさ → 向き → 間引いて復号 → 回転・縮小（フィルターなし）→ 復号した画像の解放 → JPEG → 解放 の順で窓口（の偽物）を呼び、
 * 読めない写真を `ImageUnreadable`、5MB 以上を `ImageTooLarge` にすることを確かめる。投稿用（preparePost）は [DefaultImagePipelinePostTest]。
 * 画素そのもの（EXIF が出力に無いこと・向き・色）は JVM では確かめられないので、端末の `AndroidImageCodecDeviceTest` で見る。
 */
class DefaultImagePipelineTest {

    private val uri = "content://media/picker/0/photo/1"
    private val fiveMb = 5 * 1024 * 1024

    private val codec = FakeImageCodec()
    private val pipeline = DefaultImagePipeline(codec)

    private fun prepare(index: Int = 0, spec: JpegSpec = JpegSpec.ICON) = runBlocking { pipeline.prepare(PickedPhoto(uri, index), spec) }

    private fun ok(result: AppResult<PreparedImage>): PreparedImage = assertIs<AppResult.Ok<PreparedImage>>(result).value

    // ── 成功 ──

    @Test
    fun `大きい写真は、間引いて復号し、長辺1024へ縮小して品質90のJPEGにし、最後に解放する`() {
        codec.size = ImageSize(4000, 3000)

        val image = ok(prepare())

        assertEquals(
            listOf(
                "readSize($uri)",
                "readExifOrientation($uri)",
                "decode($uri, 2)",
                // 間引いた 2000 × 1500 を、長辺 1024 へ。アイコンにフィルターは無い
                "transform(2000x1500, ${OrientationFix.NONE}, ${ImageSize(1024, 768)}, null)",
                "release(2000x1500)",
                "encodeJpeg(t1:1024x768, 90)",
                "release(t1:1024x768)",
            ),
            codec.calls,
        )
        assertEquals(emptySet(), codec.live)
        assertContentEquals(codec.jpegBytes, image.body)
        assertEquals(1024 to 768, image.bodyWidth to image.bodyHeight)
    }

    @Test
    fun `向き6（時計回りに90度）の横長の画素は、幅と高さを入れ替えた縦長の大きさで縮小する`() {
        codec.size = ImageSize(4000, 3000)
        codec.orientation = 6

        val image = ok(prepare())

        assertEquals(
            "transform(2000x1500, ${OrientationFix(90, mirror = false)}, ${ImageSize(768, 1024)}, null)",
            codec.calls[3],
        )
        assertEquals(768 to 1024, image.bodyWidth to image.bodyHeight)
    }

    @Test
    fun `上限以下の小さい写真は、間引かず拡大もしない`() {
        codec.size = ImageSize(500, 400)

        ok(prepare())

        assertEquals("decode($uri, 1)", codec.calls[2])
        assertEquals("transform(500x400, ${OrientationFix.NONE}, ${ImageSize(500, 400)}, null)", codec.calls[3])
    }

    @Test
    fun `規格の長辺と品質をそのまま使う`() {
        codec.size = ImageSize(4096, 4096)

        ok(prepare(spec = JpegSpec(longEdge = 2048, quality = 80)))

        assertEquals("decode($uri, 2)", codec.calls[2])
        assertEquals("transform(2048x2048, ${OrientationFix.NONE}, ${ImageSize(2048, 2048)}, null)", codec.calls[3])
        assertEquals("encodeJpeg(t1:2048x2048, 80)", codec.calls[5])
    }

    @Test
    fun `アイコンはどの向きでも、向きの直しだけ・全体・フィルターなしで描き、色を掛けない`() {
        // Kiro android-edit-tools タスク 12・A1：投稿の変換に回転・切り抜き・色を足したが、アイコンは編集を持たないので、
        // EXIF の直しの操作そのもの・切り抜きは全体（記録の末尾に何も付かない）・applyColor は呼ばない
        for (exif in 0..8) {
            val fake = FakeImageCodec().apply {
                size = ImageSize(4000, 3000)
                orientation = exif
            }
            val fix = orientationFixOf(exif)
            val size = if (fix.swapsAxes) ImageSize(768, 1024) else ImageSize(1024, 768)
            val upright = "t1:${size.width}x${size.height}"

            val image = ok(runBlocking { DefaultImagePipeline(fake).prepare(PickedPhoto(uri, 0), JpegSpec.ICON) })

            assertEquals(
                listOf(
                    "readSize($uri)",
                    "readExifOrientation($uri)",
                    "decode($uri, 2)",
                    "transform(2000x1500, $fix, $size, null)",
                    "release(2000x1500)",
                    "encodeJpeg($upright, 90)",
                    "release($upright)",
                ),
                fake.calls,
                "向き $exif",
            )
            assertEquals(emptyList(), fake.colorCalls, "向き $exif")
            assertEquals(size.width to size.height, image.bodyWidth to image.bodyHeight, "向き $exif")
        }
    }

    @Test
    fun `向きを読めなくても、そのままの向きで変換を続ける（向きは画素の読み込みに必須ではない）`() {
        codec.size = ImageSize(800, 600)
        codec.orientationFailure = IOException("EXIF が壊れている")

        val image = ok(prepare())

        assertEquals("transform(800x600, ${OrientationFix.NONE}, ${ImageSize(800, 600)}, null)", codec.calls[3])
        assertEquals(800 to 600, image.bodyWidth to image.bodyHeight)
    }

    // ── 大きさ：5MB 以上は ImageTooLarge（storage.rules は「5MB 未満」）──

    @Test
    fun `変換後がちょうど5MBなら、何枚目かとバイト数を載せてImageTooLargeにし、解放はする`() {
        codec.jpegBytes = ByteArray(fiveMb)

        assertEquals(AppResult.Err(AppError.ImageTooLarge(index = 3, bytes = fiveMb.toLong())), prepare(index = 3))
        assertEquals("release(t1:1000x750)", codec.calls.last())
        assertEquals(emptySet(), codec.live)
    }

    @Test
    fun `5MBに1バイト足りなければ成功する`() {
        codec.jpegBytes = ByteArray(fiveMb - 1)

        assertEquals(fiveMb - 1, ok(prepare()).body.size)
    }

    // ── 読めない写真：ImageUnreadable（何枚目かを載せる）──

    @Test
    fun `大きさを読めなければ、復号せずにImageUnreadableにする`() {
        codec.size = null

        assertEquals(AppResult.Err(AppError.ImageUnreadable(index = 2)), prepare(index = 2))
        assertEquals(listOf("readSize($uri)"), codec.calls)
    }

    @Test
    fun `大きさが0なら、復号せずにImageUnreadableにする`() {
        codec.size = ImageSize(0, 0)

        assertEquals(AppResult.Err(AppError.ImageUnreadable(index = 0)), prepare())
        assertEquals(listOf("readSize($uri)"), codec.calls)
    }

    @Test
    fun `写真を開けない（読み込みの例外・権限の例外）ならImageUnreadableにする`() {
        for (failure in listOf(IOException("開けない"), SecurityException("権限が無い"))) {
            codec.calls.clear()
            codec.sizeFailure = failure

            assertEquals(AppResult.Err(AppError.ImageUnreadable(index = 1)), prepare(index = 1), "$failure")
        }
    }

    @Test
    fun `復号できなければImageUnreadableにし、JPEGにも解放にも進まない`() {
        codec.decodeReturnsNull = true

        assertEquals(AppResult.Err(AppError.ImageUnreadable(index = 0)), prepare())
        assertEquals(listOf("readSize($uri)", "readExifOrientation($uri)", "decode($uri, 1)"), codec.calls)
    }

    @Test
    fun `回転・縮小できなければImageUnreadableにし、復号した画像は解放してJPEGに進まない`() {
        codec.transformFailure = 1 to IllegalStateException("描けない")

        assertEquals(AppResult.Err(AppError.ImageUnreadable(index = 0)), prepare())
        assertEquals("release(1000x750)", codec.calls.last())
        assertEquals(emptySet(), codec.live)
    }

    @Test
    fun `JPEGにできなければImageUnreadableにし、作った画像も解放する`() {
        codec.encodeFailure = 1 to IOException("圧縮に失敗")

        assertEquals(AppResult.Err(AppError.ImageUnreadable(index = 0)), prepare())
        assertEquals("release(t1:1000x750)", codec.calls.last())
        assertEquals(emptySet(), codec.live)
    }

    // ── 取り消し ──

    @Test
    fun `コルーチンの取り消しは失敗に写さず、そのまま伝える`() {
        codec.sizeFailure = CancellationException("取り消し")

        assertFailsWith<CancellationException> { prepare() }
    }
}
