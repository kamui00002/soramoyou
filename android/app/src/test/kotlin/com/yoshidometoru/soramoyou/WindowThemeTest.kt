// ⭐️ ウィンドウのテーマ（アクションバーの無い親・空のいちばん上の色の窓の背景）と、アプリへの付け方の検査（android-ui-ios-parity タスク 6.1・要件 1.1・1.2・1.6・1.8・9.1）
package com.yoshidometoru.soramoyou

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.yoshidometoru.soramoyou.ui.theme.skyPaletteOf
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import org.w3c.dom.Element
import org.xml.sax.SAXException

/**
 * アプリのウィンドウのテーマを確かめる（設計書「MainActivity とウィンドウのテーマ」と、Testing Strategy の WindowThemeTest の行）。
 *
 * - `res/values/themes.xml` と `res/values-night/themes.xml` の `Theme.Soramoyou` の親が、アクションバーの無いプラットフォームのテーマ
 *   （ライトは `android:Theme.Material.Light.NoActionBar`、夜は `android:Theme.Material.NoActionBar`）であること。
 *   帯が残ると、窓全体に敷く空の背景の上に不透明な帯が 1 本出る（要件 1.6・設計書の D8 と P12）
 * - 両方の窓の背景（`android:windowBackground`）が `@color/window_sky` で、`res/values` と `res/values-night` の `colors.xml` の
 *   `window_sky` が、[skyPaletteOf] の空のいちばん上の色と等しいこと。期待値は 16 進を直書きせず `toArgb()` から出す
 *   （DesignTokens の float から 8 ビットへの丸めを、こちらで計算し直して食い違えないようにするため）
 * - `src/main/AndroidManifest.xml` の `application` に `android:theme="@style/Theme.Soramoyou"` があり、`activity` に別のテーマが付いていないこと
 *   （activity にテーマを付けると、その画面だけアプリのテーマが上書きされ、帯か窓の色が戻ってしまう）
 *
 * 見ないもの：テーマの名前と親の名前が実際に使えること（aapt2 が親を見つけて組み立てられること）は、JVM の単体テストでは確かめられない。
 * :app の組み立てが通ることで確かめる。端末での見え方（帯が無いこと・起動画面の色）は端末で確かめる（タスク 7.4）。
 *
 * 検査は res の根とマニフェストを引数で受け取る関数（[windowThemeViolations]）にし、本物と、一時的な置き場に作った写しの両方に当てる
 * （設計書「陽性対照の手順」の 4。FixedHeightInUiTest と同じ形）。写しは本物をコピーせず文字列の雛形から作る。
 * そうすると、本物が無い・壊れているときも、陽性対照は本物と独立に「検査が違反を見つけられること」を示せる。
 * 違反は「どのファイルの何が違うか」を人が読める文言の一覧で返す。ファイルや要素が無いときも、空の結果で黙って通らず違反として出す。
 * XML は MainActivityManifestTest と同じく、名前空間を解かない DocumentBuilder で読み、属性は `android:theme` のように接頭辞つきの名前で引く。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main` の下を相対のパスで読む。
 */
class WindowThemeTest {

    private val resRoot = File("src/main/res")
    private val manifest = File("src/main/AndroidManifest.xml")

    /** 昼の空のいちばん上の色（ライトの窓の背景）。画面と同じ [skyPaletteOf] から読む。 */
    private val dayTop: Color = skyPaletteOf(darkTheme = false).skyGradient.first()

    /** 昼の空のいちばん下の色。陽性対照で「違う色」として使う。 */
    private val dayBottom: Color = skyPaletteOf(darkTheme = false).skyGradient.last()

    /** 夜の空のいちばん上の色（ダークの窓の背景）。 */
    private val nightTop: Color = skyPaletteOf(darkTheme = true).skyGradient.first()

    /** 陽性対照のための一時的な res とマニフェストの置き場。テストごとに消す。 */
    private val fixtureRoot: File = createTempDirectory("window-theme").toFile()

    @AfterTest
    fun deleteFixtures() {
        fixtureRoot.deleteRecursively()
    }

    // ── 本物 ──

