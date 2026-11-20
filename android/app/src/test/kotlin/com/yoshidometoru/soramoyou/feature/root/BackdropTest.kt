// ⭐️ 根の画面と今の行き先から、いちばん外側に敷く背景の種類を決める判定（backdropOf）と、雲の置き場（cloudRects）の単体テスト（android-ui-ios-parity タスク 7.2・8.1・要件 1.1・1.2・1.4・1.9・2.3・2.4・3.2）
package com.yoshidometoru.soramoyou.feature.root

import androidx.compose.ui.unit.DpRect
import androidx.compose.ui.unit.dp
import com.yoshidometoru.soramoyou.ui.component.BackdropKind
import com.yoshidometoru.soramoyou.ui.component.cloudRects
import com.yoshidometoru.soramoyou.ui.theme.CloudSpec
import com.yoshidometoru.soramoyou.ui.theme.SkyPalette
import com.yoshidometoru.soramoyou.ui.theme.skyPaletteOf
import java.io.File
import kotlin.math.abs
import kotlin.reflect.KClass
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 期待の種類は、ROUTES_WITH_PLAIN_BACKDROP から計算せずに、下の表へ直接書く。集合から計算すると、集合を壊したときに
 * 期待も一緒に動いてしまい、テストが落ちなくなる（陽性対照が取れない）。
 *
 * 行き先の比較は、BannerAdSlotPlacementTest と同じく、行き先をルートの型そのもので表して == で比べる
 * （本物は Navigation の NavDestination.hasRoute。本番の配線は端末で確かめる・タスク 7.4）。
 *
 * 雲の置き場（cloudRects・タスク 8.1）のテストは、ライトとダークの両方の色の一式で、幅 320〜1280dp・高さ 200〜1280dp の
 * どの窓でも雲どうしが重ならないことを総当たりで確かめる（設計書の BackdropTest）。総当たりが空の一覧で素通りしないように、
 * 決まった窓の矩形と残る雲を、式から計算せずに数で直接書いて比べるテストを 2 つ並べる。
 * 重なりを除く処理を外す陽性対照（設計書の手順 5）では、総当たりが高さ 240dp の窓の雲1と雲3で落ちる。
 */
class BackdropTest {

    private val appSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/root/SoramoyouApp.kt")

    /** ログイン後のナビゲーションに置いた全てのルート。下のテストで、SoramoyouApp.kt の NavHost と同じ顔ぶれかを確かめる。 */
    private val allRoutes: List<KClass<*>> = listOf(
        FeedRoute::class,
        SettingsRoute::class,
        PostComposeRoute::class,
        PostDetailRoute::class,
        ProfileRoute::class,
        ProfileEditRoute::class,
        UserProfileRoute::class,
        BlockListRoute::class,
        FeedbackRoute::class,
        AccountDeletionRoute::class,
    )

    /**
     * 表：根の画面ごと・行き先ごとの背景の種類（行き先の null は「未定」＝NavHost がグラフを置く前の最初の描画）。
     * - 読み込み中は、行き先に依らず空
     * - ログイン前は、行き先に依らず空と雲
     * - ログイン済みは、投稿の作成だけ無地（写真の色を見て選ぶ画面なので空を敷かない・D5）。ほかの行き先と未定は空
     */
    private val table: Map<RootScreen, Map<KClass<*>?, BackdropKind>> = mapOf(
        RootScreen.LOADING to (listOf<KClass<*>?>(null) + allRoutes).associateWith { BackdropKind.SKY },
        RootScreen.SIGNED_OUT to (listOf<KClass<*>?>(null) + allRoutes).associateWith { BackdropKind.SKY_WITH_CLOUDS },
        RootScreen.SIGNED_IN to mapOf(
            null to BackdropKind.SKY,
            FeedRoute::class to BackdropKind.SKY,
            SettingsRoute::class to BackdropKind.SKY,
            PostComposeRoute::class to BackdropKind.PLAIN,
            PostDetailRoute::class to BackdropKind.SKY,
            ProfileRoute::class to BackdropKind.SKY,
            ProfileEditRoute::class to BackdropKind.SKY,
            UserProfileRoute::class to BackdropKind.SKY,
            BlockListRoute::class to BackdropKind.SKY,
            FeedbackRoute::class to BackdropKind.SKY,
            AccountDeletionRoute::class to BackdropKind.SKY,
        ),
    )

    /** 行き先をルートの型そのもので表したときの判定。 */
    private fun backdropAt(screen: RootScreen, destination: KClass<*>?): BackdropKind =
        backdropOf(screen, destination) { current, route -> current == route }

    /** [source] の NavHost に composable で置いたルートの名前。 */
    private fun composableRoutesIn(source: String): Set<String> =
        Regex("""composable<(\w+)>""").findAll(source).map { it.groupValues[1] }.toSet()

