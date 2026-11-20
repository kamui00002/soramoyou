// ⭐️ 画面と共通の部品が色の値を作らないこと・ガラスの部品をガラスの5画面だけが使うことの検査（android-ui-ios-parity タスク 10.3・要件 2.1・2.2・3.7・4.4・8.4）
package com.yoshidometoru.soramoyou.ui

import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 色と不透明度の値は ui/theme（色の一式と Material 3 の配色）が持ち、画面（feature/）と共通の部品（ui/component/）では作らない。
 * 値を外で作ると、コントラスト比の表（SkyContrastTest）が確かめていない色が画面に出るためである（要件 4.4）。
 * また、ガラス風の部品はガラスの 5 画面だけで使い、背景だけの画面と無地の画面では使わない（要件 2.1・2.2）。
 *
 * 確かめること:
 * - feature/ と ui/component/ に、色の値の直書き（`Color` に数字を渡す形と、赤・緑・青などを名前で渡す形）と、
 *   不透明度を替えた写し（`copy` に `alpha` を名前で渡す形と、最初の引数に数字を渡す形）と、2 つの色の間の色（`lerp`）が無い。
 *   名前の付いた色（白・透明など）と、数字を変数で渡す形は数えない（設計書の決定）
 * - feature/ のうち、ガラスの部品（Glass.kt の部品と、色の一式のガラスの一式）を参照するファイルが、ガラスの 5 画面のファイルだけである
 *
 * 探すのは文字列なので、コメントの中の一致も数える（説明にも、上の書き方を丸括弧付きで書かない）。
 * 走査の仕方は FixedHeightInUiTest と同じで、陽性対照は、違反を含む写しのファイルを一時的な置き場に作って確かめる（設計書の手順 4）。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class ScreenStyleSourceTest {

    /** アプリの本体のソースの根。見つけた場所のパスは、ここからの相対パスで出す。 */
    private val mainRoot = File("src/main/kotlin/com/yoshidometoru/soramoyou")

    /** 陽性対照のための一時的なソースの置き場。テストごとに消す。 */
    private val fixtureRoot: File = createTempDirectory("screen-style").toFile()

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
    fun `画面と共通の部品は色の値を作らない`() {
        assertTrue(mainRoot.isDirectory, "本体のソースが見つからない: ${mainRoot.absolutePath}")

        assertEquals(
            emptyList(),
            ScreenStyleScanner.colorValues(mainRoot),
            "feature/ か ui/component/ で色の値を作っている（色と不透明度は ui/theme の色の一式から読む）",
        )
    }

    @Test
    fun `ガラスの部品を参照する画面のファイルは、ガラスの5画面のファイルだけ`() {
        assertEquals(
            emptySet(),
            ScreenStyleScanner.glassReferrers(mainRoot) - ScreenStyleScanner.GLASS_SCREEN_FILES,
            "ガラスの 5 画面の外のファイルが、ガラスの部品を参照している",
        )
    }

    @Test
    fun `走査の範囲に画面と共通の部品のソースが入っている（上の検査が空振りしていない）`() {
        val files = ScreenStyleScanner.scannedFiles(mainRoot).toSet()

        // 色の値の検査が読むべきファイル（画面と共通の部品の両方）
        listOf("feature/feed/FeedScreen.kt", "ui/component/Glass.kt", "ui/component/LikeButton.kt").forEach {
            assertTrue(it in files, "走査の範囲に $it が無い")
        }
        // ガラスの 5 画面のファイルの名簿が古くなっていない（名前を変えたら、名簿も一緒に直す）
        ScreenStyleScanner.GLASS_SCREEN_FILES.forEach {
            assertTrue(it in files, "ガラスの 5 画面のファイル $it が本体のソースに無い（名簿が古い）")
        }
    }

    @Test
    fun `陽性対照：色の値の直書きと半透明の写しを検出する`() {
        fixture(
            "feature/sample/Bad.kt",
            """
            package com.example
            val a = Color(0xFF262633)
            val b = Color (
                0x80FFFFFF)
            val c = MaterialTheme.colorScheme.surface.copy(alpha = 0.8f)
            val d = palette.text.copy(
                alpha = 0.5f,
            )
            // コメントの中の Color(0xFF000000) も数える
            """.trimIndent(),
        )
        fixture(
            "ui/component/AlsoBad.kt",
            """
            package com.example
            val e = Color.White.copy(alpha = 0.3f)
            """.trimIndent(),
        )

        val hits = ScreenStyleScanner.colorValues(fixtureRoot)

        assertEquals(
            listOf("feature/sample/Bad.kt" to 2, "feature/sample/Bad.kt" to 3, "feature/sample/Bad.kt" to 5, "feature/sample/Bad.kt" to 6) +
                listOf("feature/sample/Bad.kt" to 9, "ui/component/AlsoBad.kt" to 2),
            hits.map { it.path to it.line },
            "検出した場所: $hits",
        )
    }

    @Test
    fun `陽性対照：数字や名前付きの赤・緑・青で作る色と、位置で渡す不透明度と、2色の間の色を検出する`() {
        // Color.copy の最初の引数は不透明度。lerp は色でない値の間（長さなど）も文字では見分けられないので数える
        fixture(
            "feature/sample/Positional.kt",
            """
            package com.example
            val a = palette.text.copy(0.5f)
            val b = Color(red = 0.2f, green = 0.2f, blue = 0.25f)
            val c = Color(38, 38, 51)
            val d = Color(
                0.2f, 0.2f, 0.25f,
            )
            val e = lerp(palette.text, palette.accent, 0.5f)
            val f = Color.White.copy(.5f)
            """.trimIndent(),
        )
        fixture("ui/component/AlsoPositional.kt", "val g = Color(color = 0xFF262633)")

        val hits = ScreenStyleScanner.colorValues(fixtureRoot)

        assertEquals(
            listOf(2, 3, 4, 5, 8, 9).map { "feature/sample/Positional.kt" to it } + listOf("ui/component/AlsoPositional.kt" to 1),
            hits.map { it.path to it.line },
            "検出した場所: $hits",
        )
    }

    @Test
    fun `陽性対照：ガラスの5画面の外のファイルからのガラスの部品の参照を検出する`() {
        // ガラスの 5 画面のファイル（許される側）
        fixture("feature/feed/FeedScreen.kt", "val a = Modifier.glassSurface(LocalSkyPalette.current.glass.postCard)")
        fixture("feature/auth/LoginScreen.kt", "val b = AccentGradientButton(onClick = {}, enabled = true) {}")
        // 5 画面の外のファイル（検出される側）。部品の名前・見た目の種類・色の一式のガラスの一式のどれでも拾う
        fixture("feature/settings/SettingsScreen.kt", "val c = GlassButton(onClick = {}) {}")
        fixture("feature/profile/ProfileEditScreen.kt", "val d = GlassTextField(value = v, onValueChange = {}, label = {}, singleLine = false)")
        fixture("feature/settings/BlockListScreen.kt", "val e = ErrorContent(onRetry = {}, buttonLook = ButtonLook.GLASS)")
        fixture("feature/compose/PostComposerScreen.kt", "val f = Modifier.background(palette.glass.card.fill)")

        val outside = ScreenStyleScanner.glassReferrers(fixtureRoot) - ScreenStyleScanner.GLASS_SCREEN_FILES

        assertEquals(
            setOf(
                "feature/settings/SettingsScreen.kt",
                "feature/profile/ProfileEditScreen.kt",
                "feature/settings/BlockListScreen.kt",
                "feature/compose/PostComposerScreen.kt",
            ),
            outside,
        )
    }

    @Test
    fun `色の一式から読む書き方とガラスでない書き方は検出しない`() {
        fixture(
            "feature/settings/Ok.kt",
            """
            package com.example
            val a = Surface(color = palette.photoBadge.scrim, contentColor = palette.photoBadge.text) {}
            val b = Color.White
            val c = Color.Transparent
            val d = drawRect(color = plainColor, alpha = alpha)
            val e = spec.copy(width = 10.dp)
            val f = ErrorContent(onRetry = {}, buttonLook = ButtonLook.MATERIAL)
            val g = MaterialTheme.colorScheme.onSurfaceVariant
            val h = state.copy(isSaving = true, error = null)
            val i = ButtonDefaults.buttonColors(containerColor = palette.accent)
            val j = SolidColor(Color.Gray)
            """.trimIndent(),
        )

        assertEquals(emptyList(), ScreenStyleScanner.colorValues(fixtureRoot))
        assertEquals(emptySet(), ScreenStyleScanner.glassReferrers(fixtureRoot))
    }
}

