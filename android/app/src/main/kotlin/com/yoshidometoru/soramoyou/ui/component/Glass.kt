// ⭐️ ガラスの面・ガラスのボタン・ガラスの入力欄・ログインのグラデーションのボタン（android-ui-ios-parity タスク 9.1・9.2・9.3・要件 2.1・2.5・3.2・3.4・3.8・3.9・5.2・5.5・6.1・6.3・7.1・7.3）
package com.yoshidometoru.soramoyou.ui.component

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LocalMinimumInteractiveComponentSize
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.yoshidometoru.soramoyou.ui.theme.DISABLED_GLASS_ALPHA
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens
import com.yoshidometoru.soramoyou.ui.theme.GlassStyle
import com.yoshidometoru.soramoyou.ui.theme.LocalSkyPalette

/*
 * ガラスの 5 画面（要件 2.1）で使う、ガラス風の部品を 1 つのファイルにまとめる。
 * あるのは、ガラスの面の修飾子（glassSurface）・ガラスのボタン（GlassButton）・ボタンの見た目の種類（ButtonLook）・
 * ガラスの入力欄（GlassTextField・タスク 9.2）・ログインのグラデーションのボタン（AccentGradientButton・タスク 9.3）の 5 つ
 * （同じファイルを書くので、9.1 → 9.2 → 9.3 の順に足した）。
 *
 * 作りの決まり（どの部品も同じ）:
 * - ぼかしと影を付けない（要件 3.8・5.5。設計書の P4・P5）。ぼかしの使えない古い Android を含めて、全てのバージョンで同じ見た目にする。
 *   iOS の ultraThinMaterial と DesignTokens.Shadow の代わりに、色の一式の半透明の白の面と白の縁だけで描く。
 * - 意味の節を足さない（要件 6.1・6.3）。ガラスの面は修飾子だけで描き、Material 3 の面の部品（Surface）で包まないので、
 *   まとまりやタッチを止める処理が増えず、TalkBack が読む文言・役割・順序は今のまま変わらない。
 * - 高さを固定しない（要件 7.1・7.3）。中の文字の量で伸びる。ui の下の固定の大きさの検査（FixedHeightInUiTest）は、
 *   このファイルのコメントも文字列として読む。
 * - 色と不透明度の値は全て ui/theme（色の一式の LocalSkyPalette と、押せないときの DISABLED_GLASS_ALPHA）から読み、
 *   このファイルでは作らない（タスク 10.3 のソースの検査が ui/component を見る）。半透明の色は作り替えずにそのまま渡す。
 */

/** ガラスの縁の線の太さ。iOS の `lineWidth: 1` と同じ。トークンに無い値（設計書「トークンに無い値と外した値」）。 */
private val GLASS_BORDER_WIDTH = 1.dp

/**
 * ガラスの縁の色の並び（[GlassStyle.border]）を、縁を描く筆にする。色の数による描き方の分け方を、ここ 1 か所にまとめる。
 *
 * - 空：筆を返さない（null）。縁を描かない。入力欄は縁を付けず、Material 3 の枠を使う（要件 3.5）
 * - 1 色：その色の単色（SolidColor）。カードの白 30% の縁
 * - 2 色以上：左上→右下のグラデーション（Brush.linearGradient の既定の始まりと終わり）。iOS の
 *   `LinearGradient(startPoint: .topLeading, endPoint: .bottomTrailing)` と同じ向き。ボタンと投稿のカードの縁
 *
 * Brush.linearGradient は、色が 2 つ未満だと、作るときでなく描くときに例外を投げる（設計書の「ガラスの部品」の節）。
 * 1 色や空の並びをそのまま渡すと、その部品を初めて描いたときに落ちるので、色の数で分ける。
 * 描画から切り離した純関数で、GlassBorderBrushTest が色の一式の実際の縁で確かめる。
 *
 * @param border 縁の色の並び（色の一式のガラスの部品の border）
 * @return 縁を描く筆。縁を描かないときは null
 */
