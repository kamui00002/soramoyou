// ⭐️ いいねのボタンといいね数（タスク 18.4・要件 9.1・9.7・16.5）（android-ui-ios-parity タスク 10.1・要件 3.5・6.2）
package com.yoshidometoru.soramoyou.ui.component

import androidx.compose.foundation.layout.Row
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.ui.theme.LocalSkyPalette

/**
 * いいねのボタン（ハート）と、その横のいいね数。
 *
 * - ボタンの TalkBack の説明は、押すと何が起こるか（いいね済みでなければ「いいねする」、いいね済みなら「いいねを取り消す」）。
 *   説明は [IconOnlyButton] が必ず受け取るので、付け忘れるとコンパイルが通らない（要件 16.5）
 * - いいね数はボタンの外の文字に置き、TalkBack はそのまま「いいね 3」と読む
 * - [enabled] が false のとき（いいねの書き込みが無効なビルド）は押せない。表示は出す
 *
 * 見た目と押した手触りはエミュレータで確認済み（タスク 19.1）。TalkBack の音声での読み上げは未確認（説明文が付くことは確認済み）。
 *
 * @param isLiked いいね済みか（塗りつぶしのハートで出す）。
 * @param count 出すいいね数（0 未満にしない値。LikeStateStore の displayedLikeCount で出したもの）。
 */
@Composable
fun LikeButton(
    isLiked: Boolean,
    count: Long,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically) {
        IconOnlyButton(
            imageVector = if (isLiked) HeartFilled else HeartOutlined,
            contentDescription = stringResource(if (isLiked) R.string.like_action_unlike else R.string.like_action_like),
            onClick = onClick,
            enabled = enabled,
            tint = likeTint(isLiked, enabled, LocalContentColor.current, LocalSkyPalette.current.liked),
        )
        Text(text = stringResource(R.string.feed_likes_count, count), style = MaterialTheme.typography.bodyMedium)
    }
}

/**
 * ハートの色。いいね済みで押せるときだけ [liked]（いいね済みの色）にし、それ以外は [default]（今の文字色）にする。
 * 押せないときに既定の色へ戻すのは、IconButton が押せない状態の薄い色を今の文字色に入れるため（ピンクのままだと押せそうに見える）。
 *
 * いいね済みの色は、この部品の中に色の値として持たず、呼び出し側が色の一式（SkyPalette の liked）から読んで渡す。
 * 色の一式はライトとダークで別の色を持ち（ライトは昼の空の上でも 3.0 を保つ濃さ、ダークは iOS の softPink そのもの）、
 * 値と選んだ理由は ui/theme の SkyPalette.kt に置く（要件 3.5）。
 *
 * @param default いいね済みの色にしないときの色（今の文字色）。
 * @param liked いいね済みの色（色の一式の liked）。
 */
internal fun likeTint(isLiked: Boolean, enabled: Boolean, default: Color, liked: Color): Color =
    if (isLiked && enabled) liked else default

/**
 * ハートのアイコン 2 つ。Material Icons の Favorite・FavoriteBorder と同じ形（24×24 の座標）。
 * アイコンの部品（material-icons-core）は material3 1.4.0 の依存に含まれないので、依存を足さずに形だけを書く。
 * 色は [androidx.compose.material3.Icon] が今の文字色で塗り替える。
 */
private val HeartFilled: ImageVector = heart(
    "Favorite",
    "M12,21.35l-1.45,-1.32C5.4,15.36 2,12.28 2,8.5 2,5.42 4.42,3 7.5,3c1.74,0 3.41,0.81 4.5,2.09" +
        "C13.09,3.81 14.76,3 16.5,3 19.58,3 22,5.42 22,8.5c0,3.78 -3.4,6.86 -8.55,11.54L12,21.35z",
)

private val HeartOutlined: ImageVector = heart(
    "FavoriteBorder",
    "M16.5,3c-1.74,0 -3.41,0.81 -4.5,2.09C10.91,3.81 9.24,3 7.5,3 4.42,3 2,5.42 2,8.5c0,3.78 3.4,6.86 8.55,11.54" +
        "L12,21.35l1.45,-1.32C18.6,15.36 22,12.28 22,8.5 22,5.42 19.58,3 16.5,3zM12.1,18.55l-0.1,0.1 -0.1,-0.1" +
        "C7.14,14.24 4,11.39 4,8.5 4,6.5 5.5,5 7.5,5c1.54,0 3.04,0.99 3.57,2.36h1.87C13.46,5.99 14.96,5 16.5,5" +
        "c2,0 3.5,1.5 3.5,3.5 0,2.89 -3.14,5.74 -7.9,10.05z",
)

private fun heart(name: String, pathData: String): ImageVector =
    ImageVector.Builder(name = name, defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)
        .addPath(pathData = addPathNodes(pathData), fill = SolidColor(Color.Black))
        .build()
