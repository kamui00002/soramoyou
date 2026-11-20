// ⭐️ 端末のダークの設定の読み取りと、MainActivity がシステムバーに透明の指定を渡していることの検査（android-ui-ios-parity タスク 6.2・要件 1.3・1.6・8.1・8.2）
package com.yoshidometoru.soramoyou

import android.content.res.Configuration
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * システムバー（ステータスバーとナビゲーションバー）を透明にし、アイコンの明暗を端末のダークの設定から選んでいることを確かめる。
 *
 * - [isNightMode] は純関数なので、`Configuration` の定数（コンパイル時に数へ置き換わる）を渡して直接確かめる。
 * - 選んだ指定の中身（`SystemBarStyle` の private や internal の欄）は、ここでは覗かない。:app の単体テストは
 *   `unitTests.isReturnDefaultValues` を付けていないので、Android の本体の呼び出しは「not mocked」で落ちうる。
 *   そこで、値の正しさは MainActivity.kt のソースの文字列で確かめる（[SystemBarsSourceCheck]）。
 *   実際にバーの後ろに帯が出ないことと、アイコンの明暗が切り替わることは、端末で確かめる（タスク 7.4）。
 * - ソースの検査は文字列を見るので、コメントの中の一致も数える。MainActivity.kt のコメントには、
 *   自動の指定を点でつないだ形や、検査する関数の丸括弧つきの呼び出しの形を書かない（BannerAdSlotPlacementTest と同じ注記）。
 * - 陽性対照（設計書「陽性対照の手順」の 4）は、違反を含む写しのファイルを一時的な置き場に作り、その違反だけが出ることを
 *   文言まで確かめる（FixedHeightInUiTest と同じ形の常設のテスト）。写しは本物に依らないので、本物を壊した回にも通る。
 *
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class SystemBarsSetupTest {

    private val mainActivitySource = File("src/main/kotlin/com/yoshidometoru/soramoyou/MainActivity.kt")

    /** 陽性対照のための一時的なソースの置き場。テストごとに消す。 */
    private val fixtureRoot: File = createTempDirectory("system-bars").toFile()

    @AfterTest
    fun deleteFixtures() {
        fixtureRoot.deleteRecursively()
    }

    /** 一時的な置き場に MainActivity.kt の写しを書き、そのファイルを返す。 */
    private fun fixture(source: String): File =
        File(fixtureRoot, "MainActivity.kt").apply { writeText(source) }

    /**
     * 陽性対照の写しの中身。既定の引数のままなら、本物の MainActivity.kt と同じ形のコード（コメントは除く）になる。
     * 1 か所だけ差し替えて、その違反だけが出ることを見る（差し替える値は 1 行で渡す。trimIndent の字下げの計算を崩さないため）。
     */
    private fun mainActivitySource(
        readDark: String = "val isDark = isNightMode(resources.configuration.uiMode)",
        edgeToEdge: String =
            "enableEdgeToEdge(statusBarStyle = systemBarStyleFor(isDark), navigationBarStyle = systemBarStyleFor(isDark))",
        styleFunction: String =
            "internal fun systemBarStyleFor(isDark: Boolean): SystemBarStyle { return if (isDark) { " +
                "SystemBarStyle.dark(Color.TRANSPARENT) } else { SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT) } }",
        extra: String = "",
    ): String = """
        package com.yoshidometoru.soramoyou

        import android.content.res.Configuration
        import android.graphics.Color
        import android.os.Bundle
        import androidx.activity.ComponentActivity
        import androidx.activity.SystemBarStyle
        import androidx.activity.compose.setContent
        import androidx.activity.enableEdgeToEdge

        class MainActivity : ComponentActivity() {
            override fun onCreate(savedInstanceState: Bundle?) {
                super.onCreate(savedInstanceState)
                $readDark
                $edgeToEdge
                val container = (application as SoramoyouApplication).container
                container.adsController.start(UmpConsentGateway(this))
                setContent {
                    SoramoyouTheme {
                        SoramoyouApp(container)
                    }
                }
            }
        }

        internal fun isNightMode(uiMode: Int): Boolean =
            (uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

        $styleFunction

        $extra
    """.trimIndent()

    // MARK: - 端末のダークの設定の読み取り（isNightMode）

    @Test
    fun `夜の印がYESならダークと読む`() {
        assertTrue(isNightMode(Configuration.UI_MODE_NIGHT_YES), "UI_MODE_NIGHT_YES をダークと読んでいない")
    }

    @Test
    fun `夜の印がNOと未定ならライトと読む`() {
        assertFalse(isNightMode(Configuration.UI_MODE_NIGHT_NO), "UI_MODE_NIGHT_NO をダークと読んだ")
        // 夜の印が未定（0）のときはライトとして扱う（Compose の isSystemInDarkTheme と同じ）
        assertFalse(isNightMode(Configuration.UI_MODE_NIGHT_UNDEFINED), "UI_MODE_NIGHT_UNDEFINED をダークと読んだ")
    }

    @Test
    fun `夜の印以外のビットが立っていても、夜の印だけで決まる`() {
        // 本物の uiMode は、端末の種類の印（下位 4 ビット）と夜の印（UI_MODE_NIGHT_MASK の 2 ビット）を 1 つの数に持つ。
        // 「uiMode が UI_MODE_NIGHT_YES と等しいか」のような書き方だと、ふつうの端末（UI_MODE_TYPE_NORMAL）で夜を見逃す。
        // 種類の印の全ての値と、夜の印のビット以外を全て立てた数で、夜の印だけで決まることを見る
        val others = listOf(
            Configuration.UI_MODE_TYPE_NORMAL,
            Configuration.UI_MODE_TYPE_DESK,
            Configuration.UI_MODE_TYPE_CAR,
            Configuration.UI_MODE_TYPE_TELEVISION,
            Configuration.UI_MODE_TYPE_APPLIANCE,
            Configuration.UI_MODE_TYPE_WATCH,
            Configuration.UI_MODE_TYPE_VR_HEADSET,
            Configuration.UI_MODE_TYPE_MASK,
            Configuration.UI_MODE_NIGHT_MASK.inv(),
        )
        others.forEach { bits ->
            val hex = "0x%08x".format(bits)
            assertTrue(isNightMode(bits or Configuration.UI_MODE_NIGHT_YES), "夜の印以外のビット $hex と YES をダークと読んでいない")
            assertFalse(isNightMode(bits or Configuration.UI_MODE_NIGHT_NO), "夜の印以外のビット $hex と NO をダークと読んだ")
            assertFalse(isNightMode(bits or Configuration.UI_MODE_NIGHT_UNDEFINED), "夜の印以外のビット $hex と未定をダークと読んだ")
        }
    }

    // MARK: - MainActivity.kt のソースの検査

    @Test
    fun `MainActivityは端末の明暗から選んだ透明の指定を両方のバーに渡し、自動の指定を使わない`() {
        assertTrue(mainActivitySource.isFile, "MainActivity.kt が見つからない: ${mainActivitySource.absolutePath}")

        assertEquals(emptyList(), SystemBarsSourceCheck.violations(mainActivitySource), "MainActivity.kt のシステムバーの指定が設計と違う")
    }

    // MARK: - 陽性対照（違反を含む写しを一時的な置き場に作り、その違反だけが出ることを見る）

    @Test
    fun `陽性対照の土台：正しい形の写しでは違反が出ない`() {
        // 下の陽性対照は、この土台から 1 か所だけ差し替えた写しで行う。土台そのものが違反を出さないことを先に見る
        assertEquals(emptyList(), SystemBarsSourceCheck.violations(fixture(mainActivitySource())))
    }

    @Test
    fun `正しい形の書き方の違いでは違反を出さない`() {
        // 名前を付けない引数・末尾のカンマ・明暗の読み取りを引数の中に直接書く形は、どれも設計どおりの呼び出しである
        listOf(
            mainActivitySource(edgeToEdge = "enableEdgeToEdge(systemBarStyleFor(isDark), systemBarStyleFor(isDark))"),
            mainActivitySource(edgeToEdge = "enableEdgeToEdge(systemBarStyleFor(isDark), systemBarStyleFor(isDark),)"),
            mainActivitySource(
                readDark = "",
                edgeToEdge = "enableEdgeToEdge(systemBarStyleFor(isNightMode(resources.configuration.uiMode)), " +
                    "systemBarStyleFor(isNightMode(resources.configuration.uiMode)))",
            ),
        ).forEach { source ->
            assertEquals(emptyList(), SystemBarsSourceCheck.violations(fixture(source)), "正しい形で違反が出た:\n$source")
        }
    }

    @Test
    fun `陽性対照①：引数なしのenableEdgeToEdgeを検出する`() {
        // 引数なしだと、両方のバーが自動の指定になる（API 29 以上の 3 ボタンの端末でナビゲーションバーの膜が強制される）
        val source = mainActivitySource(edgeToEdge = "enableEdgeToEdge()")

        assertEquals(
            listOf("MainActivity.kt: enableEdgeToEdge の引数が 2 つ（ステータスバーとナビゲーションバー）でない（0 個）: enableEdgeToEdge()"),
            SystemBarsSourceCheck.violations(fixture(source)),
        )
    }

    @Test
    fun `陽性対照②：SystemBarStyleのautoを使う形を検出する`() {
        val source = mainActivitySource(
            edgeToEdge = "enableEdgeToEdge(statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT), " +
                "navigationBarStyle = systemBarStyleFor(isDark))",
        )

        assertEquals(
            listOf(
                "MainActivity.kt: enableEdgeToEdge の 1 つ目（ステータスバー）の引数が systemBarStyleFor の結果でない: " +
                    "statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT)",
                "MainActivity.kt: 自動の指定（SystemBarStyle.auto）を 1 か所で使っている",
            ),
            SystemBarsSourceCheck.violations(fixture(source)),
        )
    }

    @Test
    fun `陽性対照③：ステータスバーだけに渡す1引数の呼び出しを検出する`() {
        // 1 引数だと、ナビゲーションバーは既定の自動の指定に戻る
        val source = mainActivitySource(edgeToEdge = "enableEdgeToEdge(systemBarStyleFor(isDark))")

        assertEquals(
            listOf(
                "MainActivity.kt: enableEdgeToEdge の引数が 2 つ（ステータスバーとナビゲーションバー）でない（1 個）: " +
                    "enableEdgeToEdge(systemBarStyleFor(isDark))",
            ),
            SystemBarsSourceCheck.violations(fixture(source)),
        )
    }

    @Test
    fun `陽性対照④：isDarkのときにライト用を選ぶ向きの取り違えを検出する`() {
        // 取り違えると、ダークで暗いアイコンが暗い空に載り、ライトで明るいアイコンが明るい空に載る（要件 8.1・8.2）
        val source = mainActivitySource(
            styleFunction = "internal fun systemBarStyleFor(isDark: Boolean): SystemBarStyle { return if (isDark) { " +
                "SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT) } else { SystemBarStyle.dark(Color.TRANSPARENT) } }",
        )

        assertEquals(
            listOf(
                "MainActivity.kt: isDark のときの分かれ道で、ダーク用の指定（SystemBarStyle.dark）だけを選んでいない: " +
                    "{ SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT) }",
                "MainActivity.kt: isDark でないときの分かれ道で、ライト用の指定（SystemBarStyle.light）だけを選んでいない: " +
                    "{ SystemBarStyle.dark(Color.TRANSPARENT) }",
            ),
            SystemBarsSourceCheck.violations(fixture(source)),
        )
    }

    @Test
    fun `陽性対照⑤：端末の明暗でなく決め打ちの値を渡す形を検出する`() {
        // いつもライト用になり、ダークの設定でアイコンの明暗が切り替わらない
        val source = mainActivitySource(
            edgeToEdge = "enableEdgeToEdge(statusBarStyle = systemBarStyleFor(false), navigationBarStyle = systemBarStyleFor(false))",
        )

        assertEquals(
            listOf(
                "MainActivity.kt: enableEdgeToEdge の 1 つ目（ステータスバー）の引数の systemBarStyleFor に、" +
                    "端末の明暗（isNightMode の結果）を渡していない: statusBarStyle = systemBarStyleFor(false)",
                "MainActivity.kt: enableEdgeToEdge の 2 つ目（ナビゲーションバー）の引数の systemBarStyleFor に、" +
                    "端末の明暗（isNightMode の結果）を渡していない: navigationBarStyle = systemBarStyleFor(false)",
            ),
            SystemBarsSourceCheck.violations(fixture(source)),
        )
    }

    @Test
    fun `陽性対照⑥：isNightModeに端末の設定のuiModeを渡していない形を検出する`() {
        val source = mainActivitySource(readDark = "val isDark = isNightMode(0)")

        assertEquals(
            listOf("MainActivity.kt: onCreate で isNightMode に resources.configuration.uiMode を渡していない（端末のダークの設定を読んでいない）"),
            SystemBarsSourceCheck.violations(fixture(source)),
        )
    }

    @Test
    fun `陽性対照⑦：透明でない膜の色を検出する`() {
        val source = mainActivitySource(
            styleFunction = "internal fun systemBarStyleFor(isDark: Boolean): SystemBarStyle { return if (isDark) { " +
                "SystemBarStyle.dark(Color.BLACK) } else { SystemBarStyle.light(Color.TRANSPARENT, Color.WHITE) } }",
        )

        assertEquals(
            listOf(
                "MainActivity.kt: 膜の色に透明（Color.TRANSPARENT）だけを渡していない: SystemBarStyle.dark(Color.BLACK)",
                "MainActivity.kt: 膜の色に透明（Color.TRANSPARENT）だけを渡していない: SystemBarStyle.light(Color.TRANSPARENT, Color.WHITE)",
            ),
            SystemBarsSourceCheck.violations(fixture(source)),
        )
    }

    @Test
    fun `陽性対照⑧：明暗で分けずにいつも同じ指定を返す形を検出する`() {
        val source = mainActivitySource(
            styleFunction = "internal fun systemBarStyleFor(isDark: Boolean): SystemBarStyle { return SystemBarStyle.dark(Color.TRANSPARENT) }",
        )

        assertEquals(
            listOf(
                "MainActivity.kt: systemBarStyleFor の本体に、ライト用の指定（SystemBarStyle.light）が無い",
                "MainActivity.kt: systemBarStyleFor の本体に、isDark で分ける if（if (isDark)）が無い",
            ),
            SystemBarsSourceCheck.violations(fixture(source)),
        )
    }

    @Test
    fun `陽性対照⑨：enableEdgeToEdgeの呼び出しが2つある形と、onCreateの外にある形を検出する`() {
        val twice = mainActivitySource(edgeToEdge = "enableEdgeToEdge(systemBarStyleFor(isDark), systemBarStyleFor(isDark)); enableEdgeToEdge()")
        val outside = mainActivitySource(
            edgeToEdge = "",
            extra = "fun ComponentActivity.setUpBars(isDark: Boolean) { enableEdgeToEdge(systemBarStyleFor(isDark), systemBarStyleFor(isDark)) }",
        )

        assertEquals(
            listOf("MainActivity.kt: enableEdgeToEdge の呼び出しが 1 つでない（2 個）"),
            SystemBarsSourceCheck.violations(fixture(twice)),
        )
        assertEquals(
            listOf("MainActivity.kt: enableEdgeToEdge の呼び出しが onCreate の中に無い"),
            SystemBarsSourceCheck.violations(fixture(outside)),
        )
    }

    @Test
    fun `陽性対照⑩：systemBarStyleForを式本体で書いた形は、向きを確かめられないので違反にする`() {
        // 式本体だと、本体を波括弧の対応で切り出せない。空の結果で黙って通さず、違反として出す
        val source = mainActivitySource(
            styleFunction = "internal fun systemBarStyleFor(isDark: Boolean): SystemBarStyle = " +
                "if (isDark) SystemBarStyle.dark(Color.TRANSPARENT) else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)",
        )

        assertEquals(
            listOf("MainActivity.kt: systemBarStyleFor の本体が波括弧で書かれていない（式本体では、明暗の向きを確かめられない）"),
            SystemBarsSourceCheck.violations(fixture(source)),
        )
    }

    @Test
    fun `陽性対照⑪：ファイルが無いときは空の結果で通さず違反にする`() {
        val missing = File(fixtureRoot, "MainActivity.kt")

        assertEquals(listOf("MainActivity.kt: ファイルが見つからない（${missing.path}）"), SystemBarsSourceCheck.violations(missing))
    }
}

