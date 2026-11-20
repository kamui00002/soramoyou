// ⭐️ 写真の変換の入口の単体テスト：投稿用（preparePost）の部分（タスク 22.1・要件 6.9・7.1・7.3・7.4・7.5）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.EditGeometry
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.edit.ToolValues
import com.yoshidometoru.soramoyou.contract.model.FilterId
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * 投稿用の変換が、本体（長辺 2048・品質 90・フィルターあり）と、本体と同じ画素から作るサムネイル（長辺 512・品質 80・フィルターを重ねない）を、
 * 同時に持つ画像を 2 枚までにして作ること、5MB 以上と読めない写真を断ることを、窓口（の偽物）の呼ばれ方で確かめる。
 * 色の変換の中身（行列の値・尺度）は FilterIdTest、描いた画素は端末の `AndroidImageCodecDeviceTest` で見る。
 *
 * 編集（回転・切り抜き・色）の渡し方は、末尾の「編集」の節（Kiro android-edit-tools タスク 12・A1・design.md:1134 の①〜⑥）で見る。
 */
class DefaultImagePipelinePostTest {

    private val uri = "content://media/picker/0/photo/7"
    private val fiveMb = 5 * 1024 * 1024

    private val codec = FakeImageCodec()
    private val pipeline = DefaultImagePipeline(codec)

    /** [filter] だけを掛ける編集（null は [PhotoEdit.NONE]）で投稿用に変換する（引数の形は Kiro android-edit-tools タスク 2.4・K0）。 */
    private fun preparePost(filter: FilterId? = FilterId.DRAMA, index: Int = 0) =
        runBlocking { pipeline.preparePost(PickedPhoto(uri, index), editOf(filter)) }

    private fun editOf(filter: FilterId?): PhotoEdit = if (filter == null) PhotoEdit.NONE else PhotoEdit(filter = filter)

    private fun ok(result: AppResult<PreparedPostImage>): PreparedPostImage = assertIs<AppResult.Ok<PreparedPostImage>>(result).value

    // ── 規格（設計書 Q5）──

    @Test
    fun `投稿の規格は、本体が長辺2048・品質90、サムネイルが長辺512・品質80`() {
        assertEquals(JpegSpec(longEdge = 2048, quality = 90), JpegSpec.POST_BODY)
        assertEquals(JpegSpec(longEdge = 512, quality = 80), JpegSpec.POST_THUMBNAIL)
    }

    // ── 成功：順序・寸法・品質・フィルター・解放 ──

    @Test
    fun `48MP相当の写真は、間引いて復号し、本体を描いたら復号した画像を解放し、本体の画素からサムネイルを作る`() {
        codec.size = ImageSize(8000, 6000)
        val body = ByteArray(2_000_000) { 1 }
        val thumbnail = ByteArray(80_000) { 2 }
        codec.jpegBytesQueue += listOf(body, thumbnail)

        val image = ok(preparePost(FilterId.DRAMA))

        assertEquals(
            listOf(
                "readSize($uri)",
                "readExifOrientation($uri)",
                // 8000 を 1/2 で 4000（1/4 では 2000 で 2048 を下回る）
                "decode($uri, 2)",
                // 回転・縮小・フィルターを 1 回で描く
                "transform(4000x3000, ${OrientationFix.NONE}, ${ImageSize(2048, 1536)}, drama)",
                // 本体を描いたら、すぐに復号した画像を手放す（サムネイルを作る前）
                "release(4000x3000)",
                "encodeJpeg(t1:2048x1536, 90)",
                // サムネイルは本体と同じ画素から。フィルターは本体で掛け済みなので重ねない
                "transform(t1:2048x1536, ${OrientationFix.NONE}, ${ImageSize(512, 384)}, null)",
                "encodeJpeg(t2:512x384, 80)",
                "release(t2:512x384)",
                "release(t1:2048x1536)",
            ),
            codec.calls,
        )
        assertContentEquals(body, image.body)
        assertContentEquals(thumbnail, image.thumbnail)
        assertEquals(2048 to 1536, image.bodyWidth to image.bodyHeight)
        // 同時に持つ画像は 2 枚まで、終わったら全て手放している
        assertEquals(2, codec.peakLive)
        assertEquals(emptySet(), codec.live)
    }

