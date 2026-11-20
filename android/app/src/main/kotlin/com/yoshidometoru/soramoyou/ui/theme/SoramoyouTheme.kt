// ⭐️ 端末のダークテーマの設定に追従するテーマ（タスク 5.2・要件 16.4）。色の役と書体の付け替え（android-ui-ios-parity タスク 4.4）
package com.yoshidometoru.soramoyou.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember

/*
 * 配色は、設計書の「Material 3 の役の付け替え」の表のとおりにする。
 * - 主色・その上の文字・本文・補助・エラーとその上の文字・枠の役は、色の一式（[skyPaletteOf]）の色にする。
 *   空の上に全画面で載る文字の色で、空の 3 色の上でコントラスト比を満たすように色の一式が決めてある。
 * - 面の役（background・surface・surfaceContainer* など）は Material 3 の既定の不透明な色のままにする。
 *   無地の画面・ダイアログ・メニュー・写真の下地に使うので、空の色もガラスの半透明も持ち込まない。
 * - 端末の壁紙から色を作る仕組み（ダイナミックカラー）は使わない（Android 12 以上にしか無く、端末ごとに見た目が変わるため）。
 *
 * 書体は文字の大きさを iOS 版の値にした一式（[soramoyouTypography]）。sp の単位なので、端末の文字サイズの設定に合わせて大きくなる（要件 16.6）。
 * ガラス・雲・写真の札など Material 3 の役に無い色は、部品が [LocalSkyPalette] から読む。
 */

/**
 * ライト（端末がダークでないとき）の配色。lightColorScheme に役を引数で渡すので、面の色味（surfaceTint）も
 * Material 3 の既定どおり主色に揃う（copy で主色だけ替えると、既定の紫のまま残る）。
 */
private val LightColors: ColorScheme = skyPaletteOf(darkTheme = false).let { palette ->
    lightColorScheme(
        primary = palette.accent,
        onPrimary = palette.onAccent,
        onBackground = palette.text,
        onSurface = palette.text,
        onSurfaceVariant = palette.textSecondary,
        error = palette.error,
        onError = palette.onError,
        outline = palette.outline,
    )
}

/** ダーク（端末がダークのとき）の配色。役の割り当てはライトと同じで、色は夜の空の一式から取る。 */
private val DarkColors: ColorScheme = skyPaletteOf(darkTheme = true).let { palette ->
    darkColorScheme(
        primary = palette.accent,
        onPrimary = palette.onAccent,
        onBackground = palette.text,
        onSurface = palette.text,
        onSurfaceVariant = palette.textSecondary,
        error = palette.error,
        onError = palette.onError,
        outline = palette.outline,
    )
}

/**
 * 端末がダークテーマかどうか（[darkTheme]）から配色を選ぶ。描画から切り離した純関数にして、JVM の単体テストで確かめる。
 */
fun soramoyouColorScheme(darkTheme: Boolean): ColorScheme = if (darkTheme) DarkColors else LightColors

/**
 * アプリ全体のテーマ。画面は全てこの中に置く（Activity の setContent の直下で 1 回だけ使う想定）。
 *
 * [darkTheme] の既定値は端末の設定（[isSystemInDarkTheme]）で、設定を切り替えると描画し直して配色と色の一式が変わる（要件 16.4）。
 * 引数で渡せるのはプレビュー用で、アプリの中でダーク・ライトを決め打ちする設定は作らない。
 *
 * 書体は [darkTheme] に依らないので、remember で 1 回だけ作り、描き直しのたびに作り直さない。
 */
@Composable
fun SoramoyouTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalSkyPalette provides skyPaletteOf(darkTheme)) {
        MaterialTheme(
            colorScheme = soramoyouColorScheme(darkTheme),
            typography = remember { soramoyouTypography() },
            content = content,
        )
    }
}
