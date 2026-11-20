// ⭐️ ライトとダークの色の一式（空・文字・ガラス・雲・写真の札・ログインのボタン）（タスク 4.2・要件 1.1・1.2・2.3・2.5・3.5〜3.7・5.6・5.7）
package com.yoshidometoru.soramoyou.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * 端末がライトかダークかで変わる色を 1 組にまとめたもの。[skyPaletteOf] が作り、[LocalSkyPalette] で画面の中へ配る。
 *
 * - 空の上に全画面で載る文字の色（[text]・[textSecondary]・[accent]・[error]・[outline] など）は、
 *   SoramoyouTheme が Material 3 の役（onBackground・primary など）へ付け替える（タスク 4.4）。
 * - ガラス・雲・写真の札・ログインのボタンの色は Material 3 の役に無いので、部品がここから直接読む。
 * - iOS の値をそのまま使う色は [DesignTokens.Colors] から読む。要件 3 のコントラスト比のために濃さを変えた色だけを
 *   16 進数でここに持つ（色相は iOS の元の色から 10° 以内。IosDesignTokensTest が確かめる）。
 */
@Immutable
data class SkyPalette(
    /** 端末がダークテーマのときの一式か。 */
    val isDark: Boolean,
    /** 空のグラデーション。上→中→下の 3 色。 */
    val skyGradient: List<Color>,
    /** 本文の色（onBackground・onSurface）。 */
    val text: Color,
    /** 補助の文字の色（onSurfaceVariant）。日時・文字数・案内に使う。 */
    val textSecondary: Color,
    /** 文字だけのボタン・ハッシュタグ・選んだ印の色（primary）。 */
    val accent: Color,
    /** 塗りのボタンの文字の色（onPrimary）。 */
    val onAccent: Color,
    /** エラーの文字と枠の色（error）。 */
    val error: Color,
    /** エラーの色で塗った面の上の文字の色（onError）。 */
    val onError: Color,
    /** いいね済みのハートの色。アイコンなので、基準は 3.0（要件 3.5）。 */
    val liked: Color,
    /** 入力欄と枠のボタンの枠の色（outline）。基準は 3.0（要件 3.5）。 */
    val outline: Color,
    /** ガラスの部品の面・縁・文字の色。 */
    val glass: GlassPalette,
    /** ログインと新規登録の背景に重ねる装飾の雲。iOS の並び（上・上・中央・下）の 4 つ（要件 2.3）。 */
    val clouds: List<CloudSpec>,
    /** 写真の上の「n枚」の札の色（要件 3.7）。 */
    val photoBadge: PhotoBadgeColors,
    /** ログインと新規登録の送信のボタンのグラデーション。左上→右下の 2 色（要件 2.5）。 */
    val accentGradient: List<Color>,
    /** ログインと新規登録の送信のボタンの文字の色。 */
    val onAccentGradient: Color,
)

/** ガラスの部品ごとの見た目と、ガラスの上に載る文字の色。 */
@Immutable
data class GlassPalette(
    /** 投稿のカード（フィード）。 */
    val postCard: GlassStyle,
    /** カード（詳細とプロフィールの見出しなど）。 */
    val card: GlassStyle,
    /** 入力欄（ログインと新規登録）。 */
    val input: GlassStyle,
    /** ガラスのボタン。 */
    val button: GlassStyle,
    /**
     * 入力欄のラベル（選択中・未選択・エラーの 3 つの状態）と中の文字の色。本文の色と等しい。
     * 雲とガラスの重なりに文字として載る唯一の色で、アクセントとエラーはそこでは枠とカーソルにだけ使う（ダークで 4.5 を割るため）。
     */
    val inputContent: Color,
    /** ガラスのボタンの文字と中のアイコンの色。iOS の GlassButtonStyle と同じく本文の色と等しい。 */
    val buttonContent: Color,
)

/**
 * ガラスの部品 1 つの見た目。
 * [fill] は白に不透明度を付けた色で、背景に重ねた色（compositeOver）が実際の面の色になる。
 * [border] は縁の線の色で、2 色なら左上→右下のグラデーション、1 色なら単色、空なら縁を描かない。
 */
@Immutable
data class GlassStyle(val fill: Color, val border: List<Color>, val cornerRadius: Dp)