internal fun glassBorderBrush(border: List<Color>): Brush? = when (border.size) {
    0 -> null
    1 -> SolidColor(border.single())
    else -> Brush.linearGradient(border)
}

/**
 * ガラスの面を付ける。角の切り抜き → 面の色 → 縁の順に、修飾子だけで描く。カードなど、中身を包む面に使う。
 *
 * - 角の切り抜き：[GlassStyle.cornerRadius] の角丸で切り抜く。中身も角丸の外にはみ出さない
 * - 面：[GlassStyle.fill]（白に不透明度を付けた色）で塗る。下の空の色に重なった色が、実際の面の色になる
 * - 縁：[glassBorderBrush] が筆を返したときだけ、同じ角丸で [GLASS_BORDER_WIDTH] の線を描く（空の縁なら描かない）
 *
 * 意味の節を足さない（semantics を付けず、Surface で包まない）。ぼかしと影も付けない。
 * 大きさは決めず、付けた先の大きさ（中身の大きさ）のまま描くので、文字が増えれば面も伸びる。
 *
 * @param style 色の一式のガラスの部品の見た目（例：`LocalSkyPalette.current.glass.card`）
 */
fun Modifier.glassSurface(style: GlassStyle): Modifier {
    val shape = RoundedCornerShape(style.cornerRadius)
    // 切り抜いた後に塗るので、面の色は角丸の内側だけに付く
    val filled = this.clip(shape).background(style.fill)
    val brush = glassBorderBrush(style.border)
    return if (brush == null) filled else filled.border(width = GLASS_BORDER_WIDTH, brush = brush, shape = shape)
}

/**
 * ボタンの見た目の種類。同じ操作のボタンを、置く画面に合わせて出し分けるために使う
 * （タスク 10.2 で、状態の表示〔エラーとオフライン〕の再試行のボタンが受け取る）。
 *
 * - [MATERIAL]：今の Material 3 の塗りのボタン（Button の既定の色と形）。背景だけの画面と無地の画面で使う（要件 2.2）
 * - [GLASS]：ガラスのボタン（[GlassButton]）。ガラスの 5 画面で使う（要件 2.1）
 */
enum class ButtonLook { MATERIAL, GLASS }

/**
 * ガラスのボタン。iOS の `GlassButtonStyle`（SkyBackgroundView.swift）を、ぼかしと影を除いて写す。
 * 面は色の一式のガラスのボタンの面（ライトは白 25%・ダークは白 8%）、縁は白 60%→10% の左上→右下のグラデーション、
 * 角丸は 14dp（`Radius.button`）、文字と中のアイコンは本文の色（`glass.buttonContent`）で描く。
 *
 * 作り方の決めたこと（理由をここに残す）:
 * - 今の Material 3 の Button をそのまま包む。役割（ボタン）と文言の読み上げは Button のままで変わらない（要件 6.3）。
 *   高さと中の余白も Button の既定のまま。最小の高さだけが決まっていて、文字の量で伸びる（要件 7.1・7.3）。
 * - 面は、Button の colors の面の色に、色の一式のガラスのボタンの面の色を、通常と押せないときの両方で渡す。
 *   文字と中のアイコンの色も、通常と押せないときの両方で `glass.buttonContent` を渡す。
 *   半透明の色を作り替えずにそのまま渡すので、このファイルでは色の値を作らない。
 * - tasks.md と設計書は「面の色を透明にし、ガラスの面を修飾子で描く」と書いているが、そうしない。
 *   material3 1.4.0 の Button の中の押せる Surface は、渡した修飾子の内側で、押せる範囲の最小の大きさ（48dp）を足す。
 *   そのため修飾子で描いた面は、ボタンの見た目の高さ（最小 40dp）より上下に大きくなり、角丸と押したときの波紋が面とずれる。
 *   material3 1.4.0 の aar の SurfaceKt では、押せる版（Surface$2・$3・$4）にだけ minimumInteractiveComponentSize があり、
 *   押せない版（Surface$1）には無いことを確かめてある。面を colors の面の色に渡せば、面・角丸・波紋が同じ大きさになる。
 * - 角丸は shape に、縁は border に渡す（縁の筆は [glassBorderBrush]）。Button が面と縁を同じ形で描く。
 * - 影を付けない（要件 3.8・5.5）。Button の既定の影（マウスを載せたときに出る 1dp）を、elevation に null を渡して消す。
 * - 押せないときは、色を変えずに全体を [DISABLED_GLASS_ALPHA]（0.6）の不透明度にする。押せないときの色にも通常と同じ色を
 *   渡し（Material 3 の既定の薄い灰色にしない）、修飾子の不透明度で、面・縁・文字をまとめて薄くする。
 *   描くときの不透明度なので、色の値は作らない。押せない部品の色は、コントラスト比の表の対象外（要件 3.9）。
 *
 * @param onClick 押したときの処理
 * @param modifier 置き場所の修飾子（高さを固定しない）
 * @param enabled 押せるか。false のときは全体を薄くする
 * @param content ボタンの中身（文言とアイコン）。文字の色は Button が配る（`glass.buttonContent`）
 */
