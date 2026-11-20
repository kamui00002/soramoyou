// ⭐️ 背景の層ごとに、載る全ての文字とアイコンのコントラスト比を確かめる単体テスト（タスク 5.1・要件 3.1〜3.7・3.9・4.1・4.2・4.4）
package com.yoshidometoru.soramoyou.ui.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.ui.graphics.Color
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 設計書の「SkyContrastTest の層の表」の 9 つの層を、ライトとダークの両方で確かめる。
 *
 * - 文字などの色と背景は、全て画面と同じ [skyPaletteOf] と [soramoyouColorScheme] から読み、ここに色の値を書かない（要件 4.4）。
 *   例外は写真の札の下の「真っ白な写真」と「真っ黒な写真」で、これはアプリの色でなく、札の下に来うる写真の明るさの両端である（要件 3.7）。
 * - 背景になる色は、空の 3 色とその間の色（隣の 2 色の間を [SKY_STEPS] 等分した点）と、そこにガラスの面や雲を重ねた色。半透明の面は [ContrastMath.stack] で
 *   不透明の色にしてから比を求める（重ね忘れは [ContrastMath] が失敗させる）。
 * - 雲の層と雲の上の入力欄の層は、雲 1 つ分の濃さで確かめる。雲どうしが重ならないことは BackdropTest（タスク 8.1）が確かめる。
 * - 押せない部品の色（Material 3 の onSurface の 38% など）は表に入れない（要件 3.9）。
 * - 層ごとに、基準に届かない組（配色・層・背景・色・比・基準）を全て集めてから比べ、1 回の失敗で全て並べる。
 */
class SkyContrastTest {

    @Test
    fun `空の3色とその間の色の上で、本文・補助・アクセント・エラーは4_5以上、いいね済みと枠は3_0以上ある`() {
        assertLayer("空") { grid(skyBackgrounds(), onSky()) }
    }

    @Test
    fun `空にガラスの面を重ねた色の上で、空の層の色とガラスのボタンの文字が基準以上ある`() {
        assertLayer("ガラス") {
            grid(
                glassBackgrounds(),
                onSky() + Foreground("ガラスのボタンの文字（glass.buttonContent）", palette.glass.buttonContent, TEXT),
            )
        }
    }

    @Test
    fun `空に雲を1つ重ねた色の上で、本文・補助・アクセント・エラーは4_5以上、枠は3_0以上ある`() {
        assertLayer("雲") { grid(cloudBackgrounds(), textAndOutline()) }
    }

    @Test
    fun `空に最も濃い雲と入力欄の面を重ねた色の上で、入力欄の文字は4_5以上、枠とカーソルは3_0以上ある`() {
        // アクセントとエラーは、この重なりでは枠とカーソルにだけ使い、文字として載せない（設計書「ガラスの部品」）
        assertLayer("雲の上の入力欄") {
            grid(
                cloudInputBackgrounds(),
                listOf(
                    Foreground("入力欄のラベルと文字（glass.inputContent）", palette.glass.inputContent, TEXT),
                    Foreground("未選択の枠（outline）", scheme.outline, GRAPHIC),
                    Foreground("選択中の枠とカーソル（primary）", scheme.primary, GRAPHIC),
                    Foreground("エラーの枠（error）", scheme.error, GRAPHIC),
                ),
            )
        }
    }

    @Test
    fun `無地の背景の上で、空の層と同じ色が基準以上ある`() {
        assertLayer("無地") { grid(listOf(Background("無地（background）", scheme.background)), onSky()) }
    }

    @Test
    fun `ダイアログとメニューの面の上で、本文・補助・主色・エラーの文字が4_5以上ある`() {
        assertLayer("ダイアログとメニュー") {
            grid(
                listOf(
                    Background("ダイアログの面（surfaceContainerHigh）", scheme.surfaceContainerHigh),
                    Background("メニューの面（surfaceContainer）", scheme.surfaceContainer),
                ),
                listOf(
                    Foreground("本文（onSurface）", scheme.onSurface, TEXT),
                    Foreground("補助（onSurfaceVariant）", scheme.onSurfaceVariant, TEXT),
                    Foreground("文字だけのボタン（primary）", scheme.primary, TEXT),
                    Foreground("エラー（error）", scheme.error, TEXT),
                ),
            )
        }
    }

