// ⭐️ iOS 版のデザイントークン（Utils/DesignTokens.swift）の写し（タスク 4.1・要件 1.8・5.1〜5.3・5.9）
package com.yoshidometoru.soramoyou.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * iOS 版の `DesignTokens` の `Spacing`・`Radius`・`Typography` と、そのまま使う色を Kotlin に写したもの。
 *
 * - `Spacing`・`Radius`・`Typography` は、iOS の全ての名前を同じ名前で写す（Android で使わない名前も写す）。
 *   IosDesignTokensTest が、名前の集合と値の両方を iOS のソースと突き合わせるためである。
 * - 値は iOS の `static let 名前: CGFloat = 数` と同じ数で書き、Kotlin の側で計算しない。
 *   余白と角丸は dp、文字の大きさは sp にする（sp は端末の文字サイズの設定に合わせて大きくなる。要件 5.4）。
 * - 色は、iOS の値をそのまま使うものだけを写す。要件 3 のコントラスト比のために濃さを変えた色は、ここでなく SkyPalette に置く。
 */
object DesignTokens {

    /** 余白（iOS の `DesignTokens.Spacing`）。画面の端・カードの内側・要素の間に使う（要件 5.1）。 */
    object Spacing {
        /** 極小。 */
        val xs: Dp = 4.dp

        /** 小。 */
        val sm: Dp = 8.dp

        /** 中。 */
        val md: Dp = 16.dp

        /** 大。 */
        val lg: Dp = 24.dp

        /** 特大。 */
        val xl: Dp = 32.dp

        /** 巨大。 */
        val xxl: Dp = 48.dp

        /** 画面の端の余白。 */
        val screenMargin: Dp = 20.dp

        /** カードの内側の余白。 */
        val cardPadding: Dp = 16.dp

        /**
         * iOS の名前 → 値。IosDesignTokensTest が iOS の `Spacing` と完全に一致することを確かめる。
         * 数を書き写さずに上の値を参照する（数を二重に書くと、上の値を書き換えてもこの表が古いまま残り、突き合わせが空振りする）。
         */
        internal val byIosName: Map<String, Dp> = mapOf(
            "xs" to xs,
            "sm" to sm,
            "md" to md,
            "lg" to lg,
            "xl" to xl,
            "xxl" to xxl,
            "screenMargin" to screenMargin,
            "cardPadding" to cardPadding,
        )
    }

    /** 角丸（iOS の `DesignTokens.Radius`）。名前は [Spacing] と重なるが、別の値である（要件 5.2）。 */
    object Radius {
        /** 小。 */
        val sm: Dp = 8.dp

        /** 中。 */
        val md: Dp = 12.dp

        /** 大。 */
        val lg: Dp = 16.dp

        /** 特大。 */
        val xl: Dp = 20.dp

        /** 巨大（浮いて見える部品用）。 */
        val xxl: Dp = 28.dp

        /** カード用。 */
        val card: Dp = 16.dp

        /** ボタン用。 */
        val button: Dp = 14.dp

        /** 両端を丸め切る形（錠剤の形）。 */
        val full: Dp = 100.dp

        /** チップ用。 */
        val chip: Dp = 20.dp

        /** iOS の名前 → 値（[Spacing.byIosName] と同じく、上の値を参照する）。 */
        internal val byIosName: Map<String, Dp> = mapOf(
            "sm" to sm,
            "md" to md,
            "lg" to lg,
            "xl" to xl,
            "xxl" to xxl,
            "card" to card,
            "button" to button,
            "full" to full,
            "chip" to chip,
        )
    }

    /** 文字の大きさ（iOS の `DesignTokens.Typography`）。全て sp の単位である（要件 5.3・5.4）。 */
    object Typography {
        /** タイトル。 */
        val titleSize: TextUnit = 28.sp

        /** サブタイトル。 */
        val subtitleSize: TextUnit = 20.sp

        /** 本文。 */
        val bodySize: TextUnit = 17.sp

        /** キャプション。 */
        val captionSize: TextUnit = 14.sp