/**
 * MainActivity.kt のソースを読み、システムバーの指定の書き方の違反を、人が読める文言の一覧で返す（違反が無ければ空）。
 *
 * 確かめること（設計書「MainActivity とウィンドウのテーマ（変更）」の事後条件）：
 * 1. onCreate の中で、isNightMode に `resources.configuration.uiMode` を渡して、端末のダークの設定を読んでいる
 * 2. enableEdgeToEdge の呼び出しがファイルにちょうど 1 つあり、onCreate の中にある。括弧の対応で切り出した引数を、
 *    最上位のカンマで分けて 2 つ（ステータスバーとナビゲーションバー）あり、どちらも「1 で読んだ明暗を渡した systemBarStyleFor」である
 * 3. ファイルのどこにも、自動の指定（SystemBarStyle の auto）が無い（コメントの中も数える）
 * 4. systemBarStyleFor の本体に、ダーク用とライト用の指定があり、渡す色が全て `Color.TRANSPARENT` で、
 *    `if (isDark)` の側でダーク用を、`else` の側でライト用を選んでいる
 *
 * 見つからないもの（ファイル・onCreate・関数の定義・if の分かれ道）は、空の結果で黙って通さず、違反の文言として返す。
 * 文字列と正規表現で読むので、文字列の値の中の括弧は考えない（MainActivity.kt の該当の箇所に文字列の値は無い）。
 */