    @Test
    fun `本物のテーマと色とマニフェストに違反が無い`() {
        assertTrue(resRoot.isDirectory, "res が見つからない: ${resRoot.absolutePath}")

        assertEquals(emptyList(), windowThemeViolations(resRoot, manifest), "ウィンドウのテーマか、その付け方に違反がある")
    }

    // ── 陽性対照（設計書の手順 4：違反を含む写しを一時的な置き場に作り、検査が見つけることを確かめる） ──

    @Test
    fun `陽性対照：正しい写しでは違反を出さない（検査が何でも違反にするのでない）`() {
        // 雛形の既定の引数は、本物と同じ中身（親・窓の背景・色・アプリのテーマ）。下の各陽性対照は、ここから 1 か所だけを変える
        writeFixture()

        assertEquals(emptyList(), fixtureViolations())
    }

    @Test
    fun `陽性対照：昼のテーマの親がアクションバーのあるテーマなら検出する`() {
        writeFixture(dayParent = "android:Theme.Material.Light")

        assertEquals(
            listOf("values/themes.xml：Theme.Soramoyou の親が android:Theme.Material.Light で、アクションバーの無い android:Theme.Material.Light.NoActionBar でない"),
            fixtureViolations(),
        )
    }

    @Test
    fun `陽性対照：夜のテーマの親がアクションバーのあるテーマなら検出する`() {
        writeFixture(nightParent = "android:Theme.Material")

        assertEquals(
            listOf("values-night/themes.xml：Theme.Soramoyou の親が android:Theme.Material で、アクションバーの無い android:Theme.Material.NoActionBar でない"),
            fixtureViolations(),
        )
    }

    @Test
    fun `陽性対照：窓の背景がwindow_skyでなければ検出する`() {
        writeFixture(dayWindowBackground = "@android:color/white")

        assertEquals(
            listOf("values/themes.xml：Theme.Soramoyou の android:windowBackground が @android:color/white で、@color/window_sky でない"),
            fixtureViolations(),
        )
    }

    @Test
    fun `陽性対照：window_skyが空のいちばん上の色でなければ検出する`() {
        // 昼は空のいちばん下の色を、夜は昼の空の上の色（ライトの色の置き忘れ）を置く。2 つが違う色であることを先に確かめる（空振りの防止）
        assertNotEquals(dayTop.toArgb(), dayBottom.toArgb(), "昼の空の上と下が同じ色で、違う色の写しにならない")
        assertNotEquals(dayTop.toArgb(), nightTop.toArgb(), "昼の空と夜の空の上が同じ色で、違う色の写しにならない")
        writeFixture(dayWindowSky = hex(dayBottom.toArgb()), nightWindowSky = hex(dayTop.toArgb()))

        assertEquals(
            listOf(
                "values/colors.xml：window_sky が ${hex(dayBottom.toArgb())} で、昼の空のいちばん上の色 ${hex(dayTop.toArgb())} でない",
                "values-night/colors.xml：window_sky が ${hex(dayTop.toArgb())} で、夜の空のいちばん上の色 ${hex(nightTop.toArgb())} でない",
            ),
            fixtureViolations(),
        )
    }

    @Test
    fun `陽性対照：アプリにテーマが無ければ検出する`() {
        writeFixture(applicationTheme = null)

        assertEquals(
            listOf("AndroidManifest.xml：application に android:theme が無い（@style/Theme.Soramoyou を付ける）"),
            fixtureViolations(),
        )
    }

    @Test
    fun `陽性対照：画面に別のテーマが付いていれば検出する`() {
        // アプリのテーマは正しく付いていても、activity の側のテーマがそれを上書きする
        writeFixture(activityTheme = "@android:style/Theme.Material.Light")

        assertEquals(
            listOf("AndroidManifest.xml：activity .MainActivity に別の android:theme（@android:style/Theme.Material.Light）が付いていて、アプリのテーマを上書きする"),
            fixtureViolations(),
        )
    }

