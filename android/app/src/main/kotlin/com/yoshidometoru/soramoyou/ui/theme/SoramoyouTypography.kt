// ⭐️ Material 3 の書体の役の文字の大きさを、iOS 版の文字の大きさに付け替えた書体の一式（タスク 4.3・要件 5.3・5.4・設計書 P7）
package com.yoshidometoru.soramoyou.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp

/**
 * 設計書の「書体の対応表」のとおり、Material 3 の 15 の役の文字の大きさを、iOS 版の `DesignTokens.Typography` の値にした書体の一式。
 *
 * - 大きさは [DesignTokens.Typography] から読み、数を書き写さない。トークンに無い 24（headlineSmall）と 22（titleLarge）は、
 *   subtitleSize（20）に寄せる（28 に上げるより、文字 200% で見出しの行があふれにくいため。設計書の P7）。
 * - 太さは Material 3 の各役のまま変えない。行の高さは、各役の「行の高さ÷大きさ」の比を保って求める（[scaledTo]）。
 * - 大きさも行の高さも sp のままなので、端末の文字サイズの設定に合わせて大きくなる（要件 5.4）。
 *
 * 描画から切り離した値なので、JVM の単体テスト（SoramoyouTypographyTest）でそのまま確かめる（タスク 2 で作れることを確かめた）。
 * テーマに渡すのはタスク 4.4 である。
 */
fun soramoyouTypography(): Typography {
    val base = Typography()
    val size = DesignTokens.Typography
    return base.copy(
        displayLarge = base.displayLarge.scaledTo(size.heroSize),
        displayMedium = base.displayMedium.scaledTo(size.heroSize),
        displaySmall = base.displaySmall.scaledTo(size.heroSize),
        headlineLarge = base.headlineLarge.scaledTo(size.titleSize),
        headlineMedium = base.headlineMedium.scaledTo(size.titleSize),
        headlineSmall = base.headlineSmall.scaledTo(size.subtitleSize),
        titleLarge = base.titleLarge.scaledTo(size.subtitleSize),
        titleMedium = base.titleMedium.scaledTo(size.bodySize),
        titleSmall = base.titleSmall.scaledTo(size.captionSize),
        bodyLarge = base.bodyLarge.scaledTo(size.bodySize),
        bodyMedium = base.bodyMedium.scaledTo(size.captionSize),
        bodySmall = base.bodySmall.scaledTo(size.smallCaptionSize),
        labelLarge = base.labelLarge.scaledTo(size.buttonSize),
        labelMedium = base.labelMedium.scaledTo(size.smallCaptionSize),
        labelSmall = base.labelSmall.scaledTo(size.tabLabelSize),
    )
}

/**
 * 大きさを [size] にし、行の高さを元の「行の高さ÷大きさ」の比を保って求めた書体。太さ・字間など、ほかは変えない。
 * 元の大きさ・行の高さ・[size] のどれかが sp でなければ失敗させる
 * （決まっていない値〔Unspecified〕の value は NaN で、そのまま割ると行の高さが黙って NaN になるため）。
 */
private fun TextStyle.scaledTo(size: TextUnit): TextStyle {
    require(fontSize.isSp && lineHeight.isSp && size.isSp) {
        "大きさか行の高さが sp でない: 大きさ $fontSize・行の高さ $lineHeight → $size"
    }
    return copy(fontSize = size, lineHeight = (lineHeight.value / fontSize.value * size.value).sp)
}
