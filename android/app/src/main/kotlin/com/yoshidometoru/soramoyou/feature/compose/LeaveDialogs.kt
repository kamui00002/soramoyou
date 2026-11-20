// ⭐️ 編集をやめる・写真を選び直すときの確かめと、下書きの案内のダイアログ（Kiro android-edit-tools タスク 11・部品 U5・要件 1.7・1.9・8.16・8.17・13.2・13.5）
package com.yoshidometoru.soramoyou.feature.compose

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.data.edit.LocalDraftRepository

/*
 * 公開の Composable と引数
 *
 * [LeaveDialog]：画面を離れる（DISCARD_OR_DRAFT）・写真を選び直す（REPICK）ときの確かめ。
 *  - question：どちらの確かめか（[LeaveQuestion]）。状態が null の間は呼ばない（呼び出し側が出し分ける）
 *  - onChoice：利用者の答え（[LeaveChoice]）。
 *      DISCARD_OR_DRAFT では SAVE_DRAFT（下書きに保存）・DISCARD（破棄）・CONTINUE（編集を続ける）のどれか
 *      REPICK では DISCARD（選び直す）・CONTINUE（やめる）のどちらか
 *    ダイアログの外を押す・戻る操作は CONTINUE（何も失わない側）として扱う
 *  - isSavingDraft：下書きを保存している間は true。保存と破棄のボタンを押せなくする（二重の保存を避ける）。
 *    編集を続けるは押せる
 *  - canSaveDraft：false の間は「下書きに保存」だけを押せなくする（破棄と編集を続けるは押せる）。この画面の投稿の途中に
 *    下書きも残さないために、呼び出し側が false を渡す（問い 34・利用者の決定 2026-11-13）。既定は true（止めない）
 *  - modifier：ダイアログの見た目を変えるときだけ渡す
 *
 * [DraftNoticeDialog]：下書きについての案内。画面は 1 つだけ出し、OK で消す（[DraftNotice] 1 つにつき 1 つのダイアログ）。
 *  - notice：案内の種類（上限・保存の失敗・読めない）
 *  - onDismiss：OK・ダイアログの外・戻る操作のどれでも呼ぶ。呼び出し側が案内を null に戻す
 *  - modifier：同上
 *
 * 色は MaterialTheme の既定のまま（色を直接書かない）。ボタンは文字（絵だけのボタンを作らない）。
 * ViewModel は参照しない（状態と操作は引数で受ける）。PostComposerScreen が、確かめ（leaveQuestion）と下書きの案内（draftNotice）があるときに呼ぶ。
 */

/** 押せる所の最小の高さ（13.2）。ボタンは文字が増えて縦に伸びてよいので、最小だけを決める */
private val MIN_TOUCH_HEIGHT = 48.dp

/**
 * 画面を離れる・写真を選び直すときの確かめ。ボタンは文字。
 * 3 つのボタン（下書きに保存・破棄・編集を続ける）は縦に並べる（文字を大きくしても画面の外へ出さないため）。
 */
@Composable
fun LeaveDialog(
    question: LeaveQuestion,
    onChoice: (LeaveChoice) -> Unit,
    isSavingDraft: Boolean = false,
    canSaveDraft: Boolean = true,
    modifier: Modifier = Modifier,
) {
    when (question) {
        LeaveQuestion.DISCARD_OR_DRAFT -> AlertDialog(
            onDismissRequest = { onChoice(LeaveChoice.CONTINUE) },
            modifier = modifier,
            title = { Text(stringResource(R.string.edit_leave_title)) },
            text = { Text(stringResource(R.string.edit_leave_message)) },
            confirmButton = {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.End,
                ) {
                    LeaveButton(
                        text = stringResource(R.string.edit_leave_save),
                        enabled = !isSavingDraft && canSaveDraft,
                        onClick = { onChoice(LeaveChoice.SAVE_DRAFT) },
                    )
                    LeaveButton(
                        text = stringResource(R.string.edit_leave_discard),
                        enabled = !isSavingDraft,
                        onClick = { onChoice(LeaveChoice.DISCARD) },
                    )
                    LeaveButton(
                        text = stringResource(R.string.edit_leave_continue),
                        enabled = true,
                        onClick = { onChoice(LeaveChoice.CONTINUE) },
                    )
                }
            },
        )

        LeaveQuestion.REPICK -> AlertDialog(
            onDismissRequest = { onChoice(LeaveChoice.CONTINUE) },
            modifier = modifier,
            title = { Text(stringResource(R.string.edit_repick_title)) },
            text = { Text(stringResource(R.string.edit_repick_message)) },
            confirmButton = {
                TextButton(
                    onClick = { onChoice(LeaveChoice.DISCARD) },
                    modifier = Modifier.heightIn(min = MIN_TOUCH_HEIGHT),
                ) { Text(stringResource(R.string.edit_repick_confirm)) }
            },
            dismissButton = {
                TextButton(
                    onClick = { onChoice(LeaveChoice.CONTINUE) },
                    modifier = Modifier.heightIn(min = MIN_TOUCH_HEIGHT),
                ) { Text(stringResource(R.string.edit_repick_cancel)) }
            },
        )
    }
}

/** 縦に並べる 1 つの文字ボタン。最小の高さだけ決める（高さは固定しない） */
@Composable
private fun LeaveButton(text: String, enabled: Boolean, onClick: () -> Unit) {
    TextButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.heightIn(min = MIN_TOUCH_HEIGHT),
    ) { Text(text) }
}

/** 下書きについての案内。OK で消す 1 つのダイアログ。文言は案内の種類で決まる */
@Composable
fun DraftNoticeDialog(
    notice: DraftNotice,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val message = when (notice) {
        DraftNotice.LIMIT_REACHED -> stringResource(R.string.drafts_limit, LocalDraftRepository.MAX_DRAFTS)
        DraftNotice.SAVE_FAILED -> stringResource(R.string.drafts_save_failed)
        DraftNotice.DRAFT_BROKEN -> stringResource(R.string.drafts_broken)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        modifier = modifier,
        text = { Text(message) },
        confirmButton = {
            TextButton(
                onClick = onDismiss,
                modifier = Modifier.heightIn(min = MIN_TOUCH_HEIGHT),
            ) { Text(stringResource(R.string.action_ok)) }
        },
    )
}