    @Test
    fun `陽性対照：テーマか色かマニフェストのファイルが無ければ検出する`() {
        writeFixture()
        listOf("res/values/colors.xml", "res/values-night/themes.xml", "AndroidManifest.xml").forEach { relativePath ->
            assertTrue(File(fixtureRoot, relativePath).delete(), "写しの $relativePath を消せない")
        }

        assertEquals(
            listOf("values/colors.xml が無い", "values-night/themes.xml が無い", "AndroidManifest.xml が無い"),
            fixtureViolations(),
        )
    }

    @Test
    fun `陽性対照：テーマや色の名前が違えば、無いものとして検出する`() {
        // ファイルはあっても、探す名前の要素が無ければ黙って通さない（名前の打ち間違い・古い名前の残り）
        writeFixture()
        fixtureFile(
            "res/values/themes.xml",
            """
            <?xml version="1.0" encoding="utf-8"?>
            <resources>
                <style name="AppTheme" parent="android:Theme.Material.Light.NoActionBar">
                    <item name="android:windowBackground">@color/window_sky</item>
                </style>
            </resources>
            """.trimIndent(),
        )
        fixtureFile(
            "res/values-night/colors.xml",
            """
            <?xml version="1.0" encoding="utf-8"?>
            <resources>
                <color name="window_night">${hex(nightTop.toArgb())}</color>
            </resources>
            """.trimIndent(),
        )

        assertEquals(
            listOf("values/themes.xml：style Theme.Soramoyou が無い", "values-night/colors.xml：color window_sky が無い"),
            fixtureViolations(),
        )
    }

    @Test
    fun `色は6桁でも8桁でも読み、色として読めない値は違反にする`() {
        // 本物のテストが頼る色の読み取りの確かめ。8 桁（#AARRGGBB）は上の陽性対照の既定の写しで読めている。
        // 昼は不透明を略した 6 桁（#RRGGBB）で正しい色を書く（読めて、等しいので違反にならない）。
        // 夜は色でなく別の色への参照を書く。窓の背景の色は空の色と比べられる値で持つ決まりなので、比べられない書き方は違反にする
        writeFixture(dayWindowSky = "#%06X".format(dayTop.toArgb() and 0xFFFFFF), nightWindowSky = "@color/night_sky")

        assertEquals(
            listOf("values-night/colors.xml：window_sky の値 @color/night_sky を色として読めない（#RRGGBB か #AARRGGBB で書く）"),
            fixtureViolations(),
        )
    }

    // ── 検査 ──

    /** 昼と夜のテーマの置き場（res の下のディレクトリ）と、それぞれに求める親と窓の背景の色。 */
    private class Variant(val directory: String, val label: String, val parent: String, val skyTop: Color)

    /** 違反はこの順（昼 → 夜）に出す。 */
    private val variants = listOf(
        Variant(directory = "values", label = "昼", parent = "android:Theme.Material.Light.NoActionBar", skyTop = dayTop),
        Variant(directory = "values-night", label = "夜", parent = "android:Theme.Material.NoActionBar", skyTop = nightTop),
    )

    /**
     * [resRoot]（res の根）と [manifest] の、ウィンドウのテーマの違反を、人が読める文言の一覧で返す。違反が無ければ空。
     * 並びは「昼のテーマ → 昼の色 → 夜のテーマ → 夜の色 → マニフェスト」の順に固定する（陽性対照が一覧を丸ごと比べるため）。
     */
    private fun windowThemeViolations(resRoot: File, manifest: File): List<String> = buildList {
        variants.forEach { variant ->
            addAll(themeViolations(resRoot, variant))
            addAll(colorViolations(resRoot, variant))
        }
        addAll(manifestViolations(manifest))
    }

