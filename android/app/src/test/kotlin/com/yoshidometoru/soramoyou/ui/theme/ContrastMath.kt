// ⭐️ コントラスト比・重ねた色・違反の一覧・色相を求めるテストの補助（タスク 3.1・要件 4.1・4.3）
package com.yoshidometoru.soramoyou.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * 層の表のテスト（SkyContrastTest）と、iOS の色との突き合わせ（IosDesignTokensTest）が使う計算をまとめた補助。
 *
 * 比の式は [SoramoyouThemeTest] の `contrastRatio` と同じ WCAG 2 の式（明るい方 + 0.05）/（暗い方 + 0.05）にする。
 * 輝度は Compose の [luminance] で求める。[luminance] は不透明度を見ないので、比の計算は不透明の色だけを受け取り、
 * 半透明の色を渡されたら失敗する。ガラスの面を背景に重ね忘れて渡す書き間違いで、表が空振りして通るのを防ぐためである。
 * 半透明の面は、先に [over] か [stack] で背景に重ねて不透明の色にしてから渡す。
 */
internal object ContrastMath {

    /** 確かめる 1 組。[label] は失敗の文言に出す名前、[minimum] はその組の基準（文字は 4.5、アイコンと枠は 3.0）。 */
    data class Check(val label: String, val foreground: Color, val background: Color, val minimum: Double)

    /** 基準に届かなかった組と、その比。 */
    data class Violation(val check: Check, val ratio: Double) {
        override fun toString(): String =
            "${check.label}: ${"%.2f".format(ratio)} < ${check.minimum}（${hex(check.foreground)} / ${hex(check.background)}）"
    }

    /** WCAG 2 のコントラスト比。[a] と [b] のどちらかが半透明なら失敗する。 */
    fun contrastRatio(a: Color, b: Color): Double {
        requireOpaque(a, "比の計算の 1 つ目")
        requireOpaque(b, "比の計算の 2 つ目")
        val (high, low) = listOf(a.luminance(), b.luminance()).sortedDescending()
        return (high + 0.05) / (low + 0.05)
    }

    /**
     * [foreground]（半透明でよい）を不透明の [background] に重ねた色。
     * Compose の [compositeOver] と同じく、sRGB の値のまま混ぜる（Android の描画と同じ）。背景が半透明なら失敗する。
     */
    fun over(foreground: Color, background: Color): Color {
        requireOpaque(background, "重ねる先の背景")
        return foreground.compositeOver(background)
    }

    /** 不透明の [base] に、[layers] を下から順に重ねた色（空＋雲＋ガラス のように）。層が無いときは [base] のまま。 */
    fun stack(base: Color, layers: List<Color>): Color = layers.fold(base) { below, layer -> over(layer, below) }

    /**
     * 不透明の [from] から [to] へのグラデーションの、[fraction]（0 で [from]、1 で [to]）の所の色。
     * 赤・緑・青の sRGB の値を、そのまま直線で混ぜる（Android のグラデーションの描き方と同じと見ている。推定）。
     * Compose の色の lerp は Oklab で混ぜる（手元の ui-graphics の jar の 1 つを javap で読んで確かめた）ので、
     * 画面に描かれる途中の色と違う色になる。ここでは使わない。
     * 半透明の色を渡されたら失敗する（混ぜた色が不透明になり、重ね忘れが表に出なくなるため）。
     */
    fun between(from: Color, to: Color, fraction: Float): Color {
        requireOpaque(from, "グラデーションの始まり")
        requireOpaque(to, "グラデーションの終わり")
        return Color(
            red = from.red + (to.red - from.red) * fraction,
            green = from.green + (to.green - from.green) * fraction,
            blue = from.blue + (to.blue - from.blue) * fraction,
        )
    }

    /** [checks] のうち、比が基準に届かない組だけを、渡した順に返す。半透明の色を含む組があれば失敗する。 */
    fun violations(checks: List<Check>): List<Violation> =
        checks.mapNotNull { check ->
            val ratio = contrastRatio(check.foreground, check.background)
            if (ratio < check.minimum) Violation(check, ratio) else null
        }

    /**
     * 色相（0 以上 360 未満の度。HSV と HSL で同じ値）。赤・緑・青の 3 つの値だけを見る。
     * 無彩色（3 つが等しい）は色相が決まらないので失敗する。0° と返すと、赤との比較が黙って通るためである。
     */
    fun hueDegrees(color: Color): Double {
        val r = color.red.toDouble()
        val g = color.green.toDouble()
        val b = color.blue.toDouble()
        val high = max(r, max(g, b))
        val low = min(r, min(g, b))
        require(high > low) { "無彩色 ${hex(color)} の色相は決まらない" }
        val delta = high - low
        val degrees = when (high) {
            r -> 60 * ((g - b) / delta)
            g -> 60 * ((b - r) / delta + 2)
            else -> 60 * ((r - g) / delta + 4)
        }
        // 赤が最大で緑が青より小さいときは負になるので、0 以上 360 未満へ戻す
        return ((degrees % 360) + 360) % 360
    }

    /** 2 つの色相の差（0〜180 の度）。350° と 10° の差は 20° のように、360 をまたいで近い方で測る。 */
    fun hueDistance(a: Double, b: Double): Double {
        val d = abs(a - b) % 360
        return min(d, 360 - d)
    }

    private fun requireOpaque(color: Color, role: String) {
        require(color.alpha == 1f) {
            "$role の色 ${hex(color)} が半透明（不透明度 ${color.alpha}）。先に背景へ重ねて不透明の色にしてから渡す"
        }
    }

    /** 失敗の文言に出す #AARRGGBB。 */
    private fun hex(color: Color): String = "#%08X".format(color.toArgb())
}