@Composable
fun GlassButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    val glass = LocalSkyPalette.current.glass
    // ガラスのボタンの見た目（面・縁・角丸）。ライトとダークで面の濃さだけが変わる
    val style = glass.button
    // 縁の筆。ボタンの縁は 2 色なのでグラデーションになる（色の一式が変わって空になったら、縁を描かない）
    val borderBrush = glassBorderBrush(style.border)
    Button(
        onClick = onClick,
        // 押せないときだけ、全体を薄くする不透明度を、呼び出し側の修飾子の後ろに足す
        modifier = modifier.then(if (enabled) Modifier else Modifier.alpha(DISABLED_GLASS_ALPHA)),
        enabled = enabled,
        shape = RoundedCornerShape(style.cornerRadius),
        // 面と文字の色は、通常と押せないときで同じにする（押せないときの見分けは、上の不透明度だけで付ける）
        colors = ButtonDefaults.buttonColors(
            containerColor = style.fill,
            contentColor = glass.buttonContent,
            disabledContainerColor = style.fill,
            disabledContentColor = glass.buttonContent,
        ),
        // 影を付けない（既定はマウスを載せたときに 1dp の影が出る）
        elevation = null,
        border = borderBrush?.let { BorderStroke(GLASS_BORDER_WIDTH, it) },
        content = content,
    )
}