private object SystemBarsSourceCheck {

    private val ON_CREATE = Regex("""\bfun\s+onCreate\s*\(""")
    private val ENABLE_CALL = Regex("""\benableEdgeToEdge\s*\(""")
    private val NIGHT_CALL = Regex("""\bisNightMode\s*\(""")
    private val NIGHT_VALUE = Regex("""\bval\s+(\w+)\s*=\s*isNightMode\s*\(""")
    private val STYLE_FUN = Regex("""\bfun\s+systemBarStyleFor\s*\(""")
    private val STYLE_CALL = Regex("""^systemBarStyleFor\((.*)\)$""")
    private val AUTO_STYLE = Regex("""SystemBarStyle\s*\.\s*auto\b""")
    private val DARK_CALL = Regex("""SystemBarStyle\s*\.\s*dark\s*\(""")
    private val LIGHT_CALL = Regex("""SystemBarStyle\s*\.\s*light\s*\(""")
    private val IF_DARK = Regex("""\bif\s*\(\s*isDark\s*\)""")
    private val ELSE = Regex("""\belse\b""")

    /** 引数の頭の「名前 =」（名前付きの引数）。`==` は名前付きの引数でないので外さない。 */
    private val NAMED_ARG = Regex("""^\w+\s*=(?!=)\s*""")