/**
 * [ScreenStyleSourceTest] で使う走査器。本体のソースの根を受け取り、feature/ と ui/component/ の `.kt` を読む。
 * 一致はどれも、間に空白・改行を挟んでも数える。
 */
internal object ScreenStyleScanner {

    /** 見つけた 1 か所。[path] は根からの相対パス、[line] は 1 始まりの行番号、[text] は一致した文字列（空白を除いたもの）。 */
    data class Hit(val path: String, val line: Int, val text: String)

    /** 色の値の検査で読む、根の下の置き場（画面と共通の部品）。 */
    private val COLOR_VALUE_DIRS = listOf("feature", "ui/component")

    /** ガラスの部品の参照の検査で読む、根の下の置き場（画面）。 */
    private const val SCREEN_DIR = "feature"

    /**
     * ガラスの 5 画面のファイル（要件 2.1）。フィード・投稿詳細・プロフィール（自分と他人は同じファイル）・ログイン・新規登録。
     * ここに無い画面のファイルは、ガラスの部品を参照してはいけない（背景だけの画面と無地の画面。要件 2.2）。
     */
    val GLASS_SCREEN_FILES: Set<String> = setOf(
        "feature/feed/FeedScreen.kt",
        "feature/detail/PostDetailScreen.kt",
        "feature/profile/ProfileScreen.kt",
        "feature/auth/LoginScreen.kt",
        "feature/auth/SignUpScreen.kt",
    )