    @Test
    fun `フィルターは本体にだけ、選んだものをそのまま渡し、「なし」はnullで渡す`() {
        // 今の 6 種は選んだものをそのまま、「なし」（PhotoEdit.NONE）は null で渡す。
        // 行列を持たない新しい 4 種（ナチュラル・ウォーム・クール・ビンテージ）は渡さない（null：design.md:788・876）
        val legacy = listOf(FilterId.CLEAR, FilterId.DRAMA, FilterId.SOFT, FilterId.MONOCHROME, FilterId.PASTEL, FilterId.VIVID)
        for (filter in FilterId.entries + listOf<FilterId?>(null)) {
            codec.calls.clear()

            ok(preparePost(filter))

            val transforms = codec.calls.filter { it.startsWith("transform(") }
            assertEquals(2, transforms.size, "$filter")
            val passed = filter?.takeIf { it in legacy }
            assertTrue(transforms[0].endsWith(", ${passed?.raw})"), "本体（$filter）: ${transforms[0]}")
            assertTrue(transforms[1].endsWith(", null)"), "サムネイル: ${transforms[1]}")
        }
    }

    @Test
    fun `向き6の横長の画素は、本体もサムネイルも正立の縦長の寸法で作る`() {
        codec.size = ImageSize(8000, 6000)
        codec.orientation = 6

        val image = ok(preparePost())

        assertEquals("transform(4000x3000, ${OrientationFix(90, mirror = false)}, ${ImageSize(1536, 2048)}, drama)", codec.calls[3])
        // サムネイルは正立済みの本体から作るので、向きは直さない
        assertEquals("transform(t1:1536x2048, ${OrientationFix.NONE}, ${ImageSize(384, 512)}, null)", codec.calls[6])
        assertEquals(1536 to 2048, image.bodyWidth to image.bodyHeight)
    }

    @Test
    fun `本体の上限以下・サムネイルの上限より大きい写真は、本体を縮小せずサムネイルだけ縮小する`() {
        codec.size = ImageSize(1000, 750)

        val image = ok(preparePost())

        assertEquals("decode($uri, 1)", codec.calls[2])
        assertEquals("transform(1000x750, ${OrientationFix.NONE}, ${ImageSize(1000, 750)}, drama)", codec.calls[3])
        assertEquals("transform(t1:1000x750, ${OrientationFix.NONE}, ${ImageSize(512, 384)}, null)", codec.calls[6])
        assertEquals(1000 to 750, image.bodyWidth to image.bodyHeight)
    }

    @Test
    fun `サムネイルの上限以下の小さい写真は、どちらも拡大しない`() {
        codec.size = ImageSize(400, 300)

        ok(preparePost())

        assertEquals("transform(400x300, ${OrientationFix.NONE}, ${ImageSize(400, 300)}, drama)", codec.calls[3])
        assertEquals("transform(t1:400x300, ${OrientationFix.NONE}, ${ImageSize(400, 300)}, null)", codec.calls[6])
    }

    // ── 大きさ：5MB 以上は ImageTooLarge（storage.rules は本体もサムネイルも「5MB 未満」）──

    @Test
    fun `本体がちょうど5MBなら、サムネイルを作らずにImageTooLargeにし、作った画像は全て解放する`() {
        codec.jpegBytesQueue += ByteArray(fiveMb)

        assertEquals(AppResult.Err(AppError.ImageTooLarge(index = 4, bytes = fiveMb.toLong())), preparePost(index = 4))
        assertEquals(1, codec.calls.count { it.startsWith("transform(") })
        assertEquals("release(t1:1000x750)", codec.calls.last())
        assertEquals(emptySet(), codec.live)
    }