    private val WHITESPACE = Regex("""\s+""")

    /** enableEdgeToEdge の引数の順の名前（javap で見た enable(ComponentActivity, statusBarStyle, navigationBarStyle) の順）。 */
    private val BAR_LABELS = listOf("1 つ目（ステータスバー）", "2 つ目（ナビゲーションバー）")

    private const val UI_MODE = "resources.configuration.uiMode"
    private const val TRANSPARENT = "Color.TRANSPARENT"

    fun violations(file: File): List<String> {
        val name = file.name
        if (!file.isFile) return listOf("$name: ファイルが見つからない（${file.path}）")
        val source = file.readText()
        return onCreateViolations(name, source) + autoViolations(name, source) + styleFunctionViolations(name, source)
    }

    /** 1 と 2：onCreate で明暗を読み、選んだ指定を両方のバーに渡しているか。 */
    private fun onCreateViolations(name: String, source: String): List<String> {
        val onCreate = ON_CREATE.find(source)?.let { braceBlock(source, source.indexOf('{', it.range.last)) }
            ?: return listOf("$name: onCreate の本体が見つからない")
        val violations = mutableListOf<String>()

        val readsUiMode = NIGHT_CALL.findAll(onCreate).any { call ->
            callArguments(onCreate, call.range.last)?.map { normalized(it) } == listOf(UI_MODE)
        }
        if (!readsUiMode) violations += "$name: onCreate で isNightMode に $UI_MODE を渡していない（端末のダークの設定を読んでいない）"

        val calls = ENABLE_CALL.findAll(source).count()
        if (calls != 1) return violations + "$name: enableEdgeToEdge の呼び出しが 1 つでない（$calls 個）"
        val call = ENABLE_CALL.find(onCreate) ?: return violations + "$name: enableEdgeToEdge の呼び出しが onCreate の中に無い"
        val args = callArguments(onCreate, call.range.last)
            ?: return violations + "$name: enableEdgeToEdge の呼び出しの括弧が閉じていない"
        if (args.size != 2) {
            val shown = "enableEdgeToEdge(${args.joinToString(", ") { oneLine(it) }})"
            return violations + "$name: enableEdgeToEdge の引数が 2 つ（ステータスバーとナビゲーションバー）でない（${args.size} 個）: $shown"
        }

        // systemBarStyleFor に渡してよいのは、onCreate で isNightMode から読んだ値か、isNightMode の呼び出しそのもの
        val darkValues = NIGHT_VALUE.findAll(onCreate).map { it.groupValues[1] }.toSet() + "isNightMode($UI_MODE)"
        args.forEachIndexed { index, arg ->
            val styleCall = STYLE_CALL.matchEntire(normalized(arg))
            if (styleCall == null) {
                violations += "$name: enableEdgeToEdge の ${BAR_LABELS[index]}の引数が systemBarStyleFor の結果でない: ${oneLine(arg)}"
            } else if (withoutName(styleCall.groupValues[1]) !in darkValues) {
                violations += "$name: enableEdgeToEdge の ${BAR_LABELS[index]}の引数の systemBarStyleFor に、" +
                    "端末の明暗（isNightMode の結果）を渡していない: ${oneLine(arg)}"
            }
        }
        return violations
    }