    /**
     * 色の値を作る書き方。数字（16 進と赤・緑・青の値）や名前付きの赤・緑・青などで作る色・不透明度を替えた写し・2 つの色の間の色。
     * 名前の付いた色（白・透明など）と、数字を変数で渡す形は数えない（設計書の決定）。
     */
    private val COLOR_VALUE_PATTERNS = listOf(
        // 数字を渡す形（16 進の直書きと、赤・緑・青の値。小数点から始まる数も）
        Regex("""\bColor\s*\(\s*\.?[0-9]"""),
        // 赤・緑・青・不透明度・色の値を名前で渡す形
        Regex("""\bColor\s*\(\s*(red|green|blue|alpha|color)\s*=(?!=)"""),
        // 不透明度を名前で渡す写し
        Regex("""\bcopy\s*\(\s*alpha\b"""),
        // 最初の引数（Color の写しでは不透明度）に数字を渡す写し。名前を付けて渡すほかの写し（data class の copy）は数えない
        Regex("""\bcopy\s*\(\s*\.?[0-9]"""),
        // 2 つの色の間の色。色でない値の間も文字では見分けられないので数える
        Regex("""\blerp\s*\("""),
    )

    /**
     * ガラスの部品の参照。Glass.kt の部品の名前・ボタンの見た目のガラス・色の一式のガラスの一式（`palette.glass.…` の形）のどれか。
     * 色の一式のガラスの一式も数えるのは、部品を使わずにガラスの色だけを読んで、5 画面の外にガラス風の面を作るのを防ぐためである。
     */
    private val GLASS_PATTERN =
        Regex("""\b(glassSurface|GlassButton|GlassTextField|AccentGradientButton)\b|\bButtonLook\s*\.\s*GLASS\b|\.\s*glass\s*\.""")

    private val WHITESPACE = Regex("""\s+""")

    /** 走査する `.kt` のファイル（根からの相対パス）。色の値の検査の範囲（feature/ と ui/component/）。 */
    fun scannedFiles(root: File): List<String> =
        COLOR_VALUE_DIRS.flatMap { dir -> ktFiles(root, dir) }.map { it.relativeTo(root).invariantSeparatorsPath }.sorted()

    /** feature/ と ui/component/ の下で、色の値を作る書き方を探す。1 行に複数が重なっても 1 件。並びはパス・行番号の順。 */
    fun colorValues(root: File): List<Hit> =
        COLOR_VALUE_DIRS.flatMap { dir -> ktFiles(root, dir) }
            .flatMap { file ->
                val path = file.relativeTo(root).invariantSeparatorsPath
                val source = file.readText()
                COLOR_VALUE_PATTERNS.flatMap { it.findAll(source) }
                    .map { match -> Hit(path, lineOf(source, match.range.first), match.value.replace(WHITESPACE, "")) }
                    .distinctBy { it.line }
            }
            .sortedWith(compareBy({ it.path }, { it.line }))

    /** feature/ の下で、ガラスの部品を参照するファイル（根からの相対パス）の集まり。 */
    fun glassReferrers(root: File): Set<String> =
        ktFiles(root, SCREEN_DIR)
            .filter { GLASS_PATTERN.containsMatchIn(it.readText()) }
            .map { it.relativeTo(root).invariantSeparatorsPath }
            .toSet()

    /** 根の下の [dir] の下の `.kt` を全て返す。[dir] が無ければ空（陽性対照の置き場に片方しか作らないとき）。 */
    private fun ktFiles(root: File, dir: String): List<File> =
        File(root, dir).walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    /** [index] の文字が何行目か（1 始まり）。 */
    private fun lineOf(source: String, index: Int): Int = source.substring(0, index).count { it == '\n' } + 1
}