    /** `<variant>/themes.xml` の `Theme.Soramoyou` の親と窓の背景を確かめる。 */
    private fun themeViolations(resRoot: File, variant: Variant): List<String> {
        val path = "${variant.directory}/themes.xml"
        val violations = mutableListOf<String>()
        val root = readXml(File(resRoot, path), path, violations) ?: return violations
        val style = single(root.elements("style").filter { it.getAttribute("name") == THEME_NAME }, path, "style $THEME_NAME", violations)
            ?: return violations

        val parent = style.getAttribute("parent")
        if (parent != variant.parent) {
            violations += "${path}：$THEME_NAME の親が ${parent.ifEmpty { "（無し）" }} で、アクションバーの無い ${variant.parent} でない"
        }

        val background = single(
            style.elements("item").filter { it.getAttribute("name") == WINDOW_BACKGROUND },
            path,
            "$THEME_NAME の $WINDOW_BACKGROUND の item",
            violations,
        )
        if (background != null) {
            val value = background.textContent.trim()
            if (value != WINDOW_SKY_REFERENCE) {
                violations += "${path}：$THEME_NAME の $WINDOW_BACKGROUND が ${value.ifEmpty { "（空）" }} で、$WINDOW_SKY_REFERENCE でない"
            }
        }
        return violations
    }

    /** `<variant>/colors.xml` の `window_sky` が、その配色の空のいちばん上の色と等しいことを確かめる。 */
    private fun colorViolations(resRoot: File, variant: Variant): List<String> {
        val path = "${variant.directory}/colors.xml"
        val violations = mutableListOf<String>()
        val root = readXml(File(resRoot, path), path, violations) ?: return violations
        val color = single(root.elements("color").filter { it.getAttribute("name") == WINDOW_SKY }, path, "color $WINDOW_SKY", violations)
            ?: return violations

        val value = color.textContent.trim()
        val argb = argbOf(value)
        val expected = variant.skyTop.toArgb()
        when {
            argb == null ->
                violations += "${path}：$WINDOW_SKY の値 ${value.ifEmpty { "（空）" }} を色として読めない（#RRGGBB か #AARRGGBB で書く）"
            argb != expected ->
                violations += "${path}：$WINDOW_SKY が ${hex(argb)} で、${variant.label}の空のいちばん上の色 ${hex(expected)} でない"
        }
        return violations
    }

    /** マニフェストの `application` にアプリのテーマが付き、`activity` に別のテーマが付いていないことを確かめる。 */
    private fun manifestViolations(manifest: File): List<String> {
        val path = manifest.name
        val violations = mutableListOf<String>()
        val root = readXml(manifest, path, violations) ?: return violations

        val application = single(root.elements("application"), path, "application", violations)
        if (application != null) {
            val theme = application.getAttribute("android:theme")
            when {
                theme.isEmpty() -> violations += "${path}：application に android:theme が無い（$THEME_REFERENCE を付ける）"
                theme != THEME_REFERENCE -> violations += "${path}：application の android:theme が $theme で、$THEME_REFERENCE でない"
            }
        }

        // 同じテーマを重ねて書くのは害が無いので許し、違うテーマだけを違反にする
        root.elements("activity").forEach { activity ->
            val theme = activity.getAttribute("android:theme")
            if (theme.isNotEmpty() && theme != THEME_REFERENCE) {
                violations += "${path}：activity ${activity.getAttribute("android:name")} に別の android:theme（$theme）が付いていて、アプリのテーマを上書きする"
            }
        }
        return violations
    }