    /** 3：自動の指定を使っていないか（コメントの中の一致も数える）。 */
    private fun autoViolations(name: String, source: String): List<String> {
        val count = AUTO_STYLE.findAll(source).count()
        return if (count == 0) emptyList() else listOf("$name: 自動の指定（SystemBarStyle.auto）を $count か所で使っている")
    }

    /** 4：systemBarStyleFor の本体が、透明の色だけで、isDark のときにダーク用を選んでいるか。 */
    private fun styleFunctionViolations(name: String, source: String): List<String> {
        val declaration = STYLE_FUN.find(source) ?: return listOf("$name: systemBarStyleFor の定義が見つからない")
        val parameters = parenRange(source, declaration.range.last)
            ?: return listOf("$name: systemBarStyleFor の引数の括弧が閉じていない")
        // 引数の括弧の後で、波括弧より先に等号が来たら式本体（本体を波括弧の対応で切り出せない）
        val bodyStart = (parameters.last + 1 until source.length).firstOrNull { source[it] == '{' || source[it] == '=' }
        if (bodyStart == null || source[bodyStart] == '=') {
            return listOf("$name: systemBarStyleFor の本体が波括弧で書かれていない（式本体では、明暗の向きを確かめられない）")
        }
        val block = braceBlock(source, bodyStart) ?: return listOf("$name: systemBarStyleFor の本体の波括弧が閉じていない")
        // 外側の波括弧を除いた中身だけを見る（分かれ道の文言に、関数の閉じ括弧を混ぜないため）
        val body = block.substring(1, block.length - 1)
        val violations = mutableListOf<String>()

        val darkCalls = DARK_CALL.findAll(body).toList()
        val lightCalls = LIGHT_CALL.findAll(body).toList()
        if (darkCalls.isEmpty()) violations += "$name: systemBarStyleFor の本体に、ダーク用の指定（SystemBarStyle.dark）が無い"
        if (lightCalls.isEmpty()) violations += "$name: systemBarStyleFor の本体に、ライト用の指定（SystemBarStyle.light）が無い"

        // 色の数は javap で見た形（dark(int)・light(int, int)）。全ての色が透明であること
        (darkCalls.map { it to 1 } + lightCalls.map { it to 2 }).sortedBy { it.first.range.first }.forEach { (call, colorCount) ->
            val range = parenRange(body, call.range.last)
            val colors = callArguments(body, call.range.last)?.map { withoutName(normalized(it)) }
            if (range == null || colors == null) {
                violations += "$name: ${oneLine(call.value)} の括弧が閉じていない"
            } else if (colors.size != colorCount || colors.any { it != TRANSPARENT }) {
                violations += "$name: 膜の色に透明（${TRANSPARENT}）だけを渡していない: ${oneLine(body.substring(call.range.first, range.last + 1))}"
            }
        }

        val ifDark = IF_DARK.find(body)
            ?: return violations + "$name: systemBarStyleFor の本体に、isDark で分ける if（if (isDark)）が無い"
        val afterIf = body.substring(ifDark.range.last + 1)
        val elseAt = ELSE.find(afterIf) ?: return violations + "$name: systemBarStyleFor の if (isDark) に else が無い"
        val whenDark = afterIf.substring(0, elseAt.range.first)
        val whenLight = afterIf.substring(elseAt.range.last + 1)
        if (!DARK_CALL.containsMatchIn(whenDark) || LIGHT_CALL.containsMatchIn(whenDark)) {
            violations += "$name: isDark のときの分かれ道で、ダーク用の指定（SystemBarStyle.dark）だけを選んでいない: ${oneLine(whenDark)}"
        }
        if (!LIGHT_CALL.containsMatchIn(whenLight) || DARK_CALL.containsMatchIn(whenLight)) {
            violations += "$name: isDark でないときの分かれ道で、ライト用の指定（SystemBarStyle.light）だけを選んでいない: ${oneLine(whenLight)}"
        }
        return violations
    }