    @Test
    fun `根の画面3つと全ての行き先（未定を含む）で、表のとおりの種類を返す`() {
        // ずれた組を 1 つで止めずに全て集め、最後に 1 回だけ比べる（陽性対照で、どの組が落ちたかを 1 回の文言で読めるように）
        val mismatches = RootScreen.entries.flatMap { screen ->
            (listOf<KClass<*>?>(null) + allRoutes).mapNotNull { destination ->
                // 表に無い根の画面や行き先は getValue が投げる（根の画面や行き先を足したら、表にも足させるため）
                val expected = table.getValue(screen).getValue(destination)
                val actual = backdropAt(screen, destination)
                if (actual == expected) null else "$screen × ${destination?.simpleName ?: "未定"}：期待 $expected・実際 $actual"
            }
        }

        assertEquals(emptyList(), mismatches, "表と違う種類を返した組がある")
    }

    @Test
    fun `表の行き先は、NavHostに置いた全てのルートと同じ顔ぶれである`() {
        assertTrue(appSource.isFile, "SoramoyouApp.kt が見つからない: ${appSource.absolutePath}")

        assertEquals(
            composableRoutesIn(appSource.readText()),
            allRoutes.map { route -> route.simpleName }.toSet(),
            "NavHost のルートと表の行き先が違う（ルートを足したら、表と allRoutes にも足す）",
        )
    }

    @Test
    fun `陽性対照：NavHostのルートの名前を、引数の有無に依らず拾う`() {
        val source = """
            NavHost(navController = navController, startDestination = FeedRoute) {
                composable<FeedRoute> { }
                composable<NewRoute> { backStackEntry -> }
            }
        """.trimIndent()

        assertEquals(setOf("FeedRoute", "NewRoute"), composableRoutesIn(source))
    }

    // --- 雲の置き場（cloudRects・タスク 8.1） ---

    /** ライトとダークの色の一式。雲の大きさと位置は両方で同じで濃さだけが違うが、どちらも本物の一式から読んで同じ規則で確かめる。 */
    private val palettes: List<SkyPalette> = listOf(skyPaletteOf(darkTheme = false), skyPaletteOf(darkTheme = true))

    /** 失敗の文言に出す、色の一式の名前。 */
    private fun SkyPalette.label(): String = if (isDark) "ダーク" else "ライト"

    /** 雲の番号（雲1〜雲4）。返った組の雲が、色の一式の雲の並びの何番目か（1 始まり）。 */
    private fun SkyPalette.cloudNumberOf(cloud: CloudSpec): Int = clouds.indexOf(cloud) + 1

    /** 雲の番号の並びを、失敗の文言に出す形（例「雲1・雲2・雲4」）にする。空なら「（無し）」。 */
    private fun numbersText(numbers: List<Int>): String =
        if (numbers.isEmpty()) "（無し）" else numbers.joinToString("・") { number -> "雲${number}" }

    /**
     * テストの側の「重なる」。本体の判定を呼ばずに、ここで独立に書く（本体の判定を壊したときに、テストの判定も一緒に動かないように）。
     * 定義は本体と同じく内部が交わることで、辺が接するだけは重ならない。
     */
    private fun intersects(a: DpRect, b: DpRect): Boolean =
        a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom

    /** 重なった 1 組。[first] と [second] は雲の番号で、[first] が小さいほう。[width] と [height] は窓の大きさ（dp）。 */
    private data class CloudOverlap(val palette: String, val width: Int, val height: Int, val first: Int, val second: Int)

    /** 重なった組の、雲の組の種類（例「ライト・雲1×雲3」）。 */
    private val CloudOverlap.kind: String get() = "${palette}・雲${first}×雲${second}"

    /**
     * 重なった組の一覧を、失敗の文言で読める短い要約にする。重なりが無ければ空の一覧を返す。
     * 全ての組をそのまま並べると十数万行になるので、総数と、雲の組の種類ごとの件数・窓の高さと幅の範囲と、
     * 幅 320・高さ 240 の窓の組だけを書く。陽性対照（設計書の手順 5）で「高さ 240dp の窓で雲1と雲3が重なった」を、この文言から読むためである。
     */
    private fun summarize(overlaps: List<CloudOverlap>): List<String> {
        if (overlaps.isEmpty()) return emptyList()
        val byKind = overlaps.groupBy { it.kind }.map { (kind, group) ->
            val heights = group.map { it.height }.distinct()
            "${kind}：${group.size} 組・高さ ${heights.min()}〜${heights.max()}dp（${heights.size} 通り）・" +
                "幅 ${group.minOf { it.width }}〜${group.maxOf { it.width }}dp"
        }
        val probe = overlaps.filter { it.width == 320 && it.height == 240 }
        val probeLine = "幅 320・高さ 240 の窓：" +
            (if (probe.isEmpty()) "重なり無し" else probe.joinToString("、") { it.kind })
        return listOf("重なった組の総数 ${overlaps.size}") + byKind + probeLine
    }

