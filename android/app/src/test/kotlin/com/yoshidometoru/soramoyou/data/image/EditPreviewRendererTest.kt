// ⭐️ 編集のプレビューの絵を作る部品（DefaultEditPreviewRenderer）の単体テスト（Kiro android-edit-tools タスク 13・A3・design.md:1135）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.edit.ColorKernel
import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.EditGeometry
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.edit.ToolValues
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * プレビューの部品が、色の係数を自分で持たずに [ColorKernel] を呼んでいること（要件 11.5 の半分。焼き込みの側は端末の
 * `AndroidImageCodecDeviceTest` ⑤）と、写真の読み方（向きと利用者の回転の合成・切り抜き・寸法・品質・解放・失敗の扱い）を、
 * 窓口の偽物（[FakeImageCodec]）の呼ばれ方で確かめる。
 *
 * - [DefaultEditPreviewRenderer.render] の期待値も [ColorKernel] から作るので、[ColorKernel] の係数を変えてもこのテストは赤にならない。
 *   見ているのは「プレビューが自分の係数を持たず、受け取ったレシピをそのまま [ColorKernel] に渡していること」（design.md:1135）
 * - 期待する向きの直し（[OrientationFix]）は、本体の合成の関数を呼ばずに数字で書く（同じ関数から期待値を作ると、合成の取り違えを見逃すため）
 * - 描いた画素そのもの（向き・切り抜きの中身）は、端末の `EditPreviewRendererDeviceTest` で見る
 */
class EditPreviewRendererTest {

    private val uri = "content://media/picker/0/photo/9"

    private val codec = FakeImageCodec()
    private val analytics = RecordingAnalytics()
    private val renderer = DefaultEditPreviewRenderer(codec, analytics)

    /** 露出・明るさ・コントラストを動かした編集（灰や白だけの絵では、ツールによっては色が変わらないので、色を混ぜた絵と組む）。 */
    private val toolEdit = PhotoEdit(
        tools = ToolValues.NONE.with(EditTool.EXPOSURE, 50).with(EditTool.BRIGHTNESS, 20).with(EditTool.CONTRAST, 30),
    )

    /** 色を混ぜた 3×2 の絵（不透明の ARGB・行優先）。 */
    private val mixedPixels = intArrayOf(
        0xFF804020.toInt(), 0xFF20A0C0.toInt(), 0xFFE0E0E0.toInt(),
        0xFF101010.toInt(), 0xFF6090F0.toInt(), 0xFFC04080.toInt(),
    )

    private fun okBase(result: AppResult<PreviewBase>): PreviewBase = assertIs<AppResult.Ok<PreviewBase>>(result).value

    // ── render：色は ColorKernel だけが計算する ──

    @Test
    fun `renderは、同じ画素にColorKernelのrenderを掛けた結果と一致し、受け取った絵を書き換えない`() {
        val recipe = ColorRecipe.of(toolEdit)
        val base = PreviewBase(mixedPixels.copyOf(), 3, 2)
        // 期待値：同じ画素の写しに、範囲は全体・縦横比は 幅÷高さ で ColorKernel を掛けたもの
        val expected = mixedPixels.copyOf().also { ColorKernel.render(it, 3, 2, recipe, NormalizedRect.FULL, 3.0 / 2.0) }
        // 前提（陽性対照の空振りを防ぐ）：このレシピは絵を変える。変えないと、レシピを IDENTITY に差し替えても緑のままになる
        assertFalse(expected.contentEquals(mixedPixels), "前提：このレシピで絵が変わる")

        val actual = runBlocking { renderer.render(base, recipe) }

        assertContentEquals(expected, actual)
        assertContentEquals(mixedPixels, base.pixels, "受け取った絵は書き換えない（写しに掛ける）")
        assertNotSame(base.pixels, actual, "返すのは写し")
    }