    /** [text] の [openAt]（`(` の位置）から対応する `)` までの位置の範囲。対応が無ければ null。 */
    private fun parenRange(text: String, openAt: Int): IntRange? {
        if (openAt !in text.indices || text[openAt] != '(') return null
        var depth = 0
        for (i in openAt until text.length) {
            when (text[i]) {
                '(' -> depth++
                ')' -> if (--depth == 0) return openAt..i
            }
        }
        return null
    }

    /** [text] の [openAt]（`(` の位置）の呼び出しの引数を、最上位のカンマで分けた一覧（末尾のカンマの後の空は捨てる）。 */
    private fun callArguments(text: String, openAt: Int): List<String>? {
        val range = parenRange(text, openAt) ?: return null
        val inside = text.substring(range.first + 1, range.last)
        val arguments = mutableListOf<String>()
        val current = StringBuilder()
        var depth = 0
        for (c in inside) {
            when (c) {
                '(', '{', '[' -> depth++
                ')', '}', ']' -> depth--
            }
            if (c == ',' && depth == 0) {
                arguments += current.toString().trim()
                current.clear()
            } else {
                current.append(c)
            }
        }
        val last = current.toString().trim()
        if (last.isNotEmpty()) arguments += last
        return arguments
    }

    /** [text] の [openAt]（`{` の位置）から、対応する `}` までの塊（波括弧を含む）。対応が無ければ null。 */
    private fun braceBlock(text: String, openAt: Int): String? {
        if (openAt !in text.indices || text[openAt] != '{') return null
        var depth = 0
        for (i in openAt until text.length) {
            when (text[i]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return text.substring(openAt, i + 1)
            }
        }
        return null
    }

    /** 比べるための形：空白を全て除き、頭の「名前 =」を外す。 */
    private fun normalized(argument: String): String = withoutName(argument.replace(WHITESPACE, ""))

    private fun withoutName(argument: String): String = argument.replaceFirst(NAMED_ARG, "")

    /** 文言に載せるための形：空白の並びを 1 つにまとめ、前後を除く。 */
    private fun oneLine(text: String): String = text.replace(WHITESPACE, " ").trim()
}
