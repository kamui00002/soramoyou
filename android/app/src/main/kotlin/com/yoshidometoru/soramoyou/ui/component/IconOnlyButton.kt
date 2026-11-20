// ⭐️ アイコンだけのボタン。TalkBack の説明を必ず受け取る（タスク 5.2・要件 16.5）
package com.yoshidometoru.soramoyou.ui.component

import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * 文字を持たず、アイコンだけで操作を表すボタン（閉じる・戻る・その他のメニューなど）。
 *
 * [contentDescription] は TalkBack が読み上げる説明で、null を許さない引数にしてある。説明を付け忘れた呼び出しは
 * コンパイルが通らない（要件 16.5）。説明は「何が起こるか」を日本語で書く（例:「閉じる」）。文言は strings.xml に置き、
 * stringResource で読んで渡す。
 *
 * ボタンの大きさは Material 3 の IconButton のまま（押せる範囲は最小 48dp を確保する）。アイコンは文字ではないので、
 * 端末の文字サイズでは大きくならず、文字サイズを大きくしても画面からはみ出さない（要件 16.6）。
 *
 * @param imageVector 表示するアイコン
 * @param contentDescription TalkBack が読み上げる説明
 * @param onClick 押したときの処理
 * @param modifier 配置の調整（高さを固定しない）
 * @param enabled 押せるか
 * @param tint アイコンの色（既定は今の文字色。押せないときの薄い色も IconButton がこの既定に入れる）
 */
@Composable
fun IconOnlyButton(
    imageVector: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    tint: Color = LocalContentColor.current,
) {
    // IconButton はボタンの役割を持ち、中のアイコンの説明をまとめて読み上げる（「閉じる、ボタン」のように）
    IconButton(onClick = onClick, modifier = modifier, enabled = enabled) {
        Icon(imageVector = imageVector, contentDescription = contentDescription, tint = tint)
    }
}
