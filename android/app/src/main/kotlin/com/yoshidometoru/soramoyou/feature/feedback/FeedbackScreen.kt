// ⭐️ フィードバック送信の画面：種別の選択・本文の入力・送信・完了と失敗の表示（タスク 30・要件 13.1〜13.6・16.2・16.5・16.6）（android-ui-ios-parity タスク 12.1・要件 5.1）
package com.yoshidometoru.soramoyou.feature.feedback

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.model.FeedbackCategory
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens

/**
 * フィードバック送信の画面（iOS の FeedbackView。設定の「ご意見・ご要望」から開く）。上に「閉じる」と題名、その下を [state] で切り替える。
 *
 * - 送る前：案内の文・種類の選択（iOS はセグメント。Android は縦に並べた選択肢で、文字を大きくしても欠けない：要件 16.6）・
 *   内容の入力欄と文字数・送信のボタン。本文が空白だけ・1000 文字を超えるときは、送信を押すと送らずに理由を入力欄の下に出す
 *   （要件 13.3。ボタンを押せなくして理由を見せないことはしない）。送信に失敗したら、入力した本文を残したまま理由を出す（要件 13.6）
 * - 送った後：「送信しました」と閉じるボタン（要件 13.5）
 * - 送信中は入力とボタンを止め、ボタンの中に読み込み中の表示を出す（要件 16.2）。オフラインの間は送信を押せなくして案内を出す
 *
 * ⚠️ この画面そのもの（Compose の描画・キーボードとの重なり・TalkBack の読み上げ・文字サイズ 200%）は、実機・エミュレータで未検証（33.x）。
 *
 * @param isOnline 接続の有無。
 * @param onClose 閉じる（設定へ戻る）。送った後の「閉じる」も同じ。
 */
@Composable
fun FeedbackScreen(
    state: FeedbackUiState,
    isOnline: Boolean,
    onMessageChange: (String) -> Unit,
    onCategoryChange: (FeedbackCategory) -> Unit,
    onSubmit: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxSize().imePadding()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = onClose) { Text(stringResource(R.string.action_close)) }
            Text(
                text = stringResource(R.string.feedback_title),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() },
            )
        }
        if (state.submitted) {
            SubmittedContent(onClose)
        } else {
            FeedbackForm(state, isOnline, onMessageChange, onCategoryChange, onSubmit)
        }
    }
}

/** 入力の欄。縦に送れるようにして、文字を大きくしても欄やボタンが画面の外に出たままにならないようにする。 */
@Composable
private fun FeedbackForm(
    state: FeedbackUiState,
    isOnline: Boolean,
    onMessageChange: (String) -> Unit,
    onCategoryChange: (FeedbackCategory) -> Unit,
    onSubmit: () -> Unit,
) {
    val editable = !state.isSending
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(DesignTokens.Spacing.md),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
    ) {
        Text(stringResource(R.string.feedback_intro), style = MaterialTheme.typography.bodyMedium)

        // 種類（iOS は不具合・要望・その他のセグメント。最初は不具合）。ラジオボタンの並びとして、TalkBack に「選択中」を読ませる
        Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)) {
            Text(stringResource(R.string.feedback_category_label), style = MaterialTheme.typography.labelLarge)
            Column(modifier = Modifier.selectableGroup()) {
                FeedbackCategory.entries.forEach { category ->
                    CategoryRow(
                        category = category,
                        selected = category == state.category,
                        enabled = editable,
                        onSelect = { onCategoryChange(category) },
                    )
                }
            }
        }

        // 内容。文字数は送る本文（前後の空白を除いたもの）の UTF-16 の長さ。判定（rules）と同じ数え方なので、表示と判定が食い違わない
        OutlinedTextField(
            value = state.message,
            onValueChange = onMessageChange,
            enabled = editable,
            label = { Text(stringResource(R.string.feedback_message_label)) },
            placeholder = { Text(stringResource(R.string.feedback_message_hint)) },
            supportingText = { Text(stringResource(R.string.compose_count, state.trimmedLength, TextLimits.FEEDBACK_MAX)) },
            isError = state.isOverLimit,
            minLines = 5,
            maxLines = 12,
            modifier = Modifier.fillMaxWidth(),
        )

        state.error?.let { error -> SendError(error) }

        if (!isOnline) {
            Text(
                text = stringResource(if (state.isSending) R.string.feedback_sending_offline else R.string.feedback_offline),
                style = MaterialTheme.typography.bodySmall,
            )
        }

        // 送信中とオフラインの間は押せない。本文の不備は、押した後に理由を出す（ボタンを先に止めて理由を隠さない）
        Button(onClick = onSubmit, enabled = editable && isOnline, modifier = Modifier.fillMaxWidth()) {
            if (state.isSending) {
                // ボタンの色（onPrimary）に合わせる。既定の色（primary）だと、ボタンの背景と同じで見えない
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = LocalContentColor.current)
            } else {
                Text(stringResource(R.string.feedback_send))
            }
        }
    }
}

/**
 * 種類の 1 行。行全体を押せる（高さは 48dp 以上で、文字が増えたら伸びる）。ラジオボタンの印は飾りで、押す操作は行が受ける
 * （印と行の両方が操作を受けると、TalkBack が二重に読む）。
 */
@Composable
private fun CategoryRow(category: FeedbackCategory, selected: Boolean, enabled: Boolean, onSelect: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .selectable(selected = selected, enabled = enabled, role = Role.RadioButton, onClick = onSelect),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null, enabled = enabled)
        Text(text = category.displayName, modifier = Modifier.padding(start = DesignTokens.Spacing.sm))
    }
}

/**
 * 送れなかった理由。本文の入力の不備は文言だけ、それ以外（通信・権限など）は「送信に失敗しました」の見出しを付ける。
 * 出たときに TalkBack が読み上げるよう、読み上げの領域にする。
 */
@Composable
private fun SendError(error: AppError) {
    Column(modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) {
        if (!isFeedbackInputProblem(error)) {
            Text(
                text = stringResource(R.string.feedback_failed_title),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.titleSmall,
            )
        }
        Text(
            text = stringResource(feedbackErrorMessageRes(error)),
            color = MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

/** 送った後の表示（iOS の successView）。アイコンの部品は依存に無いので、iOS のチェックマークの絵は出さない。 */
@Composable
private fun SubmittedContent(onClose: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(DesignTokens.Spacing.lg),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = stringResource(R.string.feedback_done_title),
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
        Text(
            text = stringResource(R.string.feedback_done_message),
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.Center,
        )
        Button(onClick = onClose, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.action_close)) }
    }
}