/**
 * 装飾の雲 1 つ。iOS の `SkyBackgroundView` の `cloudsLayer` を、雲を揺らす `cloudOffset` を 0 とした静止の形で写す（要件 2.4）。
 *
 * - [width]・[height] は雲の大きさ。
 * - [offsetX] は iOS の `offset` の横。[anchor] が [CloudAnchor.START] なら窓の左端から、[CloudAnchor.END] なら窓の右端から測る
 *   （iOS の `geometry.size.width - 80` は、END と −80 になる）。
 * - [topFraction] は iOS の `offset` の縦を、窓の高さに対する割合で表したもの。
 * - [alpha] は白の不透明度。
 *
 * 窓の中の実際の矩形は、DecorativeClouds の `cloudRects`（タスク 8.1）がこの値から求める。
 */
@Immutable
data class CloudSpec(
    val width: Dp,
    val height: Dp,
    val anchor: CloudAnchor,
    val offsetX: Dp,
    val topFraction: Float,
    val alpha: Float,
)

/** 雲の横の位置を、窓のどちらの端から測るか。 */
enum class CloudAnchor { START, END }

/** 写真の上の札の、面（[scrim]）と文字（[text]）の色。 */
@Immutable
data class PhotoBadgeColors(val scrim: Color, val text: Color)

/*
 * 値は設計書の「配色の値」の表のとおり。
 * 下の private な値は、上から順に初期化される（後の一式が前の値を読む）ので、並びを入れ替えない。
 */

/** 白に不透明度 [alpha] を付けた色（ガラスの面と縁・雲）。 */
private fun white(alpha: Float): Color = Color.White.copy(alpha = alpha)

// --- 濃さを変えた色（要件 3 のため。色相は iOS の元の色から 10° 以内：要件 5.6） ---

/** ライトのアクセント（#102B54）。iOS の `skyBlue`（216°）と同じ色相で、昼の空のいちばん下でも 4.5 を保つ濃さにした。 */
private val LightAccent = Color(0xFF102B54)

/** ライトのエラー（#580A0A）。iOS の `error`（0°）と同じ色相で濃くした。 */
private val LightError = Color(0xFF580A0A)

/** ライトのいいね済み（#7F192C）。iOS の `softPink`（349°）と同じ色相で、昼の空のいちばん下でも 3.0 を保つ濃さにした。 */
private val LightLiked = Color(0xFF7F192C)

/** ダークのアクセント（#9EC0F2）。iOS の `skyBlue` と同じ色相で、雲とガラスを重ねた夜の空の上でも 4.5 を保つ明るさにした。 */
private val DarkAccent = Color(0xFF9EC0F2)

/** ダークのエラー（#F5B3B3）。iOS の `error` と同じ色相で明るくした。 */
private val DarkError = Color(0xFFF5B3B3)

/**
 * ログインと新規登録の送信のボタンのグラデーション（#2F5FA8→#5F3FA0）。iOS の `accentGradient`（#80B3F2→#9973E6）の両端と
 * 同じ色相で、白い文字が両端で 4.5 以上（6.32・7.76）になる濃さにした（設計書の P11）。ライトとダークで同じ。
 */
private val AccentGradient = listOf(Color(0xFF2F5FA8), Color(0xFF5F3FA0))

// --- ダークの補助の文字と枠（iOS の半透明の白を、夜の空のいちばん上の色に重ねて不透明にする） ---

/**
 * 夜の空のいちばん上の色。Material 3 の役は不透明の色で持つので、iOS の `textSecondary`（白 85%）と `textTertiary`（白 70%）を
 * この色に重ねて不透明の色にする（約 #DEE0E6・約 #BEC2CD。16 進数を書き写さず、ここで計算する）。
 */
private val NightSkyTop = DesignTokens.Colors.nightSkyGradient.first()

/** ダークの補助の文字の色（白 85% を夜の空のいちばん上に重ねた色）。 */
private val DarkTextSecondary =
    DesignTokens.Colors.textPrimary.copy(alpha = DesignTokens.Colors.textSecondaryAlpha).compositeOver(NightSkyTop)

/** ダークの枠の色（白 70% を夜の空のいちばん上に重ねた色）。 */
private val DarkOutline =
    DesignTokens.Colors.textPrimary.copy(alpha = DesignTokens.Colors.textTertiaryAlpha).compositeOver(NightSkyTop)

// --- ガラス（要件 2.1・5.2） ---