    @Test
    fun `塗りの部品の面の上で、その上の文字が4_5以上ある`() {
        assertLayer("塗りの部品") {
            listOf(
                Background("塗りのボタンの面（primary）", scheme.primary) to
                    Foreground("塗りのボタンの文字（onPrimary）", scheme.onPrimary, TEXT),
                Background("エラーの面（error）", scheme.error) to
                    Foreground("エラーの面の文字（onError）", scheme.onError, TEXT),
                Background("選んだ区切りボタンの面（secondaryContainer）", scheme.secondaryContainer) to
                    Foreground("選んだ区切りボタンの文字（onSecondaryContainer）", scheme.onSecondaryContainer, TEXT),
            )
        }
    }

    @Test
    fun `ログインのボタンのグラデーションの両端で、ボタンの文字が4_5以上ある`() {
        // 2 色の間で白い文字の比が最も下がるのは端の色である（設計書「3色と白・黒だけを確かめればよい根拠」）
        assertLayer("ログインのボタン") {
            grid(
                palette.accentGradient.mapIndexed { i, color -> Background("グラデーションの${GRADIENT_ENDS[i]}", color) },
                listOf(Foreground("ボタンの文字（onAccentGradient）", palette.onAccentGradient, TEXT)),
            )
        }
    }

    @Test
    fun `真っ白な写真と真っ黒な写真に札の面を重ねた色の上で、札の文字が4_5以上ある`() {
        // 札の面を重ねた色の輝度は、写真の色について単調なので、両端の 2 つで全ての写真を代表できる（設計書の同じ根拠）
        assertLayer("写真の札") {
            grid(
                PHOTO_EXTREMES.map { (name, photo) ->
                    Background("${name}＋札の面", ContrastMath.stack(photo, listOf(palette.photoBadge.scrim)))
                },
                listOf(Foreground("札の文字", palette.photoBadge.text, TEXT)),
            )
        }
    }

    // MARK: - 層の組み立て

    /**
     * 層 1 つを、ライトとダークの両方で確かめる。[pairsOf] は配色ごとに、背景とその上に載る色の組を返す。
     * 落ちた組は「配色 ／ 層 ／ 背景 ／ 色: 比 < 基準（色 / 背景）」の形で全て並べる（比と基準は [ContrastMath.Violation] が付ける）。
     */
    private fun assertLayer(layer: String, pairsOf: ThemeColors.() -> List<Pair<Background, Foreground>>) {
        val checks = themes.flatMap { theme ->
            val pairs = theme.pairsOf()
            // 一覧が空のまま通る空振りを防ぐ
            assertTrue(pairs.isNotEmpty(), "${theme.name} の $layer の層に、確かめる組が無い")
            pairs.map { (background, foreground) ->
                ContrastMath.Check(
                    label = "${theme.name} ／ $layer ／ ${background.name} ／ ${foreground.name}",
                    foreground = foreground.color,
                    background = background.color,
                    minimum = foreground.minimum,
                )
            }
        }
        val violations = ContrastMath.violations(checks)
        println("$layer の層: ${checks.size} 組のうち、基準に届かない組 ${violations.size}")
        assertEquals(emptyList(), violations.map { it.toString() }, "$layer の層に、基準に届かない組がある")
    }

    /** [backgrounds] の全てと [foregrounds] の全てを組み合わせる。 */
    private fun grid(backgrounds: List<Background>, foregrounds: List<Foreground>): List<Pair<Background, Foreground>> =
        backgrounds.flatMap { background -> foregrounds.map { foreground -> background to foreground } }

    /**
     * 空の 3 色（上・中・下）と、隣の 2 色の間を [SKY_STEPS] 等分した点の色（上から下へ並ぶ）。
     * 間の色も入れるのは、iOS の空の色を写し直したときに、端の色は基準を満たしても途中の色で割るのに気づくためである
     * （設計書の「3色と白・黒だけを確かめればよい根拠」は今の 3 色についての話で、色相の回る組では成り立たない）。
     * 間の色は、赤・緑・青の値を直線で混ぜる（[ContrastMath.between]。描く側の SkyBackdrop の縦のグラデーションと同じと見ている＝推定）。
     */
    private fun ThemeColors.skyBackgrounds(): List<Background> {
        val sky = palette.skyGradient
        return sky.indices.flatMap { i ->
            val end = Background("空の${SKY_POSITIONS[i]}", sky[i])
            if (i == sky.lastIndex) {
                listOf(end)
            } else {
                listOf(end) + (1 until SKY_STEPS).map { k ->
                    Background(
                        "空の${SKY_POSITIONS[i]}→${SKY_POSITIONS[i + 1]}の$k/$SKY_STEPS",
                        ContrastMath.between(sky[i], sky[i + 1], k.toFloat() / SKY_STEPS),
                    )
                }
            }
        }
    }