    @Test
    fun `サムネイルがちょうど5MBなら、サムネイルのバイト数を載せてImageTooLargeにし、作った画像は全て解放する`() {
        codec.jpegBytesQueue += listOf(ByteArray(1024), ByteArray(fiveMb))

        assertEquals(AppResult.Err(AppError.ImageTooLarge(index = 2, bytes = fiveMb.toLong())), preparePost(index = 2))
        assertEquals(listOf("release(t2:512x384)", "release(t1:1000x750)"), codec.calls.takeLast(2))
        assertEquals(emptySet(), codec.live)
    }

    @Test
    fun `本体もサムネイルも5MBに1バイト足りなければ成功する`() {
        codec.jpegBytesQueue += listOf(ByteArray(fiveMb - 1), ByteArray(fiveMb - 1))

        val image = ok(preparePost())

        assertEquals(fiveMb - 1, image.body.size)
        assertEquals(fiveMb - 1, image.thumbnail.size)
    }

    // ── 読めない写真：ImageUnreadable（何枚目かを載せる）。どの段で失敗しても、作った画像は全て解放する ──

    @Test
    fun `大きさを読めなければ、復号せずにImageUnreadableにする`() {
        codec.size = null

        assertEquals(AppResult.Err(AppError.ImageUnreadable(index = 5)), preparePost(index = 5))
        assertEquals(listOf("readSize($uri)"), codec.calls)
    }

    @Test
    fun `復号できなければImageUnreadableにし、描画にも解放にも進まない`() {
        codec.decodeReturnsNull = true

        assertEquals(AppResult.Err(AppError.ImageUnreadable(index = 0)), preparePost())
        assertEquals(listOf("readSize($uri)", "readExifOrientation($uri)", "decode($uri, 1)"), codec.calls)
    }

    @Test
    fun `どの段で失敗しても、ImageUnreadableにして、それまでに作った画像を全て解放する`() {
        val failures = listOf(
            "本体の描画" to { c: FakeImageCodec -> c.transformFailure = 1 to IllegalStateException("描けない") },
            "本体の圧縮" to { c: FakeImageCodec -> c.encodeFailure = 1 to IOException("圧縮に失敗") },
            "サムネイルの描画" to { c: FakeImageCodec -> c.transformFailure = 2 to IllegalStateException("描けない") },
            "サムネイルの圧縮" to { c: FakeImageCodec -> c.encodeFailure = 2 to IOException("圧縮に失敗") },
        )
        for ((stage, fail) in failures) {
            val codec = FakeImageCodec().also(fail)

            val result = runBlocking { DefaultImagePipeline(codec).preparePost(PickedPhoto(uri, 1), PhotoEdit(filter = FilterId.SOFT)) }

            assertEquals(AppResult.Err(AppError.ImageUnreadable(index = 1)), result, stage)
            assertEquals(emptySet(), codec.live, "$stage: ${codec.calls}")
        }
    }

    // ── 取り消し ──

    @Test
    fun `コルーチンの取り消しは失敗に写さず、そのまま伝える`() {
        codec.encodeFailure = 2 to CancellationException("取り消し")

        assertFailsWith<CancellationException> { preparePost() }
        // 取り消しでも、作った画像は手放している
        assertEquals(emptySet(), codec.live)
    }

    // ── 編集：回転・切り抜き・色（Kiro android-edit-tools タスク 12・A1・design.md:871-885・1134 の①〜⑥）──
    // 偽物の transform の記録の番号（t1・t2）は窓口ごとに数えるので、1 つのテストで何度も変換するときは、毎回新しい偽物を使う（[runPost]）

    /** 新しい偽物の窓口を [setUp] で整え、[edit] で投稿用に変換する。偽物と結果を返す。 */
    private fun runPost(
        edit: PhotoEdit,
        index: Int = 0,
        setUp: FakeImageCodec.() -> Unit = {},
    ): Pair<FakeImageCodec, AppResult<PreparedPostImage>> {
        val fake = FakeImageCodec().apply(setUp)
        val result = runBlocking { DefaultImagePipeline(fake).preparePost(PickedPhoto(uri, index), edit) }
        return fake to result
    }