/** 投稿のカードの縁（白 50%→20%）。iOS の GlassPostCardStyle の直書きで、トークンに無い（設計書「トークンに無い値と外した値」）。 */
private val PostCardBorder = listOf(white(0.5f), white(0.2f))

/**
 * ガラスの部品の一式。縁と角丸はライトとダークで同じで、面の濃さと文字の色だけが変わる。
 * - 縁：投稿のカードは [PostCardBorder]、カードは白 30%、ボタンは白 60%→10%。入力欄は縁を付けず、Material 3 の枠を使う（要件 3.5）。
 * - 角丸：カードと投稿のカードは `Radius.xl`（20dp）、ボタンは `Radius.button`（14dp）、入力欄は `Radius.md`（12dp）。
 *
 * @param postCardAndButtonFill 投稿のカードとボタンの面。
 * @param cardAndInputFill カードと入力欄の面。
 * @param content 入力欄とボタンの文字の色（本文の色）。
 */
private fun glassPalette(postCardAndButtonFill: Color, cardAndInputFill: Color, content: Color): GlassPalette {
    val colors = DesignTokens.Colors
    val (accentBorderStart, accentBorderEnd) = colors.glassBorderAccentAlphas
    return GlassPalette(
        postCard = GlassStyle(postCardAndButtonFill, PostCardBorder, DesignTokens.Radius.xl),
        card = GlassStyle(cardAndInputFill, listOf(white(colors.glassBorderSecondaryAlpha)), DesignTokens.Radius.xl),
        input = GlassStyle(cardAndInputFill, emptyList(), DesignTokens.Radius.md),
        button = GlassStyle(
            postCardAndButtonFill,
            listOf(white(accentBorderStart), white(accentBorderEnd)),
            DesignTokens.Radius.button,
        ),
        inputContent = content,
        buttonContent = content,
    )
}

/**
 * 押せないガラスのボタン（と、タスク 9.3 のログインのグラデーションのボタン）を、色を変えずに全体ごと薄くする不透明度。
 * iOS のログインのボタンが入力の不足で薄くなる値（`LoginView.swift` の opacity の 0.6）と同じで、トークンに無い
 * （設計書「トークンに無い値と外した値」）。
 *
 * 色と不透明度の値は ui/theme が持ち、部品（ui/component）はこの値を読んで、描くときの不透明度として使うだけにする。
 * 部品の側で色の値を作らないという線引きで、タスク 10.3 のソースの検査（ScreenStyleSourceTest）と矛盾させないためである。
 * 押せない部品の色は、コントラスト比の表（SkyContrastTest）の対象外（要件 3.9）。
 */
const val DISABLED_GLASS_ALPHA: Float = 0.6f

// --- 雲（要件 2.3・2.4） ---

/**
 * ライトの雲。iOS の `SkyBackgroundView.swift` の `cloudsLayer` を、`cloudOffset` を 0 とした静止の形で写す。
 * 大きさ・位置・濃さとも iOS と同じ値で、濃さは IosDesignTokensTest が iOS のソースと突き合わせる。
 */
private val LightClouds = listOf(
    // 上部の雲（iOS: 180×70・x = −40・y = 高さ×0.08・白 50%）
    CloudSpec(width = 180.dp, height = 70.dp, anchor = CloudAnchor.START, offsetX = (-40).dp, topFraction = 0.08f, alpha = 0.5f),
    // 上部の雲（iOS: 140×55・x = 幅 − 80・y = 高さ×0.12・白 35%）
    CloudSpec(width = 140.dp, height = 55.dp, anchor = CloudAnchor.END, offsetX = (-80).dp, topFraction = 0.12f, alpha = 0.35f),
    // 中央の雲（iOS: 160×65・x = 10・y = 高さ×0.32・白 40%）
    CloudSpec(width = 160.dp, height = 65.dp, anchor = CloudAnchor.START, offsetX = 10.dp, topFraction = 0.32f, alpha = 0.4f),
    // 下部の雲（iOS: 200×80・x = 幅 − 130・y = 高さ×0.55・白 25%）
    CloudSpec(width = 200.dp, height = 80.dp, anchor = CloudAnchor.END, offsetX = (-130).dp, topFraction = 0.55f, alpha = 0.25f),
)

/**
 * ダークの雲の濃さの、iOS の値に対する倍率。ダークでは雲の上にアクセントとエラーの文字が載るので、
 * 0.2 倍（白 10・7・8・5%）に薄めて 4.5 を保つ（設計書の P3）。
 */
