// ⭐️ 通報・ブロックの「…」のメニューとダイアログと送信中の案内（タスク 29.2・要件 11.1〜11.4・11.6・16.2・16.5・16.6）（android-ui-ios-parity タスク 12.3・要件 5.1）
package com.yoshidometoru.soramoyou.feature.moderation

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.model.ReportReason
import com.yoshidometoru.soramoyou.feature.feed.feedErrorMessageRes
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens

/*
 * フィードの投稿と投稿詳細に出す、通報・ブロックの入口とダイアログ。どちらの画面も同じものを使う（文言と振る舞いを揃える）。
 * 出すかどうか・押せるかどうかは、PostModeration（moderationActionsFor）と接続の有無で画面の外が決めて渡す。
 *
 * ⚠️ この部品そのもの（Compose の描画・メニューの開き方・TalkBack の読み上げ・文字サイズ 200%）は、実機・エミュレータで未検証（33.x）。
 */

/**
 * 「…」のボタンと、押すと開く通報・ブロックのメニュー（iOS の ellipsis.circle の Menu：HomeView.swift:1096-1150）。
 * [actions] が空なら何も出さない（自分の投稿など：要件 11.7）。
 *
 * アイコンの部品は依存に無い（設定への入口と同じ理由）ので、「…」を文字で出し、TalkBack には「その他の操作」と読ませる
 * （「…」そのものは読ませない。要件 16.5）。オフラインの間と送信中は、メニューの項目を押せなくし、オフラインならその旨を出す。
 * 送信中であることは、画面が [ModerationSendingNotice] で出す（メニューは閉じているので、ここには出さない）。
 *
 * @param actions 出す操作（通報 → ブロックの順）。
 * @param isOnline 接続の有無。
 * @param sending 通報かブロックを送っているところか。
 * @param onReport 「この投稿を通報」を押した（理由の選択を出す）。
 * @param onBlock 「このユーザーをブロック」を押した（確認を出す）。
 */
@Composable
fun ModerationMenuButton(
    actions: Set<ModerationAction>,
    isOnline: Boolean,
    sending: Boolean,
    onReport: () -> Unit,
    onBlock: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (actions.isEmpty()) return
    var expanded by remember { mutableStateOf(false) }
    val description = stringResource(R.string.action_more_description)
    val enabled = isOnline && !sending
    // iOS の 2 つの項目は role: .destructive（赤）。押せないときの薄い色は MenuDefaults が入れる
    val itemColors = MenuDefaults.itemColors(textColor = MaterialTheme.colorScheme.error)
    Box(modifier = modifier) {
        TextButton(onClick = { expanded = true }, modifier = Modifier.semantics { contentDescription = description }) {
            Text(stringResource(R.string.action_more), modifier = Modifier.clearAndSetSemantics {})
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            if (ModerationAction.REPORT in actions) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.action_report_post)) },
                    onClick = {
                        expanded = false
                        onReport()
                    },
                    enabled = enabled,
                    colors = itemColors,
                )
            }
            if (ModerationAction.BLOCK in actions) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.action_block_user)) },
                    onClick = {
                        expanded = false
                        onBlock()
                    },
                    enabled = enabled,
                    colors = itemColors,
                )
            }
            if (!isOnline) {
                Text(
                    text = stringResource(R.string.moderation_offline),
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.sm),
                )
            }
        }
    }
}

/**
 * 通報・ブロックを送っている間に出す案内の文言（要件 16.2）。送っていなければ null。
 * 送信中はメニューの項目が押せなくなるだけで、理由が見えないまま待たせることになるので、どちらを送っているかを文言で出す
 * （遅い回線や、確認の後にオフラインになって接続を待つ間に、画面が止まって見えないように）。iOS は送信中に何も出さない＝差。
 * 純関数にして、JVM の単体テストで状態との対応を確かめる（PostModerationTest）。
 */
@StringRes
fun moderationSendingNoticeRes(state: ModerationUiState): Int? = when (state.sendingAction) {
    ModerationAction.REPORT -> R.string.report_sending
    ModerationAction.BLOCK -> R.string.block_sending
    null -> null
}

/**
 * 通報・ブロックを送っている間の案内（「通報しています」「ブロックしています」）。送っていなければ何も出さない。
 * フィードは見出しの下（一覧の上）、投稿詳細は削除中の案内（「削除しています」）と同じ位置に出す。
 */
@Composable
fun ModerationSendingNotice(state: ModerationUiState, modifier: Modifier = Modifier) {
    moderationSendingNoticeRes(state)?.let {
        Text(text = stringResource(it), style = MaterialTheme.typography.bodySmall, modifier = modifier)
    }
}

/**
 * 通報の理由の選択・ブロックの確認・「通報しました」・失敗のダイアログ。[state] が出すと決めたものだけを出す（同時には 1 つ）。
 * 文言は iOS と同じ（HomeView.swift:794-815。GalleryDetailView.swift も同じ。ModerationStringsTest が突き合わせる）。
 * ただしブロックの確認文は、iOS の文の画面の並び（ホーム・ギャラリー・そらとも）を Android にある「ホーム」だけにした
 * （ブロックした人の投稿を除くのはフィードだけ。2026-11-06 の利用者の決定。strings.xml の block_confirm_message の上の説明）。
 * 失敗の見出しは Android だけの文言で、理由の文言はフィードの取得の失敗と同じ対応（通信・権限・その他）。
 */
@Composable
fun ModerationDialogs(state: ModerationUiState, handlers: ModerationHandlers) {
    if (state.reportTarget != null) {
        // iOS の confirmationDialog（理由を並べ、選んだら確認せずに送る）。外を押す・戻る操作はキャンセルと同じ。
        // 文字サイズを大きくしても全ての理由に届くよう、並びは縦に送れるようにする（要件 16.6）
        AlertDialog(
            onDismissRequest = handlers.onCancelReport,
            title = { Text(stringResource(R.string.report_reason_title)) },
            text = {
                Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                    ReportReason.entries.forEach { reason ->
                        TextButton(onClick = { handlers.onSubmitReport(reason) }, modifier = Modifier.fillMaxWidth()) {
                            Text(reason.displayName, modifier = Modifier.fillMaxWidth())
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = handlers.onCancelReport) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
    if (state.blockTarget != null) {
        AlertDialog(
            onDismissRequest = handlers.onCancelBlock,
            title = { Text(stringResource(R.string.block_confirm_title)) },
            text = { Text(stringResource(R.string.block_confirm_message)) },
            confirmButton = {
                TextButton(onClick = handlers.onConfirmBlock) {
                    Text(stringResource(R.string.action_block), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = handlers.onCancelBlock) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
    if (state.reported) {
        AlertDialog(
            onDismissRequest = handlers.onDismissReported,
            title = { Text(stringResource(R.string.report_done_title)) },
            text = { Text(stringResource(R.string.report_done_message)) },
            confirmButton = { TextButton(onClick = handlers.onDismissReported) { Text(stringResource(R.string.action_ok)) } },
        )
    }
    state.failure?.let { failure ->
        val title = when (failure.action) {
            ModerationAction.REPORT -> R.string.report_failed_title
            ModerationAction.BLOCK -> R.string.block_failed_title
        }
        AlertDialog(
            onDismissRequest = handlers.onDismissFailure,
            title = { Text(stringResource(title)) },
            text = { Text(stringResource(feedErrorMessageRes(failure.error))) },
            confirmButton = { TextButton(onClick = handlers.onDismissFailure) { Text(stringResource(R.string.action_ok)) } },
        )
    }
}