    /** スライダーの値（百分の 1）を並べたツールの値。 */
    private fun tools(vararg values: Pair<EditTool, Int>): ToolValues =
        values.fold(ToolValues.NONE) { acc, (tool, value) -> acc.with(tool, value) }

    /** 偽物の transform の記録の、切り抜きが全体でないときの末尾（FakeImageCodec の説明のとおり）。 */
    private fun cropSuffix(crop: NormalizedRect): String = if (crop == NormalizedRect.FULL) "" else ", $crop"

    /** 偽物の transform が [n] 回目に返す画像の書き方（`t1:2048x1536` の形）。 */
    private fun t(n: Int, size: ImageSize): String = "t$n:${size.width}x${size.height}"

    private val legacySix = listOf(FilterId.CLEAR, FilterId.DRAMA, FilterId.SOFT, FilterId.MONOCHROME, FilterId.PASTEL, FilterId.VIVID)

    @Test
    fun `編集が無いときは、どの向きでも、transformに向きの直しだけ・全体・フィルターなしが渡り、applyColorを呼ばない`() {
        // ①（10.8）：EXIF の向きの直しのあとに足す利用者の回転は 0 回なので、操作は EXIF の直しそのもの。切り抜きは全体（記録の末尾に何も付かない）
        for (exif in 0..8) {
            val (fake, result) = runPost(PhotoEdit.NONE) {
                size = ImageSize(8000, 6000)
                orientation = exif
            }
            val fix = orientationFixOf(exif)
            val body = if (fix.swapsAxes) ImageSize(1536, 2048) else ImageSize(2048, 1536)
            val thumbnail = if (fix.swapsAxes) ImageSize(384, 512) else ImageSize(512, 384)

            val image = ok(result)

            assertEquals(
                listOf(
                    "readSize($uri)",
                    "readExifOrientation($uri)",
                    "decode($uri, 2)",
                    "transform(4000x3000, $fix, $body, null)",
                    "release(4000x3000)",
                    "encodeJpeg(${t(1, body)}, 90)",
                    "transform(${t(1, body)}, ${OrientationFix.NONE}, $thumbnail, null)",
                    "encodeJpeg(${t(2, thumbnail)}, 80)",
                    "release(${t(2, thumbnail)})",
                    "release(${t(1, body)})",
                ),
                fake.calls,
                "向き $exif",
            )
            assertEquals(emptyList(), fake.colorCalls, "向き $exif")
            assertEquals(body.width to body.height, image.bodyWidth to image.bodyHeight, "向き $exif")
        }
    }

    @Test
    fun `今の6種だけとナチュラルは、applyColorを呼ばず、6種は描画の中の行列に渡す（回転と切り抜きがあっても同じ）`() {
        // ②（2.2）：ツールが全部中立なら、今の 6 種は今と同じ描画（行列は描画の中）。ナチュラルは中立（何も掛けない）
        val crop = NormalizedRect(0.25, 0.5, 0.75, 1.0)
        val geometries = listOf(EditGeometry.NONE, EditGeometry(quarterTurns = 1, crop = crop))
        for (filter in legacySix + FilterId.NATURAL) {
            for (geometry in geometries) {
                val (fake, result) = runPost(PhotoEdit(filter = filter, geometry = geometry))
                ok(result)

                // 1000×750 を時計回りに 1 回回すと 750×1000。その (0.25, 0.5)〜(0.75, 1.0) は 375×500
                val fix = if (geometry.quarterTurns == 1) OrientationFix(90, mirror = false) else OrientationFix.NONE
                val size = if (geometry.quarterTurns == 1) ImageSize(375, 500) else ImageSize(1000, 750)
                val passed = filter.takeIf { it in legacySix }?.raw
                assertEquals(
                    "transform(1000x750, $fix, $size, $passed${cropSuffix(geometry.crop)})",
                    fake.calls.first { it.startsWith("transform(") },
                    "$filter・$geometry",
                )
                assertEquals(emptyList(), fake.colorCalls, "$filter・$geometry")
                assertTrue(fake.calls.none { it.startsWith("applyColor(") }, "$filter・$geometry: ${fake.calls}")
            }
        }
    }