    @Test
    fun `renderは、範囲を全体・縦横比を絵の幅÷高さにして掛ける（ビンテージの周辺減光の位置で見る）`() {
        // 8×2（幅÷高さ＝4）の一様な色。周辺減光は位置と縦横比で倍率が変わる
        val width = 8
        val height = 2
        val uniform = IntArray(width * height) { 0xFF8090A0.toInt() }
        val recipe = ColorRecipe.of(PhotoEdit(filter = FilterId.VINTAGE))
        val expected = uniform.copyOf().also { ColorKernel.render(it, width, height, recipe, NormalizedRect.FULL, 4.0) }
        // 前提：縦横比を 1 にすると値が変わる（縦横比を取り違えたら、このテストが赤になる）
        val squareAspect = uniform.copyOf().also { ColorKernel.render(it, width, height, recipe, NormalizedRect.FULL, 1.0) }
        assertFalse(expected.contentEquals(squareAspect), "前提：縦横比で周辺減光の値が変わる")

        val actual = runBlocking { renderer.render(PreviewBase(uniform.copyOf(), width, height), recipe) }

        assertContentEquals(expected, actual)
    }

    @Test
    fun `renderは、中立のレシピなら同じ画素の写しを返す`() {
        val base = PreviewBase(mixedPixels.copyOf(), 3, 2)

        val actual = runBlocking { renderer.render(base, ColorRecipe.IDENTITY) }

        assertContentEquals(mixedPixels, actual)
        assertNotSame(base.pixels, actual)
    }

    // ── loadBase：向きの直しと利用者の回転を 1 つの操作にして、切り抜きは全体・色なしで描き、画素を読む ──

    /** [loadBase] の 1 通り。[fix] と [size] は手で求めた期待値（本体の合成の関数から作らない）。 */
    private data class LoadCase(val orientation: Int, val quarterTurns: Int, val fix: OrientationFix, val size: ImageSize)

    @Test
    fun `loadBaseは、EXIFの直しに利用者の回転を足した操作と全体の切り抜きで描き、readPixelsの画素を返す`() {
        // 8000×6000 を長辺 1024 の既定で：1/4 に間引いて 2000×1500、回した後の向きで長辺 1024 へ縮める
        val cases = listOf(
            // 向き 1・回転なし：何もしない
            LoadCase(1, 0, OrientationFix(0, mirror = false), ImageSize(1024, 768)),
            // 向き 1・回転 1：時計回りに 90 度。幅と高さが入れ替わる
            LoadCase(1, 1, OrientationFix(90, mirror = false), ImageSize(768, 1024)),
            // 向き 6（時計回りに 90 度で直す）・回転 1：合わせて 180 度。幅と高さは入れ替わらない
            LoadCase(6, 1, OrientationFix(180, mirror = false), ImageSize(1024, 768)),
            // 向き 5（90 度回して左右に反転）・回転 1：反転の後の時計回りは、反転の前の反時計回りと同じなので 0 度＋反転
            LoadCase(5, 1, OrientationFix(0, mirror = true), ImageSize(1024, 768)),
            // 向き 1・回転 3：270 度
            LoadCase(1, 3, OrientationFix(270, mirror = false), ImageSize(768, 1024)),
            // 向き 8（270 度で直す）・回転 2：270＋180 で 90 度
            LoadCase(8, 2, OrientationFix(90, mirror = false), ImageSize(768, 1024)),
        )
        for (case in cases) {
            val codec = FakeImageCodec().apply {
                size = ImageSize(8000, 6000)
                orientation = case.orientation
                pixelColor = 0xFF336699.toInt()
            }
            val renderer = DefaultEditPreviewRenderer(codec, analytics)

            val base = okBase(runBlocking { renderer.loadBase(PickedPhoto(uri, 0), case.quarterTurns) })

            val upright = "t1:${case.size.width}x${case.size.height}"
            assertEquals(
                listOf(
                    "readSize($uri)",
                    "readExifOrientation($uri)",
                    // 長辺が 1024 を下回らない間引き：8000 を 1/4 で 2000（1/8 では 1000 で下回る）
                    "decode($uri, 4)",
                    // 合成した 1 つの操作・切り抜きは全体（偽物は全体のとき切り抜きを書かない）・フィルターは null（色は掛けない）
                    "transform(2000x1500, ${case.fix}, ${case.size}, null)",
                    // 描き終えたら、すぐに復号した画像を手放す
                    "release(2000x1500)",
                    "readPixels($upright)",
                    "release($upright)",
                ),
                codec.calls,
                "向き ${case.orientation}・回転 ${case.quarterTurns}",
            )
            assertEquals(case.size.width to case.size.height, base.width to base.height, "向き ${case.orientation}・回転 ${case.quarterTurns}")
            assertEquals(base.width * base.height, base.pixels.size)
            assertTrue(base.pixels.all { it == 0xFF336699.toInt() }, "画素は readPixels の値")
            assertEquals(emptySet(), codec.live, "描いた画像も解放している")
            assertEquals(2, codec.peakLive, "同時に持つ画像は 2 枚まで")
        }
        assertEquals(emptyList(), analytics.errors, "loadBase は記録しない")
    }