    /**
     * 総当たり。ライトとダークの両方で、幅 320〜1280dp・高さ 200〜1280dp の全ての窓（1dp 刻み）について、
     * 返った矩形のどの 2 つも重ならないことを確かめる。重なった組は 1 つで止めずに全て集め、要約にして最後に 1 回だけ比べる。
     * 本体が空の一覧を返しても、このテストは通ってしまう。それを防ぐのが、下の 2 つのテスト（決まった窓の矩形と、残る雲）である。
     */
    @Test
    fun `雲の置き場：幅320〜1280dp・高さ200〜1280dpのどの窓でも、互いに重なる矩形を返さない`() {
        val overlaps = mutableListOf<CloudOverlap>()
        for (palette in palettes) {
            for (width in 320..1280) {
                for (height in 200..1280) {
                    val placed = cloudRects(palette.clouds, width.dp, height.dp)
                    // 返った矩形の 2 つずつの全ての組（同じ組を 2 回数えない）
                    for (i in placed.indices) {
                        for (j in i + 1 until placed.size) {
                            val (cloudA, rectA) = placed[i]
                            val (cloudB, rectB) = placed[j]
                            if (intersects(rectA, rectB)) {
                                val (first, second) =
                                    listOf(palette.cloudNumberOf(cloudA), palette.cloudNumberOf(cloudB)).sorted()
                                overlaps += CloudOverlap(palette.label(), width, height, first, second)
                            }
                        }
                    }
                }
            }
        }

        assertEquals(emptyList(), summarize(overlaps), "互いに重なる雲の矩形を返した窓がある")
    }

    /**
     * 空振りの防止その 1。幅 400・高さ 800 の窓では 4 つとも重ならずに残り（この並び）、矩形が iOS の式のとおりになる。
     * 期待の矩形は式から計算せずに、数を直接書く（式を壊したときに期待も一緒に動かないように）。比べは各辺 0.01dp 以内。
     * 上の総当たりのテストが、本体が空の一覧を返したときに素通りするのを防ぐ。
     */
    @Test
    fun `雲の置き場：幅400・高さ800の窓では4つとも残り、iOSの式のとおりの矩形になる`() {
        // 雲の番号 → 左・上・右・下（dp）。手で確かめた値（箱は 200×80。例えば雲2 は、左 =（200 − 140）÷ 2 + 400 − 80 = 350、
        // 上 =（80 − 55）÷ 2 + 0.12 × 800 = 108.5）
        val expected: Map<Int, List<Float>> = linkedMapOf(
            1 to listOf(-30f, 69f, 150f, 139f),
            2 to listOf(350f, 108.5f, 490f, 163.5f),
            3 to listOf(30f, 263.5f, 190f, 328.5f),
            4 to listOf(270f, 440f, 470f, 520f),
        )
        val sideNames = listOf("左", "上", "右", "下")

        // ずれを 1 つで止めずに全て集め、最後に 1 回だけ比べる
        val mismatches = palettes.flatMap { palette ->
            val placed = cloudRects(palette.clouds, 400.dp, 800.dp)
            val numbers = placed.map { (cloud, _) -> palette.cloudNumberOf(cloud) }
            buildList<String> {
                if (numbers != expected.keys.toList()) {
                    add("${palette.label()}：残った雲 期待 ${numbersText(expected.keys.toList())}・実際 ${numbersText(numbers)}")
                }
                expected.forEach { (number, sides) ->
                    val rect = placed.firstOrNull { (cloud, _) -> palette.cloudNumberOf(cloud) == number }?.second
                    if (rect == null) {
                        add("${palette.label()}・雲${number}：返っていない")
                    } else {
                        val actualSides = listOf(rect.left.value, rect.top.value, rect.right.value, rect.bottom.value)
                        sideNames.indices.forEach { k ->
                            if (abs(actualSides[k] - sides[k]) > 0.01f) {
                                add("${palette.label()}・雲${number}の${sideNames[k]}：期待 ${sides[k]}・実際 ${actualSides[k]}")
                            }
                        }
                    }
                }
            }
        }

        assertEquals(emptyList(), mismatches, "幅 400・高さ 800 の窓で、残った雲か矩形が iOS の式と違う")
    }

    /**
     * 空振りの防止その 2。幅 320・高さ 240 の窓では、雲3 が先に残した雲1 に重なるので除かれ、残るのは雲1・雲2・雲4 の 3 つ（この並び）になる。
     * ライトとダークの両方で確かめる。上の総当たりのテストが空の一覧で素通りするのを防ぎ、重なりを除く向きが「iOS の並びで先の雲を残す」
     * であることも確かめる（後の雲を残す書き方だと、雲1 が除かれて落ちる）。
     */
    @Test
    fun `雲の置き場：幅320・高さ240の窓では、雲1に重なる雲3を除き、雲1・雲2・雲4をこの並びで残す`() {
        val mismatches = palettes.mapNotNull { palette ->
            val kept = cloudRects(palette.clouds, 320.dp, 240.dp).map { (cloud, _) -> palette.cloudNumberOf(cloud) }
            if (kept == listOf(1, 2, 4)) null else "${palette.label()}：期待 雲1・雲2・雲4・実際 ${numbersText(kept)}"
        }

        assertEquals(emptyList(), mismatches, "幅 320・高さ 240 の窓で、残った雲が違う")
    }
}