    /** [file] を XML として読む。無い・読めないときは [violations] に足して null を返す（空の結果で黙って通さない）。 */
    private fun readXml(file: File, path: String, violations: MutableList<String>): Element? {
        if (!file.isFile) {
            violations += "$path が無い"
            return null
        }
        return try {
            DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).documentElement
        } catch (e: SAXException) {
            violations += "$path を XML として読めない（${e.message}）"
            null
        }
    }

    /** [found] がちょうど 1 つならそれを返す。0 個・2 個以上なら [violations] に足して null を返す。 */
    private fun single(found: List<Element>, path: String, what: String, violations: MutableList<String>): Element? {
        when (found.size) {
            1 -> return found.single()
            0 -> violations += "${path}：$what が無い"
            else -> violations += "${path}：$what が ${found.size} 個ある（1 個であるべき）"
        }
        return null
    }

    /** [tag] の名前の子孫の要素を、文書の順に並べる。 */
    private fun Element.elements(tag: String): List<Element> {
        val nodes = getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
    }

    /**
     * `#RRGGBB`（不透明）か `#AARRGGBB` を ARGB の Int にする。ほかの書き方（`#RGB`・`#ARGB`・別の色への参照など）は読めないとして null を返す。
     * 窓の背景の色は、空の色とそのまま比べられる 6 桁か 8 桁で書く決まりにする。
     */
    private fun argbOf(value: String): Int? {
        val digits = Regex("#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})").matchEntire(value)?.groupValues?.get(1) ?: return null
        val bits = digits.toLong(16)
        return (if (digits.length == 6) bits or 0xFF000000L else bits).toInt()
    }

    /** ARGB の Int を `#AARRGGBB` の文言にする（ContrastMath と同じ書き方）。 */
    private fun hex(argb: Int): String = "#%08X".format(argb)

    // ── 写しの雛形（既定の引数は本物と同じ中身。名前と参照は検査の定数を使わず、本物と同じく文字で書く） ──

    private fun fixtureViolations(): List<String> = windowThemeViolations(File(fixtureRoot, "res"), File(fixtureRoot, "AndroidManifest.xml"))

    private fun fixtureFile(relativePath: String, text: String) {
        File(fixtureRoot, relativePath).apply {
            checkNotNull(parentFile).mkdirs()
            writeText(text)
        }
    }

    /** 一時的な置き場に、res の 4 つのファイルとマニフェストの写しを作る。違反を入れたい所だけ引数で変える。 */
    private fun writeFixture(
        dayParent: String = "android:Theme.Material.Light.NoActionBar",
        nightParent: String = "android:Theme.Material.NoActionBar",
        dayWindowBackground: String = "@color/window_sky",
        dayWindowSky: String = hex(dayTop.toArgb()),
        nightWindowSky: String = hex(nightTop.toArgb()),
        applicationTheme: String? = "@style/Theme.Soramoyou",
        activityTheme: String? = null,
    ) {
        fixtureFile("res/values/themes.xml", themesXml(dayParent, dayWindowBackground))
        fixtureFile("res/values-night/themes.xml", themesXml(nightParent, "@color/window_sky"))
        fixtureFile("res/values/colors.xml", colorsXml(dayWindowSky))
        fixtureFile("res/values-night/colors.xml", colorsXml(nightWindowSky))
        fixtureFile("AndroidManifest.xml", manifestXml(applicationTheme, activityTheme))
    }

    private fun themesXml(parent: String, windowBackground: String): String =
        """
        <?xml version="1.0" encoding="utf-8"?>
        <resources>
            <style name="Theme.Soramoyou" parent="$parent">
                <item name="android:windowBackground">$windowBackground</item>
            </style>
        </resources>
        """.trimIndent()

    private fun colorsXml(windowSky: String): String =
        """
        <?xml version="1.0" encoding="utf-8"?>
        <resources>
            <color name="window_sky">$windowSky</color>
        </resources>
        """.trimIndent()

    /** 本物と同じく、名前空間の宣言と、起動の入口の activity（MAIN と LAUNCHER）を持つマニフェスト。テーマの属性は null なら書かない。 */
    private fun manifestXml(applicationTheme: String?, activityTheme: String?): String {
        val applicationThemeAttribute = applicationTheme?.let { " android:theme=\"$it\"" }.orEmpty()
        val activityThemeAttribute = activityTheme?.let { " android:theme=\"$it\"" }.orEmpty()
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <manifest xmlns:android="http://schemas.android.com/apk/res/android">
                <application android:name=".SoramoyouApplication" android:label="@string/app_name"$applicationThemeAttribute>
                    <activity android:name=".MainActivity" android:exported="true"$activityThemeAttribute>
                        <intent-filter>
                            <action android:name="android.intent.action.MAIN" />
                            <category android:name="android.intent.category.LAUNCHER" />
                        </intent-filter>
                    </activity>
                </application>
            </manifest>
        """.trimIndent()
    }

    private companion object {
        const val THEME_NAME = "Theme.Soramoyou"
        const val THEME_REFERENCE = "@style/Theme.Soramoyou"
        const val WINDOW_BACKGROUND = "android:windowBackground"
        const val WINDOW_SKY = "window_sky"
        const val WINDOW_SKY_REFERENCE = "@color/window_sky"
    }
}