    @Test
    fun `新しい3種かツールが付けば、描画では行列を掛けず、applyColorにColorRecipeのofと切り抜きの範囲と全体の縦横比が渡る`() {
        // ③（2.2・11.5）：描画の legacyFilter は null。色は描いた後の本体（t1）に 1 回だけ、レシピ全体（今の 6 種の行列を含む）で掛ける
        val crop = NormalizedRect(0.25, 0.5, 0.75, 1.0)
        data class Case(
            val name: String,
            val edit: PhotoEdit,
            val exif: Int,
            val fix: OrientationFix,
            val body: ImageSize,
            val fullAspect: Double,
        )
        val cases = listOf(
            // 8000×6000 は 1/2 で 4000×3000。回さなければ全体の縦横比は 4000÷3000
            Case("ドラマに露出", PhotoEdit(filter = FilterId.DRAMA, tools = tools(EditTool.EXPOSURE to 50)), 1, OrientationFix.NONE, ImageSize(2048, 1536), 4000.0 / 3000),
            Case("フィルターなしでコントラスト", PhotoEdit(tools = tools(EditTool.CONTRAST to -30)), 1, OrientationFix.NONE, ImageSize(2048, 1536), 4000.0 / 3000),
            Case("ウォームだけ", PhotoEdit(filter = FilterId.WARM), 1, OrientationFix.NONE, ImageSize(2048, 1536), 4000.0 / 3000),
            Case("クールだけ", PhotoEdit(filter = FilterId.COOL), 1, OrientationFix.NONE, ImageSize(2048, 1536), 4000.0 / 3000),
            // EXIF の向き 6 は時計回りに 90 度。回した後の全体は 3000×4000 で、縦横比は 0.75（幅と高さを入れ替え忘れると 1.333…）
            Case("ビンテージだけ・EXIFの向き6", PhotoEdit(filter = FilterId.VINTAGE), 6, OrientationFix(90, mirror = false), ImageSize(1536, 2048), 3000.0 / 4000),
            // 利用者の回転 1 回と切り抜き：回した後の 3000×4000 の (0.25, 0.5)〜(0.75, 1.0) は 1500×2000（2048 以下なのでそのまま）。
            // 範囲（frame）は切り抜きの範囲、縦横比は切り抜く前の全体（回した後）の 0.75
            Case(
                "ヴィヴィッドにフェード・回転と切り抜き",
                PhotoEdit(filter = FilterId.VIVID, tools = tools(EditTool.FADE to 40), geometry = EditGeometry(quarterTurns = 1, crop = crop)),
                1,
                OrientationFix(90, mirror = false),
                ImageSize(1500, 2000),
                3000.0 / 4000,
            ),
        )
        for (case in cases) {
            val (fake, result) = runPost(case.edit) {
                size = ImageSize(8000, 6000)
                orientation = case.exif
            }
            ok(result)

            val geometry = case.edit.geometry
            assertEquals(
                "transform(4000x3000, ${case.fix}, ${case.body}, null${cropSuffix(geometry.crop)})",
                fake.calls.first { it.startsWith("transform(") },
                case.name,
            )
            val call = fake.colorCalls.singleOrNull() ?: throw AssertionError("${case.name}: applyColor が 1 回だけ呼ばれていない: ${fake.calls}")
            assertEquals(t(1, case.body), call.image.toString(), "${case.name}：色を掛けるのは描いた本体")
            assertEquals(ColorRecipe.of(case.edit), call.recipe, case.name)
            assertEquals(case.edit.filter, call.recipe.filter, "${case.name}：フィルター（今の 6 種の行列を含む）もレシピに残る")
            assertEquals(geometry.crop, call.frame, case.name)
            assertEquals(case.fullAspect, call.fullAspect, 1e-12, case.name)
        }
    }