/**
 * ガラスの入力欄。iOS の `GlassInputField`（SkyBackgroundView.swift）を、ぼかしと白 30% の縁を除いて、
 * Material 3 の枠付きの入力欄（OutlinedTextField）の上に写す。面は色の一式のガラスの入力欄の面、角丸は 12dp（`Radius.md`）、
 * ラベルと中の文字は本文の色（`glass.inputContent`）で描く。
 *
 * 作り方の決めたこと（理由をここに残す）:
 * - 今の画面が使っている OutlinedTextField をそのまま包み、colors と shape だけを渡す（OutlinedTextField に縁の引数は無い）。
 *   役割（編集欄）とラベルの読み上げは OutlinedTextField のままで変わらない（要件 6.3）。高さも既定のままで、文字の量で伸びる（要件 7.1・7.3）。
 * - 面は、colors の入力欄の地の色の 3 つ（選択中・未選択・エラー）に、ガラスの入力欄の面の色を渡して塗る。
 * - ガラスの面の修飾子（[glassSurface]）は使わない。material3 1.4.0 の OutlinedTextField は、ラベルがあるとき、ラベルの上の余白を
 *   渡した修飾子の後ろ（内側）に足す。補足の文字も、枠と面と同じ配置の中で枠の下に置く。修飾子で面を描くと、面が補足の文字の下まで
 *   広がり、上端も枠より上にずれる（どちらも 1.4.0 の aar の OutlinedTextFieldKt と OutlinedTextFieldMeasurePolicy で確かめてある）。
 * - ラベル（3 つの状態）と中の文字（3 つの状態）は `glass.inputContent` で描く。雲とガラスを重ねた所に、アクセントとエラーの文字を
 *   載せないためである（ダークでは 3.89 と 4.14 で 4.5 を割る。要件 3.2・3.4）。エラーは、枠の色と補足の文字で示す。
 * - 枠（未選択は outline・選択中は primary・エラーは error）とカーソルは、Material 3 の既定の役のまま描く。iOS の白 30% の縁は付けない。
 *   SkyContrastTest は、`glass.inputContent` とこの 3 つの役を、雲とガラスの重なりの上で確かめている。
 * - 押せないとき（[enabled] が false）の色は、OutlinedTextField の既定のまま（タスク 9.2 が定めた 3 つの状態の外）。
 * - 1 行にするかどうか（[singleLine]）は、既定値の無い引数で受け取り、そのまま渡す。呼び出し側が今の画面と同じ値を必ず書くようにするためで、
 *   1 行にしたときの行の数の上限は、OutlinedTextField の既定（1 行のときは 1 行）に任せる。
 *
 * @param value 入力欄の文字
 * @param onValueChange 文字が変わったときの処理
 * @param label ラベル（`glass.inputContent` で描かれる）
 * @param singleLine 1 行にするか。既定値は無い
 * @param modifier 置き場所の修飾子（高さを固定しない）
 * @param enabled 入力できるか
 * @param isError エラーか。true のとき、枠の色が error の役になる（ラベルと文字の色は変わらない）
 * @param supportingText 補足の文字（枠の下に置かれる）。無ければ null
 * @param visualTransformation 見せ方の変換（パスワードを伏せるなど）
 * @param keyboardOptions キーボードの種類と、確定のボタンの働き
 * @param keyboardActions 確定のボタンを押したときの処理
 */
@Composable
fun GlassTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: @Composable () -> Unit,
    singleLine: Boolean,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    isError: Boolean = false,
    supportingText: (@Composable () -> Unit)? = null,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
) {
    val glass = LocalSkyPalette.current.glass
    // ガラスの入力欄の見た目（面と角丸。縁の色の並びは空で、Material 3 の枠だけを使う）
    val style = glass.input
    // ラベルと中の文字の色（本文の色）。選択中・未選択・エラーのどれでも同じ色にする
    val content = glass.inputContent
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        enabled = enabled,
        label = label,
        supportingText = supportingText,
        isError = isError,
        visualTransformation = visualTransformation,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        singleLine = singleLine,
        shape = RoundedCornerShape(style.cornerRadius),
        // 渡すのは面・ラベル・文字の色だけ。枠・カーソル・補足の文字・押せないときの色は、Material 3 の既定の役のまま
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = content,
            unfocusedTextColor = content,
            errorTextColor = content,
            focusedContainerColor = style.fill,
            unfocusedContainerColor = style.fill,
            errorContainerColor = style.fill,
            focusedLabelColor = content,
            unfocusedLabelColor = content,
            errorLabelColor = content,
        ),
    )
}