    /** 空の 3 色それぞれに、[layers] を下から順に重ねた色。[name] は重ねたものの名前。 */
    private fun ThemeColors.skyWith(name: String, layers: List<Color>): List<Background> =
        skyBackgrounds().map { sky -> Background("${sky.name}＋$name", ContrastMath.stack(sky.color, layers)) }

    /** ガラスの層の背景：空の 3 色に、4 つのガラスの部品の面をそれぞれ重ねた色。 */
    private fun ThemeColors.glassBackgrounds(): List<Background> =
        listOf(
            "投稿のカードの面" to palette.glass.postCard,
            "カードの面" to palette.glass.card,
            "入力欄の面" to palette.glass.input,
            "ガラスのボタンの面" to palette.glass.button,
        ).flatMap { (name, style) -> skyWith(name, listOf(style.fill)) }

    /** 雲の層の背景：空の 3 色に、4 つの雲を 1 つずつ重ねた色。 */
    private fun ThemeColors.cloudBackgrounds(): List<Background> =
        palette.clouds.flatMapIndexed { i, cloud -> skyWith("雲${i + 1}", listOf(cloudColor(cloud))) }

    /** 雲の上の入力欄の層の背景：空の 3 色に、最も濃い雲と入力欄のガラスの面を重ねた色。 */
    private fun ThemeColors.cloudInputBackgrounds(): List<Background> {
        val densest = palette.clouds.withIndex().maxBy { it.value.alpha }
        return skyWith("雲${densest.index + 1}＋入力欄の面", listOf(cloudColor(densest.value), palette.glass.input.fill))
    }

    /** 雲の層に載る色：本文・補助・アクセント・エラー（4.5）と枠（3.0）。いいね済みのハートは雲の上に置かない。 */
    private fun ThemeColors.textAndOutline(): List<Foreground> = listOf(
        Foreground("本文（onBackground）", scheme.onBackground, TEXT),
        Foreground("本文（onSurface）", scheme.onSurface, TEXT),
        Foreground("補助（onSurfaceVariant）", scheme.onSurfaceVariant, TEXT),
        Foreground("アクセント（primary）", scheme.primary, TEXT),
        Foreground("エラー（error）", scheme.error, TEXT),
        Foreground("枠（outline）", scheme.outline, GRAPHIC),
    )

    /** 空の層に載る色：雲の層の色と、いいね済み（3.0）。ガラスと無地の層にも同じ色が載る。 */
    private fun ThemeColors.onSky(): List<Foreground> =
        textAndOutline() + Foreground("いいね済み（liked）", palette.liked, GRAPHIC)

    /** 雲の色。[CloudSpec.alpha] は白の不透明度で、雲は白にこの濃さを付けて描く（SkyPalette.kt の [CloudSpec]）。 */
    private fun cloudColor(cloud: CloudSpec): Color = Color.White.copy(alpha = cloud.alpha)

    // MARK: - 型と値

    /** 確かめる配色 1 つ。画面と同じ関数から、色の一式と Material 3 の配色を読む。 */
    private class ThemeColors(val name: String, darkTheme: Boolean) {
        val palette: SkyPalette = skyPaletteOf(darkTheme)
        val scheme: ColorScheme = soramoyouColorScheme(darkTheme)
    }

    /** 背景になる不透明の色と、失敗の文言に出す名前。 */
    private data class Background(val name: String, val color: Color)

    /** 背景の上に載る色と、その基準（[TEXT] か [GRAPHIC]）。 */
    private data class Foreground(val name: String, val color: Color, val minimum: Double)

    /** 確かめる 2 つの配色。 */
    private val themes = listOf(ThemeColors("ライト", darkTheme = false), ThemeColors("ダーク", darkTheme = true))

    private companion object {
        /** 文字の基準（WCAG 2 の本文。要件 3.1）。 */
        const val TEXT = 4.5

        /** 操作を表すアイコン・状態を色で示す部分・枠の基準（要件 3.5）。 */
        const val GRAPHIC = 3.0

        /** 空の 3 色の位置の名前（上→中→下）。 */
        val SKY_POSITIONS = listOf("上", "中", "下")

        /** 空の隣の 2 色の間を何等分して確かめるか。点と点の間の色は確かめていない（輝度は滑らかに変わるので、点の間だけで大きく割ることは無いと見ている。推定）。 */
        const val SKY_STEPS = 16

        /** ログインのボタンのグラデーションの両端の名前（左上→右下）。 */
        val GRADIENT_ENDS = listOf("始点（左上）", "終点（右下）")

        /** 札の下に来うる写真の明るさの両端。アプリの色でなく、写真の色の範囲を表す（要件 3.7）。 */
        val PHOTO_EXTREMES = listOf("真っ白な写真" to Color.White, "真っ黒な写真" to Color.Black)
    }
}