    @Test
    fun `利用者の回転はEXIFの向きの直しのあとに足して1つの操作にする（反転のある向きでは逆向きに足す）`() {
        // 手順 2（design.md:873）：向き 6（90 度）に 1 回足すと 180 度。向き 5（90 度してから反転）に 1 回足すと「0 度してから反転」。
        // 向き 8（270 度）に 1 回足すと 0 度。どれも回した後は 4000×3000 の横長
        val cases = listOf(
            6 to OrientationFix(180, mirror = false),
            5 to OrientationFix(0, mirror = true),
            8 to OrientationFix(0, mirror = false),
        )
        for ((exif, fix) in cases) {
            val (fake, result) = runPost(PhotoEdit(geometry = EditGeometry(quarterTurns = 1))) {
                size = ImageSize(8000, 6000)
                orientation = exif
            }
            val image = ok(result)

            assertEquals("transform(4000x3000, $fix, ${ImageSize(2048, 1536)}, null)", fake.calls[3], "向き $exif")
            assertEquals(2048 to 1536, image.bodyWidth to image.bodyHeight, "向き $exif")
            // 回転だけでは色を掛けない
            assertEquals(emptyList(), fake.colorCalls, "向き $exif")
        }
    }

    @Test
    fun `出力の寸法は切り抜いた範囲の画素の寸法を長辺2048以下にしたもので、拡大しない`() {
        // ④（10.2）：切り抜く前の寸法で決めると、どの例でも違う寸法になる（各例の注を参照）
        data class Case(
            val name: String,
            val stored: ImageSize,
            val geometry: EditGeometry,
            val decoded: String,
            val fix: OrientationFix,
            val body: ImageSize,
            val thumbnail: ImageSize,
        )
        val cases = listOf(
            // 4000×3000 の (0.25, 0.5)〜(0.75, 0.75) は 2000×750。2048 以下なので拡大しない（切り抜く前なら 2048×1536）
            Case("2048より小さい範囲はそのまま", ImageSize(8000, 6000), EditGeometry(crop = NormalizedRect(0.25, 0.5, 0.75, 0.75)),
                "4000x3000", OrientationFix.NONE, ImageSize(2000, 750), ImageSize(512, 192)),
            // 4000×3000 の上半分は 4000×1500。長辺を 2048 にすると 2048×768（切り抜く前なら 2048×1536）
            Case("縦横の比が変わる範囲は、その比のまま縮める", ImageSize(8000, 6000), EditGeometry(crop = NormalizedRect(0.0, 0.0, 1.0, 0.5)),
                "4000x3000", OrientationFix.NONE, ImageSize(2048, 768), ImageSize(512, 192)),
            // 回した後の 3000×4000 の左半分は 1500×4000。長辺を 2048 にすると 768×2048
            // （回す前の 4000×3000 で計算すると 2000×3000 から 1365×2048、切り抜く前なら 1536×2048）
            Case("回してから切り抜く", ImageSize(8000, 6000), EditGeometry(quarterTurns = 1, crop = NormalizedRect(0.0, 0.0, 0.5, 1.0)),
                "4000x3000", OrientationFix(90, mirror = false), ImageSize(768, 2048), ImageSize(192, 512)),
            // 1001 × 0.5 ＝ 500.5 は四捨五入で 501（切り抜く前なら 1001×750）
            Case("端数は四捨五入", ImageSize(1001, 750), EditGeometry(crop = NormalizedRect(0.0, 0.0, 0.5, 1.0)),
                "1001x750", OrientationFix.NONE, ImageSize(501, 750), ImageSize(342, 512)),
            // 400×300 の真ん中の 200×150。本体もサムネイルも拡大しない（切り抜く前なら 400×300）
            Case("小さい写真を小さく切り抜いても拡大しない", ImageSize(400, 300), EditGeometry(crop = NormalizedRect(0.25, 0.25, 0.75, 0.75)),
                "400x300", OrientationFix.NONE, ImageSize(200, 150), ImageSize(200, 150)),
        )
        for (case in cases) {
            val (fake, result) = runPost(PhotoEdit(geometry = case.geometry)) { size = case.stored }
            val image = ok(result)

            assertEquals(
                "transform(${case.decoded}, ${case.fix}, ${case.body}, null${cropSuffix(case.geometry.crop)})",
                fake.calls.first { it.startsWith("transform(") },
                case.name,
            )
            // 投稿の images[].width・height に書く寸法は、圧縮した本体の画素の寸法（9.5）
            assertEquals(case.body.width to case.body.height, image.bodyWidth to image.bodyHeight, case.name)
            // サムネイルは、切り抜いた本体から縮める（向きも切り抜きも、もう掛けない）
            assertEquals(
                "transform(${t(1, case.body)}, ${OrientationFix.NONE}, ${case.thumbnail}, null)",
                fake.calls.last { it.startsWith("transform(") },
                case.name,
            )
        }
    }