/**
 * ログインと新規登録の送信のボタン。iOS の LoginView.swift のログインのボタン（`accentGradient` を左上→右下に敷いた角丸の面）を、
 * 影を除いて写す。面は色の一式のログインのボタンのグラデーション、角丸は 14dp（`Radius.button`）、文字と中のアイコンは
 * グラデーションの上の文字の色（`onAccentGradient`・白）で描く。
 *
 * 作り方の決めたこと（理由をここに残す）:
 * - 今の Material 3 の Button をそのまま包む。役割（ボタン）と文言の読み上げは Button のままで変わらない（要件 6.3）。
 * - Button の面の色は、通常と押せないときの両方で透明にし、グラデーションは渡した修飾子の側で、角丸 14dp で敷く
 *   （グラデーションは 1 つの色にできないので、Button の面の色には渡せない）。
 * - 修飾子のいちばん初めに、高さの最小として、押せる範囲の最小の大きさ（LocalMinimumInteractiveComponentSize・既定は 48dp）を足す。
 *   material3 1.4.0 の Button の中の押せる Surface は、渡した修飾子の内側で、押せる範囲を最小の大きさまで広げる
 *   （[GlassButton] の決めたことと同じ）。最小を足さないと、修飾子で敷いたグラデーションだけが 48dp になり、
 *   ボタンの見た目の高さ（最小 40dp）より上下に大きくなって、角丸と押したときの波紋が面とずれる。
 *   最小を外側で足すと、その下限が中の Surface まで届く（広げる部品は、入ってきた下限をそのまま中に渡す）ので、
 *   面・グラデーション・波紋が同じ大きさになる。見た目の高さは 48dp になり、iOS のログインのボタン（上下 16 の余白と文字で約 54pt）に近づく。
 *   最小だけで上限は決めないので、文字の量で伸びる（要件 7.1・7.3）。2026-10-18 ユーザー判断。
 * - 影を付けない（[GlassButton] と同じく、elevation に null を渡す）。iOS の光る影は写さない。
 * - 文字の色は、通常と押せないときの両方で `onAccentGradient` にする。中の LocalContentColor もこの色になるので、
 *   中に置く読み込み中の輪は、呼び出し側が LocalContentColor の色を渡せば白で描ける（輪の既定は主色）。
 * - 全体を [DISABLED_GLASS_ALPHA]（0.6）の不透明度にするのは、押せないうえに [dimWhenDisabled] が true のときだけにする。
 *   ログインと新規登録は、送信中も押せなくなるので、入力が足りずに押せないときだけ薄くし、送信中は薄くしない（iOS と同じ）。
 *   薄くする修飾子は、グラデーションを敷く修飾子より前（外側）に置く。描くときの不透明度は、それより後ろ（内側）に描くもの全体に効くので、
 *   グラデーションと文字がまとめて薄くなる。押せない部品の色は、コントラスト比の表の対象外（要件 3.9）。
 *
 * @param onClick 押したときの処理
 * @param enabled 押せるか（既定値は無い。呼び出し側が、送れる状態かを必ず渡す）
 * @param modifier 置き場所の修飾子（高さを固定しない）
 * @param dimWhenDisabled 押せないときに全体を薄くするか。送信中のように、押せないが薄くしないときは false を渡す
 * @param content ボタンの中身（文言とアイコン・読み込み中の輪）。文字の色は Button が配る（`onAccentGradient`）
 */
@Composable
fun AccentGradientButton(
    onClick: () -> Unit,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    dimWhenDisabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    val palette = LocalSkyPalette.current
    // 角丸。面（グラデーション）と、Button の形（波紋の切り抜き）に同じものを渡す
    val shape = RoundedCornerShape(DesignTokens.Radius.button)
    // ログインのボタンのグラデーション（2 色）。既定の始まりと終わりで、左上→右下（iOS の topLeading → bottomTrailing）
    val gradient = Brush.linearGradient(palette.accentGradient)
    // 薄くするのは、押せないうえに薄くする指定があるときだけ
    val dimmed = !enabled && dimWhenDisabled
    Button(
        onClick = onClick,
        modifier = modifier
            // 押せる範囲の最小の大きさまで、面も広げる（上の「決めたこと」の 3 つ目）
            .heightIn(min = LocalMinimumInteractiveComponentSize.current)
            // 薄くする不透明度は、グラデーションより外側に置く（グラデーションと文字をまとめて薄くする）
            .then(if (dimmed) Modifier.alpha(DISABLED_GLASS_ALPHA) else Modifier)
            .background(brush = gradient, shape = shape),
        enabled = enabled,
        shape = shape,
        // 面は通常と押せないときの両方で透明（グラデーションは上の修飾子が敷く）。文字は両方でグラデーションの上の文字の色
        colors = ButtonDefaults.buttonColors(
            containerColor = Color.Transparent,
            contentColor = palette.onAccentGradient,
            disabledContainerColor = Color.Transparent,
            disabledContentColor = palette.onAccentGradient,
        ),
        // 影を付けない（既定はマウスを載せたときに 1dp の影が出る）
        elevation = null,
        content = content,
    )
}