private const val DARK_CLOUD_ALPHA_SCALE = 0.2f

/** ダークの雲。大きさと位置はライトと同じで、濃さだけを [DARK_CLOUD_ALPHA_SCALE] 倍にする。 */
private val DarkClouds = LightClouds.map { it.copy(alpha = it.alpha * DARK_CLOUD_ALPHA_SCALE) }

// --- 写真の札（要件 3.7） ---

/** 写真の上の札の面の黒の不透明度。iOS の 50% では白い写真の上で 3.98 になるので、60%（5.74）にした（設計書の P10）。 */
private const val PHOTO_BADGE_SCRIM_ALPHA = 0.6f

/** 写真の上の札。黒 60% の面に白い文字。ライトとダークで同じ。 */
private val PhotoBadge = PhotoBadgeColors(
    scrim = Color.Black.copy(alpha = PHOTO_BADGE_SCRIM_ALPHA),
    text = DesignTokens.Colors.textPrimary,
)

// --- 一式 ---

/** ライト（昼の空）の一式。本文・補助・枠は全て `textDark`（昼の空のいちばん下の上で 4.5 を満たす幅が狭いため）。 */
private val LightPalette = SkyPalette(
    isDark = false,
    skyGradient = DesignTokens.Colors.daySkyGradient,
    text = DesignTokens.Colors.textDark,
    textSecondary = DesignTokens.Colors.textDark,
    accent = LightAccent,
    onAccent = DesignTokens.Colors.textPrimary,
    error = LightError,
    onError = DesignTokens.Colors.textPrimary,
    liked = LightLiked,
    outline = DesignTokens.Colors.textDark,
    // 投稿のカードとボタンは白 25%（glassPrimary）、カードと入力欄は白 15%（glassSecondary）
    glass = glassPalette(
        postCardAndButtonFill = white(DesignTokens.Colors.glassPrimaryAlpha),
        cardAndInputFill = white(DesignTokens.Colors.glassSecondaryAlpha),
        content = DesignTokens.Colors.textDark,
    ),
    clouds = LightClouds,
    photoBadge = PhotoBadge,
    accentGradient = AccentGradient,
    onAccentGradient = DesignTokens.Colors.textPrimary,
)

/** ダーク（夜の空）の一式。本文は白、塗りの面の上の文字は `textDark`。いいね済みは iOS の `softPink` そのもの。 */
private val DarkPalette = SkyPalette(
    isDark = true,
    skyGradient = DesignTokens.Colors.nightSkyGradient,
    text = DesignTokens.Colors.textPrimary,
    textSecondary = DarkTextSecondary,
    accent = DarkAccent,
    onAccent = DesignTokens.Colors.textDark,
    error = DarkError,
    onError = DesignTokens.Colors.textDark,
    liked = DesignTokens.Colors.softPink,
    outline = DarkOutline,
    // 全ての部品を白 8%（glassTertiary）。白 15% を重ねるとアクセントの文字が 4.17 に下がる（設計書の P2）
    glass = glassPalette(
        postCardAndButtonFill = white(DesignTokens.Colors.glassTertiaryAlpha),
        cardAndInputFill = white(DesignTokens.Colors.glassTertiaryAlpha),
        content = DesignTokens.Colors.textPrimary,
    ),
    clouds = DarkClouds,
    photoBadge = PhotoBadge,
    accentGradient = AccentGradient,
    onAccentGradient = DesignTokens.Colors.textPrimary,
)

/**
 * 端末がダークテーマかどうか（[darkTheme]）だけから色の一式を返す。描画から切り離した純関数で、画面とテストが同じこの関数を読む。
 */
fun skyPaletteOf(darkTheme: Boolean): SkyPalette = if (darkTheme) DarkPalette else LightPalette

/**
 * 画面の中へ色の一式を配る入れ物。SoramoyouTheme が、端末の設定に合った一式を入れる（タスク 4.4）。
 * 入れずに読んだとき（プレビューなど）は、Material 3 の配色の既定がライトであるのに合わせて、ライトの一式を返す。
 * 値が変わるのは端末のダークテーマの設定を切り替えたときだけなので、MaterialTheme の配色と同じく static の入れ物にする。
 */
val LocalSkyPalette: ProvidableCompositionLocal<SkyPalette> = staticCompositionLocalOf { skyPaletteOf(darkTheme = false) }