    @Test
    fun `サムネイルは色を掛けた後の本体と同じ画素から作り、色を重ねない`() {
        // ⑤（9.6）：色は本体の JPEG より前に本体の画像（t1）へ 1 回だけ掛け、サムネイルはその t1 から縮めるだけ
        val edit = PhotoEdit(filter = FilterId.VINTAGE, tools = tools(EditTool.EXPOSURE to 30))
        val (fake, result) = runPost(edit)

        ok(result)

        assertEquals(
            listOf(
                "readSize($uri)",
                "readExifOrientation($uri)",
                "decode($uri, 1)",
                "transform(1000x750, ${OrientationFix.NONE}, ${ImageSize(1000, 750)}, null)",
                "release(1000x750)",
                "applyColor(t1:1000x750, ${ColorRecipe.of(edit)}, ${NormalizedRect.FULL}, ${1000.0 / 750})",
                "encodeJpeg(t1:1000x750, 90)",
                "transform(t1:1000x750, ${OrientationFix.NONE}, ${ImageSize(512, 384)}, null)",
                "encodeJpeg(t2:512x384, 80)",
                "release(t2:512x384)",
                "release(t1:1000x750)",
            ),
            fake.calls,
        )
        assertEquals(1, fake.colorCalls.size)
        // 色を掛けている間も、同時に持つ画像は 2 枚まで。終わったら全て手放している
        assertEquals(2, fake.peakLive)
        assertEquals(emptySet(), fake.live)
    }

    @Test
    fun `applyColorに失敗したら、JPEGを作らずにImageUnreadableにし、作った画像を全て解放する`() {
        // ⑥（10.6）：失敗は窓口の例外として写す。何枚目かを載せる
        val (fake, result) = runPost(PhotoEdit(tools = tools(EditTool.BRIGHTNESS to 20)), index = 3) {
            applyColorFailure = 1 to IllegalStateException("色を掛けられない")
        }

        assertEquals(AppResult.Err(AppError.ImageUnreadable(index = 3)), result)
        assertEquals(1, fake.colorCalls.size)
        assertTrue(fake.calls.none { it.startsWith("encodeJpeg(") }, "${fake.calls}")
        assertEquals("release(t1:1000x750)", fake.calls.last())
        assertEquals(emptySet(), fake.live)
    }

    @Test
    fun `applyColorの途中の取り消しは失敗に写さず、そのまま伝え、作った画像は手放す`() {
        val fake = FakeImageCodec().apply { applyColorFailure = 1 to CancellationException("取り消し") }

        assertFailsWith<CancellationException> {
            runBlocking { DefaultImagePipeline(fake).preparePost(PickedPhoto(uri, 0), PhotoEdit(filter = FilterId.WARM)) }
        }
        assertEquals(emptySet(), fake.live)
    }
}