        /** 小さいキャプション。 */
        val smallCaptionSize: TextUnit = 12.sp

        /** 大見出し。 */
        val heroSize: TextUnit = 42.sp

        /** ボタンの文字。 */
        val buttonSize: TextUnit = 17.sp

        /** タブの見出し。 */
        val tabLabelSize: TextUnit = 11.sp

        /** iOS の名前 → 値（[Spacing.byIosName] と同じく、上の値を参照する）。 */
        internal val byIosName: Map<String, TextUnit> = mapOf(
            "titleSize" to titleSize,
            "subtitleSize" to subtitleSize,
            "bodySize" to bodySize,
            "captionSize" to captionSize,
            "smallCaptionSize" to smallCaptionSize,
            "heroSize" to heroSize,
            "buttonSize" to buttonSize,
            "tabLabelSize" to tabLabelSize,
        )
    }

    /**
     * iOS の値をそのまま使う色（iOS の `DesignTokens.Colors` の一部）。
     * 色は iOS の `Color(red:green:blue:)` と同じ 3 つの数で書く。コメントの 16 進数は、8 ビットに丸めたときの値である。
     * 白の不透明度は、色でなく数で持つ（白に重ねる面や文字の色は、SkyPalette がこの数から作る）。
     */
    object Colors {
        /** 昼の空のグラデーション。上→中→下（#ADD9E6・#87CFFA・#6394ED）。ライトの背景に使う（要件 1.8）。 */
        val daySkyGradient: List<Color> = listOf(
            Color(red = 0.68f, green = 0.85f, blue = 0.90f), // 淡い空色
            Color(red = 0.53f, green = 0.81f, blue = 0.98f), // 空色
            Color(red = 0.39f, green = 0.58f, blue = 0.93f), // 深い空色
        )

        /** 夜の空のグラデーション。上→中→下（#263359・#1A264D・#0D1A40）。ダークの背景に使う（要件 1.8）。 */
        val nightSkyGradient: List<Color> = listOf(
            Color(red = 0.15f, green = 0.20f, blue = 0.35f), // 深い紺
            Color(red = 0.10f, green = 0.15f, blue = 0.30f), // 夜空
            Color(red = 0.05f, green = 0.10f, blue = 0.25f), // 濃い夜空
        )

        /** 明るい背景の上の暗い文字の色（#262633）。 */
        val textDark: Color = Color(red = 0.15f, green = 0.15f, blue = 0.20f)

        /** 暗い背景の上の文字の色（iOS の `textPrimary` は `Color.white`）。 */
        val textPrimary: Color = Color.White

        /** やわらかいピンク（#F2B3BF）。 */
        val softPink: Color = Color(red = 0.95f, green = 0.70f, blue = 0.75f)

        /** ガラスの面（プライマリ）の白の不透明度（iOS の `glassPrimary`）。 */
        val glassPrimaryAlpha: Float = 0.25f

        /** ガラスの面（セカンダリ）の白の不透明度（iOS の `glassSecondary`）。 */
        val glassSecondaryAlpha: Float = 0.15f

        /** ガラスの面（ターシャリ・より透明）の白の不透明度（iOS の `glassTertiary`）。 */
        val glassTertiaryAlpha: Float = 0.08f

        /** ガラスの縁（セカンダリ）の白の不透明度（iOS の `glassBorderSecondary`）。 */
        val glassBorderSecondaryAlpha: Float = 0.3f

        /** ガラスの縁（アクセント）のグラデーションの、始点 → 終点の白の不透明度（iOS の `glassBorderAccentStart`・`glassBorderAccentEnd`）。 */
        val glassBorderAccentAlphas: Pair<Float, Float> = 0.6f to 0.1f

        /** 補助の文字の白の不透明度（iOS の `textSecondary`）。 */
        val textSecondaryAlpha: Float = 0.85f

        /** さらに控えめな文字の白の不透明度（iOS の `textTertiary`）。 */
        val textTertiaryAlpha: Float = 0.70f
    }
}