    @Test
    fun `loadBaseは、longEdgeを下回らない間引きと長辺longEdge以下の寸法で描く（フィルターの見本の112）`() {
        codec.size = ImageSize(8000, 6000)

        val base = okBase(runBlocking { renderer.loadBase(PickedPhoto(uri, 0), 0, EditPreviewRenderer.FILTER_SAMPLE_EDGE) })

        assertEquals(112, EditPreviewRenderer.FILTER_SAMPLE_EDGE)
        // 8000 を 1/64 で 125（1/128 では 62 で 112 を下回る）。6000/64 は 93
        assertEquals("decode($uri, 64)", codec.calls[2])
        assertEquals("transform(125x93, ${OrientationFix.NONE}, ${ImageSize(112, 83)}, null)", codec.calls[3])
        assertEquals(112 to 83, base.width to base.height)
    }

    @Test
    fun `loadBaseは、EXIFの向きを読めなければそのままの向きとして続ける`() {
        codec.orientationFailure = IOException("EXIF を読めない")

        val base = okBase(runBlocking { renderer.loadBase(PickedPhoto(uri, 0), 1) })

        // 1000×750 は間引かず縮めない。向きは「そのまま」に回転 1 を足した 90 度
        assertEquals("transform(1000x750, ${OrientationFix(90, mirror = false)}, ${ImageSize(750, 1000)}, null)", codec.calls[3])
        assertEquals(750 to 1000, base.width to base.height)
    }

    @Test
    fun `loadBaseは、読めない写真と窓口の失敗をImageUnreadableで返し、画像を全て解放し、記録しない`() {
        val photo = PickedPhoto(uri, 2)
        val setups: List<Pair<String, (FakeImageCodec) -> Unit>> = listOf(
            "大きさを読めない" to { c: FakeImageCodec ->c.size = null },
            "大きさが 0" to { c: FakeImageCodec ->c.size = ImageSize(0, 750) },
            "大きさを読む窓口の例外" to { c: FakeImageCodec ->c.sizeFailure = IOException("開けない") },
            "復号できない" to { c: FakeImageCodec ->c.decodeReturnsNull = true },
            "描けない" to { c: FakeImageCodec ->c.transformFailure = 1 to IOException("描けない") },
            "画素を読めない" to { c: FakeImageCodec ->c.readPixelsFailure = 1 to IllegalStateException("読めない") },
        )
        for ((name, setup) in setups) {
            val codec = FakeImageCodec().also(setup)
            val renderer = DefaultEditPreviewRenderer(codec, analytics)

            val result = runBlocking { renderer.loadBase(photo, 1) }

            assertEquals(AppResult.Err(AppError.ImageUnreadable(2)), result, name)
            assertEquals(emptySet(), codec.live, "$name：画像を全て解放している")
        }
        assertEquals(emptyList(), analytics.errors, "loadBase は記録しない")
    }

    @Test
    fun `loadBaseは、取り消しを失敗に写さずにそのまま伝え、画像を解放する`() {
        codec.transformFailure = 1 to CancellationException("取り消し")

        assertFailsWith<CancellationException> { runBlocking { renderer.loadBase(PickedPhoto(uri, 0), 0) } }

        assertEquals(emptySet(), codec.live)
        assertEquals(emptyList(), analytics.errors)
    }

