// ⭐️ iOS のデザイントークンのソースを入れ子の型ごとに読む補助（SwiftTokenReader）の単体テスト（タスク 3.2・要件 4.3・5.9）
package com.yoshidometoru.soramoyou.ui

import androidx.compose.ui.graphics.Color
import com.yoshidometoru.soramoyou.ui.SwiftTokenReader.SwiftColor
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * iOS との突き合わせのテスト（IosDesignTokensTest など）が使う前に、読み方そのものが効いていることを確かめる
 * （設計書の「陽性対照の手順」の 3 の前半）。
 *
 * 断片の写しに書く値は、画面の値ではなく対照のための値である。本物の iOS のソースは、読めることだけを確かめる
 * （名前と値が Kotlin の写しと一致することは、タスク 4.1 のテストが確かめる）。
 */
class SwiftTokenReaderTest {

    /** 陽性対照のための Swift の断片の写しの置き場。テストごとに消す。 */
    private val fixtureRoot: File = createTempDirectory("swift-token-reader").toFile()

    @AfterTest
    fun deleteFixtures() {
        fixtureRoot.deleteRecursively()
    }

    /** [source] を一時的な置き場にファイルとして書き、その写しを読む。 */
    private fun readerOf(source: String, name: String = "Fragment.swift"): SwiftTokenReader =
        SwiftTokenReader.of(File(fixtureRoot, name).apply { writeText(source) })

    /**
     * 陽性対照の断片。`Spacing` と `Radius` を字下げした `}` で閉じ、同じ名前（`sm`・`md`）に違う値を入れる。
     * 行頭の `}` までを切る読み方だと `Spacing` の本体が `Radius` まで伸び、名前だけで読む読み方だと `md` が 1 つに潰れる。
     */
    private val fragment = """
        enum DesignTokens {
            enum Colors {
                static let daySkyGradient: [Color] = [
                    Color(red: 0.68, green: 0.85, blue: 0.90),  // 淡い空色
                    Color(red: 0.53, green: 0.81, blue: 0.98)   // 空色
                ]
                static let textDark = Color(red: 0.15, green: 0.15, blue: 0.20)
                static let textSecondary = Color.white.opacity(0.85)
            }

            enum Spacing {
                static let sm: CGFloat = 8
                static let md: CGFloat = 16
            }

            enum Radius {
                static let sm: CGFloat = 6
                static let md: CGFloat = 12
            }
        }
    """.trimIndent()

    @Test
    fun `字下げした閉じ括弧で閉じる余白と角丸を、同じ名前でも型ごとに読み分ける`() {
        // 断片が罠を持っていること（行頭の } までを切ると Radius まで入る）を先に見る。罠の無い断片では対照にならない
        val spacingAt = fragment.indexOf("enum Spacing")
        assertTrue("enum Radius" in fragment.substring(spacingAt, fragment.indexOf("\n}", spacingAt)), "断片に罠が無い")

        val reader = readerOf(fragment)
        val spacing = reader.enumBody("Spacing").numbers()
        val radius = reader.enumBody("Radius").numbers()
        println("断片の写し: Spacing=$spacing ／ Radius=$radius")

        assertEquals(mapOf("sm" to 8.0, "md" to 16.0), spacing, "余白の本体を読み違えた")
        assertEquals(mapOf("sm" to 6.0, "md" to 12.0), radius, "角丸の本体を読み違えた")
    }

    @Test
    fun `色・色の配列・白の不透明度を、後ろのコメントがあっても読む`() {
        val colors = readerOf(fragment).enumBody("Colors")

        assertEquals(
            listOf(SwiftColor(0.68, 0.85, 0.90), SwiftColor(0.53, 0.81, 0.98)),
            colors.colors("daySkyGradient"),
            "配列の色を読み違えた（型の [Color] の括弧から切ると中身が Color になる）",
        )
        assertEquals(SwiftColor(0.15, 0.15, 0.20), colors.color("textDark"))
        assertEquals(0.85, colors.whiteOpacity("textSecondary"))
    }

    @Test
    fun `本物のDesignTokensの余白・角丸・文字の大きさと色を読める`() {
        // タスク 4.1 の突き合わせの前提。値の一致はここでは見ず、本物の書き方で読めることだけを見る
        val reader = SwiftTokenReader.ios("Utils/DesignTokens.swift")
        val tokens = listOf("Spacing", "Radius", "Typography").associateWith { reader.enumBody(it).numbers() }
        println("本物の DesignTokens.swift: $tokens")

        tokens.forEach { (name, values) -> assertTrue(values.isNotEmpty(), "$name を 1 つも読めない") }
        // 余白と角丸は名前が重なる。型ごとに読めていれば、同じ md でも値が分かれる
        val spacingMd = assertNotNull(tokens.getValue("Spacing")["md"], "Spacing に md が無い")
        val radiusMd = assertNotNull(tokens.getValue("Radius")["md"], "Radius に md が無い")
        assertNotEquals(spacingMd, radiusMd, "Spacing.md と Radius.md が同じ値で読めた（本体を読み分けていない）")

        val colors = reader.enumBody("Colors")
        val day = colors.colors("daySkyGradient")
        val night = colors.colors("nightSkyGradient")
        println("空の色: 昼=$day ／ 夜=$night ／ textDark=${colors.color("textDark")} ／ softPink=${colors.color("softPink")}")
        assertEquals(3, day.size, "昼の空の色の数")
        assertEquals(3, night.size, "夜の空の色の数")
        assertNotEquals(day, night, "昼と夜の空の色が同じに読めた")
    }

