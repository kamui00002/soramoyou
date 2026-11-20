// ⭐️ 下書きの一覧の画面（下から出るシート）（Kiro android-edit-tools タスク 11・部品 U5・要件 8.4・8.8・8.18・13.2・13.5・13.6・13.7）
package com.yoshidometoru.soramoyou.feature.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.data.edit.DraftId
import com.yoshidometoru.soramoyou.data.edit.LocalDraftSummary
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/*
 * 公開の Composable と引数
 *
 * [DraftListSheet]：下書きの一覧。投稿の画面の上に重ねるシート（新しい行き先を作らない：design.md:1008）。
 *  - drafts：[LocalDraftSummary] の一覧。保存した日時の新しい順に並んで届く前提で、並べ替えない（8.4）
 *  - isOpening：下書きを読み込んでいる間は true。「読み込んでいます」を出し、行を押しても開かない（二重に開かない）
 *  - openEnabled：false の間は、読み込める下書きの行を押せなくする（削除は押せる）。進行中の投稿がある間は下書きを開けないので、
 *    押せるように見せないために、呼び出し側が false を渡す（問い 34・利用者の決定 2026-11-13）。既定は true（止めない）
 *  - onOpen：読み込める下書きの行を押したときに、その下書きの ID で呼ぶ（開く：8.8）。読めない下書きの行では呼ばない
 *  - onDelete：削除の確かめで「削除」を押したときに、その下書きの ID で呼ぶ。確かめ（drafts_delete_title・drafts_delete_message）は
 *    このシートの中で出す（削除の確かめの状態はシートが持つ）
 *  - onDismiss：シートを閉じる（下へ引く・外を押す・戻る操作）
 *  - modifier：シートの見た目を変えるときだけ渡す
 *
 * 行の中身：見本（thumbnailUri。null や読み込めないときは地の色だけ）・保存した日時・枚数。
 * 行は 1 つの要素として「…に保存した下書き、写真n枚」と読ませる（drafts_item_description：13.2）。
 * 読めない下書き（isBroken）の行は drafts_broken と削除だけを出し、開く操作はつけない（8.18）。0 件のときは drafts_empty。
 *
 * 色は MaterialTheme.colorScheme だけ・高さは固定しない（最小の高さだけ決める）・ガラスの部品と ViewModel は参照しない。
 * PostComposerScreen が、写真の選択の段の「下書き（n件）」から、投稿の画面の上に重ねて呼ぶ。
 */

/** 保存した日時の表示（iOS の他の日時の表示と同じ「年月日 時:分」。端末の時間帯で出す） */
private val SAVED_AT_FORMAT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy年M月d日 H:mm", Locale.JAPAN)

/** 押せる所の最小の高さ（13.2） */
private val MIN_TOUCH_HEIGHT = 48.dp

/** 見本の幅。高さは縦横比で決める（高さを固定しない） */
private val THUMBNAIL_WIDTH = 64.dp

/** 下書きの一覧のシート。引数の意味は、このファイルの先頭のコメントを参照 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DraftListSheet(
    drafts: List<LocalDraftSummary>,
    isOpening: Boolean,
    onOpen: (DraftId) -> Unit,
    onDelete: (DraftId) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    openEnabled: Boolean = true,
) {
    // 削除の確かめを出している下書き（null なら出さない）。回転で消えてもよい（確かめを出し直すだけで、何も失わない）
    var pendingDelete by remember { mutableStateOf<DraftId?>(null) }

    ModalBottomSheet(onDismissRequest = onDismiss, modifier = modifier) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.md),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
        ) {
            Text(text = stringResource(R.string.drafts_title), style = MaterialTheme.typography.titleLarge)
            if (isOpening) {
                Text(text = stringResource(R.string.drafts_loading), style = MaterialTheme.typography.bodyMedium)
            }
            if (drafts.isEmpty()) {
                Text(
                    text = stringResource(R.string.drafts_empty),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(vertical = DesignTokens.Spacing.md),
                )
            } else {
                // 縦に送れる一覧。文字を大きくしても、行が画面の外で切れない
                LazyColumn(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
                    items(drafts, key = { it.id.value }) { draft ->
                        DraftRow(
                            draft = draft,
                            canOpen = !isOpening && openEnabled,
                            onOpen = { onOpen(draft.id) },
                            onDelete = { pendingDelete = draft.id },
                        )
                    }
                }
            }
        }
    }

    pendingDelete?.let { id ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.drafts_delete_title)) },
            text = { Text(stringResource(R.string.drafts_delete_message)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingDelete = null
                        onDelete(id)
                    },
                    modifier = Modifier.heightIn(min = MIN_TOUCH_HEIGHT),
                ) { Text(stringResource(R.string.action_delete)) }
            },
            dismissButton = {
                TextButton(
                    onClick = { pendingDelete = null },
                    modifier = Modifier.heightIn(min = MIN_TOUCH_HEIGHT),
                ) { Text(stringResource(R.string.action_cancel)) }
            },
        )
    }
}

/** 下書きの 1 行。読める下書きは行全体を押すと開く。読めない下書きは文言と削除だけ */
@Composable
private fun DraftRow(
    draft: LocalDraftSummary,
    canOpen: Boolean,
    onOpen: () -> Unit,
    onDelete: () -> Unit,
) {
    val savedAt = SAVED_AT_FORMAT.format(Instant.ofEpochMilli(draft.savedAtEpochMillis).atZone(ZoneId.systemDefault()))
    val shape = RoundedCornerShape(DesignTokens.Radius.md)

    if (draft.isBroken) {
        // 読めない下書き：開く操作は付けない（8.18）。削除のボタンは別に押せる
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(DesignTokens.Spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(text = savedAt, style = MaterialTheme.typography.bodyMedium)
                Text(
                    text = stringResource(R.string.drafts_broken),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }
            DeleteButton(onDelete)
        }
        return
    }

    val description = stringResource(R.string.drafts_item_description, savedAt, draft.photoCount)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(MaterialTheme.colorScheme.surfaceVariant),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // 開く部分（見本・日時・枚数）は 1 つの要素として読ませる。削除のボタンは別の要素として残す
        Row(
            modifier = Modifier
                .weight(1f)
                .heightIn(min = MIN_TOUCH_HEIGHT)
                .clickable(enabled = canOpen, role = Role.Button, onClick = onOpen)
                .padding(DesignTokens.Spacing.sm)
                .clearAndSetSemantics { contentDescription = description },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
        ) {
            // 見本は飾り（読み上げは行の説明で足りる）。地の色を敷いておき、読み込めなければそのまま見える
            AsyncImage(
                model = draft.thumbnailUri,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .width(THUMBNAIL_WIDTH)
                    .aspectRatio(1f)
                    .clip(RoundedCornerShape(DesignTokens.Radius.sm))
                    .background(MaterialTheme.colorScheme.surface),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(text = savedAt, style = MaterialTheme.typography.bodyMedium)
                Text(
                    // 枚数の見せ方は既存の feed_image_count（「n枚」）を借りる。読み上げは行全体の説明（drafts_item_description）が担う
                    text = stringResource(R.string.feed_image_count, draft.photoCount),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        DeleteButton(onDelete)
    }
}

/** 削除のボタン（文字）。押すと確かめが出る */
@Composable
private fun DeleteButton(onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.heightIn(min = MIN_TOUCH_HEIGHT)) {
        Text(text = stringResource(R.string.action_delete), color = MaterialTheme.colorScheme.error)
    }
}