    // ── draftThumbnail：回転→切り抜き→（必要なら）色→長辺 256・品質 80 の JPEG ──

    /** 下書きの見本の試験の切り抜き（回した後の絵の右下寄り。左右も上下も対称でない範囲）。 */
    private val thumbnailCrop = NormalizedRect(0.25, 0.5, 1.0, 1.0)

    @Test
    fun `draftThumbnailは、切り抜きとツールの色と長辺256と品質80で、この順に窓口を呼ぶ`() {
        codec.size = ImageSize(4000, 3000)
        val edit = toolEdit.copy(geometry = EditGeometry(quarterTurns = 1, crop = thumbnailCrop))
        val recipe = ColorRecipe.of(edit)

        val jpeg = runBlocking { renderer.draftThumbnail(PickedPhoto(uri, 0), edit) }

        assertEquals(256, EditPreviewRenderer.DRAFT_THUMBNAIL_EDGE)
        assertEquals(
            listOf(
                "readSize($uri)",
                "readExifOrientation($uri)",
                // 間引きは全体の寸法で決める：4000 を 1/8 で 500（1/16 では 250 で 256 を下回る）
                "decode($uri, 8)",
                // 回転 1 で 375×500。切り抜き（幅 0.75・高さ 0.5）で 281×250、長辺 256 へ縮めて 256×228。
                // ツールがあるので今の行列は描画の中で掛けない（null）
                "transform(500x375, ${OrientationFix(90, mirror = false)}, ${ImageSize(256, 228)}, null, $thumbnailCrop)",
                "release(500x375)",
                // 色は切り抜いた後の絵に、範囲＝切り抜き・縦横比＝回した後の全体の絵（375÷500）で掛ける
                "applyColor(t1:256x228, $recipe, $thumbnailCrop, 0.75)",
                "encodeJpeg(t1:256x228, 80)",
                "release(t1:256x228)",
            ),
            codec.calls,
        )
        val color = codec.colorCalls.single()
        assertEquals(recipe, color.recipe)
        assertEquals(thumbnailCrop, color.frame)
        assertEquals(0.75, color.fullAspect)
        assertContentEquals(codec.jpegBytes, assertNotNull(jpeg))
        assertEquals(emptySet(), codec.live)
        assertEquals(2, codec.peakLive, "同時に持つ画像は 2 枚まで")
        assertEquals(emptyList(), analytics.errors, "成功は記録しない")
    }

    @Test
    fun `draftThumbnailは、今の6種だけなら行列を描画の中で掛け、色を掛ける段を呼ばない`() {
        codec.size = ImageSize(4000, 3000)
        val edit = PhotoEdit(filter = FilterId.DRAMA, geometry = EditGeometry(quarterTurns = 1, crop = thumbnailCrop))

        assertNotNull(runBlocking { renderer.draftThumbnail(PickedPhoto(uri, 0), edit) })

        assertEquals(
            listOf(
                "readSize($uri)",
                "readExifOrientation($uri)",
                "decode($uri, 8)",
                "transform(500x375, ${OrientationFix(90, mirror = false)}, ${ImageSize(256, 228)}, drama, $thumbnailCrop)",
                "release(500x375)",
                "encodeJpeg(t1:256x228, 80)",
                "release(t1:256x228)",
            ),
            codec.calls,
        )
        assertEquals(emptyList(), codec.colorCalls)
    }

    @Test
    fun `draftThumbnailは、編集が無ければ全体を色なしで描く`() {
        codec.size = ImageSize(4000, 3000)

        assertNotNull(runBlocking { renderer.draftThumbnail(PickedPhoto(uri, 0), PhotoEdit.NONE) })

        assertEquals(
            listOf(
                "readSize($uri)",
                "readExifOrientation($uri)",
                "decode($uri, 8)",
                // 500×375 を長辺 256 へ。切り抜きは全体（偽物は書かない）・フィルターは null
                "transform(500x375, ${OrientationFix.NONE}, ${ImageSize(256, 192)}, null)",
                "release(500x375)",
                "encodeJpeg(t1:256x192, 80)",
                "release(t1:256x192)",
            ),
            codec.calls,
        )
        assertEquals(emptyList(), codec.colorCalls)
    }