    @Test
    fun `本物の空の背景から、雲の白の不透明度を並びの順に読める`() {
        // タスク 4.2 の突き合わせの前提。雲の濃さは enum でなく、計算型のプロパティ cloudsLayer の中にある
        val clouds = SwiftTokenReader.ios("Views/SkyBackgroundView.swift")
            .block(Regex("""\bvar\s+cloudsLayer\b"""), "var cloudsLayer")
            .whiteOpacities()
        println("雲の白の不透明度: $clouds")

        assertEquals(4, clouds.size, "雲の数")
    }

    @Test
    fun `iOSのソースが無いときは、探したパスを出して失敗する`() {
        val missing = "Utils/存在しないトークン.swift"

        val error = assertFailsWith<IllegalStateException> { SwiftTokenReader.ios(missing) }
        println("ソースが無いとき: ${error.message}")

        val searched = File(UiTextSources.iosSourceRoot, missing).canonicalPath
        assertTrue(searched in error.message.orEmpty(), "失敗の文言に探したパスが無い: ${error.message}")
    }

    @Test
    fun `型が無い・本体が空・書き方が変わって読めないときは、パスと名前を出して失敗する`() {
        val broken = readerOf(
            """
            enum Spacing {
            }
            enum Radius {
                static let sm: CGFloat = 8
                static let md = CGFloat(12)
            }
            enum Colors {
                static let textDark = Color.black
                static let textSecondary = Color.black.opacity(0.85)
                static let sky: [Color] = [
                    Color(red: 0.1, green: 0.2, blue: 0.3),
                    .white
                ]
            }
            var clouds: some View {
                Cloud().fill(.white.opacity(0.5))
                Cloud().fill(.blue.opacity(0.35))
            }
            var empty: some View {
                Cloud()
            }
            """.trimIndent(),
        )
        val unclosed = readerOf("enum Typography {\n    static let titleSize: CGFloat = 28\n", name = "Unclosed.swift")
        val twice = readerOf("enum Spacing {\n}\nenum Spacing {\n}\n", name = "Twice.swift")

        // 読んだ写し・失敗の文言に出るはずの名前・失敗するはずの読み方。いずれも、黙って空や一部だけを返すと 4.1 の突き合わせが空振りする
        val cases: List<Triple<SwiftTokenReader, String, () -> Any>> = listOf(
            Triple(broken, "enum Typography", { broken.enumBody("Typography") }),
            Triple(broken, "enum Spacing", { broken.enumBody("Spacing") }),
            Triple(broken, "md", { broken.enumBody("Radius").numbers() }),
            Triple(broken, "textDark", { broken.enumBody("Colors").color("textDark") }),
            Triple(broken, "textSecondary", { broken.enumBody("Colors").whiteOpacity("textSecondary") }),
            Triple(broken, "sky", { broken.enumBody("Colors").colors("sky") }),
            Triple(broken, "var clouds", { broken.block(Regex("""\bvar\s+clouds\b"""), "var clouds").whiteOpacities() }),
            Triple(broken, "var empty", { broken.block(Regex("""\bvar\s+empty\b"""), "var empty").whiteOpacities() }),
            Triple(unclosed, "enum Typography", { unclosed.enumBody("Typography") }),
            Triple(twice, "enum Spacing", { twice.enumBody("Spacing") }),
        )
        cases.forEach { (reader, name, read) ->
            val error = assertFailsWith<IllegalStateException>("$name を読むと失敗するはず") { read() }
            val message = error.message.orEmpty()
            println("失敗の文言（$name）: $message")
            assertTrue(reader.origin in message, "失敗の文言に読んだパスが無い: $message")
            assertTrue(name in message, "失敗の文言に名前 $name が無い: $message")
        }
    }

    @Test
    fun `iOSの色は、255倍した値との差が2分の1以下なら等しいとみなす`() {
        // ×255 で 173.4・216.75・229.5（設計書の「0.90×255＝229.5」の境目を含む）
        val sky = SwiftColor(0.68, 0.85, 0.90)

        assertTrue(sky.matches(Color(0xFFADD9E6)), "173・217・230 は等しい")
        assertTrue(sky.matches(Color(0xFFADD9E5)), "青 229 も 229.5 との差は 0.5 ちょうどで等しい")
        assertFalse(sky.matches(Color(0xFFAED9E6)), "赤 174 は 173.4 から 0.6 離れて等しくない")
        assertFalse(sky.matches(Color(0xFFADD9E4)), "青 228 は 229.5 から 1.5 離れて等しくない")
        // 不透明度を見ずに赤・緑・青だけで等しいと答えると、半透明の写し違いを見逃すので失敗させる
        assertFailsWith<IllegalArgumentException> { sky.matches(Color(0x80ADD9E6)) }
    }
}
