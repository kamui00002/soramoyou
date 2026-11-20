// ⭐️ テーマと共通の UI 部品が高さと文言の行数を固定していないことの検査（タスク 5.2・要件 16.6）（android-ui-ios-parity タスク 10.4・要件 7.3・9.4）
package com.yoshidometoru.soramoyou.ui

import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 端末の文字サイズを大きくしても（例: 200%）、共通の部品の文言とボタンが切れずに伸びるよう、`ui/` の下では高さを固定しない。
 * 文言の行数も制限しない（行数の上限・1 行に限る書き方・折り返さない書き方・「…」での省略を使わない）。
 * 文言が画面より長くなったときは、部品の側で縦に送れる（スクロールできる）ようにしてある。
 *
 * 走査の範囲は `ui/`（テーマと共通の部品）だけ。各画面（feature/）は、アイコンや投稿者の写真のように
 * 大きさを決めてよいものを持つので対象にしない。実際に 200% で崩れないことは端末で確かめる（タスク 11.3）。
 *
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class FixedHeightInUiTest {

    private val uiRoot = File("src/main/kotlin/com/yoshidometoru/soramoyou/ui")

    /** 陽性対照のための一時的なソースの置き場。テストごとに消す。 */
    private val fixtureRoot: File = createTempDirectory("fixed-height").toFile()

    @AfterTest
    fun deleteFixtures() {
        fixtureRoot.deleteRecursively()
    }

    private fun fixture(relativePath: String, source: String) {
        File(fixtureRoot, relativePath).apply {
            checkNotNull(parentFile).mkdirs()
            writeText(source)
        }
    }

    @Test
    fun `テーマと共通の部品は高さも文言の行数も固定していない`() {
        assertTrue(uiRoot.isDirectory, "ui のソースが見つからない: ${uiRoot.absolutePath}")

        assertEquals(emptyList(), FixedHeightScanner.scan(uiRoot), "ui/ の下で高さか文言の行数を固定している")
    }

    @Test
    fun `走査の範囲にテーマと共通の部品のソースが入っている（上の検査が空振りしていない）`() {
        val files = uiRoot.walkTopDown().filter { it.isFile && it.extension == "kt" }
            .map { it.relativeTo(uiRoot).invariantSeparatorsPath }.toSet()

        listOf(
            "theme/SoramoyouTheme.kt",
            "component/IconOnlyButton.kt",
            "component/StateContents.kt",
            // android-ui-ios-parity で足したファイル（タスク 10.4）。トークンの写し・色の一式・背景・雲・ガラスの部品
            "theme/DesignTokens.kt",
            "theme/SkyPalette.kt",
            "component/SkyBackdrop.kt",
            "component/DecorativeClouds.kt",
            "component/Glass.kt",
        ).forEach {
            assertTrue(it in files, "走査の範囲に $it が無い: $files")
        }
    }

    @Test
    fun `陽性対照：高さと大きさの固定を検出する`() {
        fixture(
            "component/Bad.kt",
            """
            package com.example
            val a = Modifier.height(48.dp)
            val b = Modifier
                .requiredHeight(48.dp)
            val c = Modifier.size(24.dp)
            val d = Modifier.requiredSize(width = 10.dp, height = 10.dp)
            """.trimIndent(),
        )

        val hits = FixedHeightScanner.scan(fixtureRoot)

        assertEquals(listOf(2, 4, 5, 6), hits.map { it.line }, "検出した行: $hits")
        assertTrue(hits.all { it.path == "component/Bad.kt" })
    }

    @Test
    fun `陽性対照：高さの上限を検出する`() {
        fixture(
            "Limit.kt",
            """
            package com.example
            val a = Modifier.heightIn(min = 48.dp, max = 96.dp)
            val b = Modifier.requiredHeightIn(max = 96.dp)
            val c = Modifier.sizeIn(minWidth = 10.dp, maxHeight = 96.dp)
            val d = Modifier.requiredSizeIn(maxHeight = 96.dp)
            """.trimIndent(),
        )

        assertEquals(listOf(2, 3, 4, 5), FixedHeightScanner.scan(fixtureRoot).map { it.line })
    }

    @Test
    fun `陽性対照：文言の行数の上限と1行の制限と省略を検出する`() {
        // 文字を大きくすると、行数の上限や 1 行の制限で文言が「…」で切られる（共通の部品の文言は行数を制限しない）
        fixture(
            "component/Lines.kt",
            """
            package com.example
            val a = Text(text = t, maxLines = 2)
            val b = Text(
                text = t,
                maxLines
                    = 1,
            )
            val c = TextField(value = v, onValueChange = {}, singleLine = true)
            val d = Text(text = t, overflow = TextOverflow.Ellipsis)
            """.trimIndent(),
        )

        val hits = FixedHeightScanner.scan(fixtureRoot)

        assertEquals(listOf(2, 5, 8, 9), hits.map { it.line }, "検出した行: $hits")
    }

    @Test
    fun `陽性対照：名前を付けずに渡す上限と、折り返さない文言と、点の無い呼び出しを検出する`() {
        // heightIn は 2 つ目、sizeIn は 4 つ目が高さの上限。引数の中に関数の呼び出しがあっても、括弧の対応で引数を分ける
        fixture(
            "component/Positional.kt",
            """
            package com.example
            val a = Modifier.heightIn(48.dp, 96.dp)
            val b = Modifier.requiredHeightIn(
                48.dp,
                96.dp,
            )
            val c = Modifier.sizeIn(0.dp, 0.dp, 600.dp, 96.dp)
            val d = Modifier.heightIn(min = minimum(), max = 96.dp)
            val e = Text(text = t, softWrap = false)
            fun Modifier.f() = height(48.dp)
            fun Modifier.g() = heightIn(max = 96.dp)
            val h = Modifier.heightIn(min = 48.dp, 96.dp)
            """.trimIndent(),
        )

        val hits = FixedHeightScanner.scan(fixtureRoot)

        assertEquals(listOf(2, 3, 7, 8, 9, 10, 11, 12), hits.map { it.line }, "検出した行: $hits")
    }

    @Test
    fun `伸びられる書き方は検出しない`() {
        // 最小の高さだけ・幅の上限・親いっぱい・縦の送り・文字の大きさ・複数行を許す入力欄・省略しない文言・折り返す文言は、文字が増えても切れない
        // 最小の高さだけの形は、名前を付けずに 1 つ・最後のカンマの後ろにコメント・括弧の中のカンマ・sizeIn の 3 つ目まで、でも拾わない
        fixture(
            "Ok.kt",
            """
            package com.example
            val a = Modifier.heightIn(min = 48.dp)
            val b = Modifier.widthIn(max = 600.dp)
            val c = Modifier.sizeIn(minHeight = 48.dp, maxWidth = 600.dp)
            val d = Modifier.fillMaxSize().verticalScroll(state)
            val e = Modifier.fillMaxHeight().padding(16.dp)
            val f = items.size
            val g = MaterialTheme.typography.bodyLarge.fontSize
            val h = TextField(value = v, onValueChange = {}, singleLine = false)
            val i = Text(text = t, overflow = TextOverflow.Visible)
            val j = Modifier.heightIn(48.dp)
            val k = Modifier.heightIn(
                min = 48.dp, // 押せる大きさ, 最低
            )
            val l = Modifier.heightIn(min = maxOf(a, b))
            val m = Modifier.sizeIn(0.dp, 48.dp, 600.dp)
            val n = Text(text = t, softWrap = true)
            """.trimIndent(),
        )

        assertEquals(emptyList(), FixedHeightScanner.scan(fixtureRoot))
    }
}