    @Test
    fun `draftThumbnailは、色を掛ける段を、中立でも今の6種だけでもないときだけ呼ぶ`() {
        val tools = ToolValues.NONE.with(EditTool.FADE, 40)
        val cases = listOf(
            // 中立（「なし」とナチュラル）は掛けない
            PhotoEdit(filter = FilterId.NATURAL) to false,
            // 今の 6 種だけは描画の中の行列だけ
            PhotoEdit(filter = FilterId.VIVID) to false,
            // 行列を持たないフィルターは色を掛ける段で
            PhotoEdit(filter = FilterId.WARM) to true,
            PhotoEdit(filter = FilterId.VINTAGE) to true,
            // ツールが付けば、今の 6 種でも色を掛ける段で（行列も ColorKernel の中で掛かる）
            PhotoEdit(filter = FilterId.DRAMA, tools = tools) to true,
            PhotoEdit(tools = tools) to true,
        )
        for ((edit, applies) in cases) {
            val codec = FakeImageCodec()
            val renderer = DefaultEditPreviewRenderer(codec, analytics)

            assertNotNull(runBlocking { renderer.draftThumbnail(PickedPhoto(uri, 0), edit) }, "$edit")

            val recipe = ColorRecipe.of(edit)
            if (applies) {
                assertEquals(recipe, codec.colorCalls.single().recipe, "$edit")
                assertTrue(codec.calls.single { it.startsWith("transform(") }.endsWith(", null)"), "$edit：行列は描画の中で掛けない")
            } else {
                assertEquals(emptyList(), codec.colorCalls, "$edit")
                assertTrue(codec.calls.single { it.startsWith("transform(") }.endsWith(", ${recipe.legacyMatrixOnly?.raw})"), "$edit")
            }
        }
    }

    @Test
    fun `draftThumbnailは、失敗したらnullを返し、画像を全て解放し、ImageUnreadableを1回記録する`() {
        val photo = PickedPhoto(uri, 1)
        val withTools = toolEdit.copy(geometry = EditGeometry(quarterTurns = 0, crop = thumbnailCrop))
        val setups: List<Pair<String, (FakeImageCodec) -> Unit>> = listOf(
            "大きさを読めない" to { c: FakeImageCodec ->c.size = null },
            "大きさが 0" to { c: FakeImageCodec ->c.size = ImageSize(1000, 0) },
            "復号できない" to { c: FakeImageCodec ->c.decodeReturnsNull = true },
            "描けない" to { c: FakeImageCodec ->c.transformFailure = 1 to IOException("描けない") },
            "色を掛けられない" to { c: FakeImageCodec ->c.applyColorFailure = 1 to IllegalStateException("掛けられない") },
            "JPEG にできない" to { c: FakeImageCodec ->c.encodeFailure = 1 to IOException("圧縮できない") },
        )
        for ((name, setup) in setups) {
            val codec = FakeImageCodec().also(setup)
            val analytics = RecordingAnalytics()
            val renderer = DefaultEditPreviewRenderer(codec, analytics)

            val jpeg = runBlocking { renderer.draftThumbnail(photo, withTools) }

            assertNull(jpeg, name)
            assertEquals(emptySet(), codec.live, "$name：画像を全て解放している")
            assertEquals(
                listOf(RecordingAnalytics.LoggedError(AppError.ImageUnreadable(1), "EditPreviewRenderer.draftThumbnail")),
                analytics.errors,
                name,
            )
        }
    }

    @Test
    fun `draftThumbnailは、取り消しを失敗に写さずにそのまま伝え、記録しない`() {
        codec.encodeFailure = 1 to CancellationException("取り消し")

        assertFailsWith<CancellationException> { runBlocking { renderer.draftThumbnail(PickedPhoto(uri, 0), toolEdit) } }

        assertEquals(emptySet(), codec.live)
        assertEquals(emptyList(), analytics.errors)
    }
}
