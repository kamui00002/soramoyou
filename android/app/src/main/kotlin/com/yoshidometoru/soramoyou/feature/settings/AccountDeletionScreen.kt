// ⭐️ アカウントの削除の画面：消えるもの・残るもの・取り消せないことの説明、Web の受付ページ、パスワード、確認、削除中の段階、失敗と再試行（タスク 31.5・要件 2.9・12.1〜12.7・16.2・16.5・16.6）（android-ui-ios-parity タスク 12.1・要件 5.1）
package com.yoshidometoru.soramoyou.feature.settings

import android.content.ActivityNotFoundException
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens

/**
 * アカウントの削除の画面（設定の「アカウントを削除」から開く。iOS は設定の中の確認のアラート → パスワードのアラート → 削除中の覆い）。
 *
 * - 削除する前：消えるデータ（投稿の写真とアイコン画像を含む）・残るデータ（通報の記録とご意見・ご要望など）・取り消せないこと（要件 12.2）、
 *   Web の削除の受付ページを開くボタン（要件 12.6。残るデータも消したい人は、ここで削除せずに受付ページから申し込むので、削除のボタンより前に置く）、
 *   パスワードの入力（要件 12.5。メールアドレスは部品がいまのユーザーから取る）、「確認して削除」。押すと iOS と同じ見出しの確認を出し、
 *   「削除する」で始める
 * - 削除中：いまの段階を出す（要件 12.4・16.2）。戻るボタンを出さず、端末の戻る操作も受け止めて画面に留める（下の注記）。
 *   通信が切れている間は「接続が戻ると削除を続けます」を添える（Firestore の削除は上限時間なしに接続を待つので、案内が無いと
 *   段階の文言のまま説明なく止まって見える。レビュー F19）
 * - 失敗：止まった段階と原因と、その後どうなっているかを出し、「再試行」を出す（要件 12.4）
 * - 完了：端末内のデータは部品が消し済み。認証状態が未ログインになるとログイン後の画面ごと捨てられ、ログイン前の画面に替わる（要件 12.7）
 *
 * 戻る操作：削除中は画面に留める（新規登録の途中と同じ受け止め方）。部品は再認証の後は画面を離れても最後まで消すが、離れた先では結果が見えず、
 * その間の他の画面の「作る・書き換える」操作は部品が断る（AccountDeletionService の区間）ので、止まって見える操作をさせないため。
 * 再認証の間に離れると（アプリを閉じるなど）、何も消さずに止まる（部品の約束）。
 *
 * ⚠️ この画面そのもの（Compose の描画・キーボードとの重なり・TalkBack の読み上げ・文字サイズ 200%・ブラウザが開くこと）は、
 *   実機・エミュレータで未検証（33.x）。
 *
 * @param stage いま削除している段階（AccountDeletionService.stage）。削除中だけ使う。
 * @param isOnline 接続の有無。オフラインの間は削除と再試行を押せなくして案内を出す。削除中は、接続が戻ると続けることを案内する。
 * @param requestPageUrl Web の削除の受付ページ。外のブラウザで開く。
 * @param onRequestPageOpenFailed 受付ページを開けなかった（開けるアプリが端末に無いなど）。
 */
@Composable
fun AccountDeletionScreen(
    state: AccountDeletionUiState,
    stage: DeletionStage?,
    isOnline: Boolean,
    requestPageUrl: String,
    onPasswordChange: (String) -> Unit,
    onRequestDelete: () -> Unit,
    onConfirmDelete: () -> Unit,
    onCancelDelete: () -> Unit,
    onRetry: () -> Unit,
    onRequestPageOpenFailed: (Throwable) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val busy = state.isDeleting || state.completed
    // 削除中と削除し終えた後は、端末の戻る操作を受け止めて何もしない（上の「戻る操作」）
    BackHandler(enabled = busy) {}
    // 説明と入力の縦送りの位置。削除中は説明と入力の塊（DeletionForm）を合成から外すので、塊の中で作ると、失敗して戻るたびに
    // 先頭から作り直され、末尾の失敗の表示と「再試行」が説明の下に隠れる。ここで作って渡し、削除中を挟んでも位置を保つ
    val formScroll = rememberScrollState()

    Column(modifier = modifier.fillMaxSize().imePadding()) {
        // 戻るは文字のボタン（ブロック中のユーザーの画面と同じ）。削除中は出さない
        if (!busy) {
            TextButton(onClick = onBack, modifier = Modifier.padding(horizontal = DesignTokens.Spacing.sm)) {
                Text(stringResource(R.string.action_back))
            }
        }
        Text(
            text = stringResource(R.string.account_delete_title),
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier
                .padding(horizontal = DesignTokens.Spacing.lg, vertical = DesignTokens.Spacing.sm)
                .semantics { heading() },
        )
        when {
            state.completed -> DoneContent()
            state.isDeleting -> DeletingContent(stage, isOnline)
            else -> DeletionForm(state, formScroll, isOnline, requestPageUrl, onPasswordChange, onRequestDelete, onRetry, onRequestPageOpenFailed)
        }
    }

    if (state.confirming) {
        // iOS の確認のアラートと同じ見出しと「削除する」（SettingsView.swift の showingDeleteAccountConfirmation）
        AlertDialog(
            onDismissRequest = onCancelDelete,
            title = { Text(stringResource(R.string.account_delete_title)) },
            text = { Text(stringResource(R.string.account_delete_confirm_message)) },
            confirmButton = {
                TextButton(onClick = onConfirmDelete) {
                    Text(stringResource(R.string.action_delete_account), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = onCancelDelete) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
}

/**
 * 削除する前の説明と入力。縦に送れるようにして、文字を大きくしても欄やボタンが画面の外に出たままにならないようにする。
 *
 * 失敗して戻ったときは、末尾（失敗の表示と「再試行」）まで送る。理由と「再試行」は説明の後ろにあるので、文字が大きいと
 * （要件 16.6 の 200%）押した位置のままでは画面の下に隠れる。失敗の塊そのものが画面より高いときは「再試行」の側が見え、
 * 見出しは上に出うる（読み上げは FailureContent の読み上げの領域が行う）。
 *
 * @param scrollState 縦送りの位置。画面（[AccountDeletionScreen]）で作ったものを受け取る（削除中に塊が外れても捨てないため）。
 */
@Composable
private fun DeletionForm(
    state: AccountDeletionUiState,
    scrollState: ScrollState,
    isOnline: Boolean,
    requestPageUrl: String,
    onPasswordChange: (String) -> Unit,
    onRequestDelete: () -> Unit,
    onRetry: () -> Unit,
    onRequestPageOpenFailed: (Throwable) -> Unit,
) {
    val uriHandler = LocalUriHandler.current
    LaunchedEffect(state.failure) {
        if (state.failure == null) return@LaunchedEffect
        // 失敗の表示が加わった後の高さ（送れる最大）は、塊が戻ってきたフレームで並べ終えてから分かる。1 フレーム待ってから送る
        // （待たずに読むと、削除の前の高さのままの最大まで送ることになり、失敗の表示の分だけ足りない）
        withFrameNanos { }
        scrollState.animateScrollTo(scrollState.maxValue)
    }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(scrollState)
            .padding(horizontal = DesignTokens.Spacing.lg, vertical = DesignTokens.Spacing.sm),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
    ) {
        // ── 消えるもの・残るもの・取り消せないこと（要件 12.2）──
        Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)) {
            Text(stringResource(R.string.account_delete_intro), style = MaterialTheme.typography.bodyMedium)
            Text(stringResource(R.string.account_delete_removed_items), style = MaterialTheme.typography.bodyMedium)
        }
        Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)) {
            Text(stringResource(R.string.account_delete_kept_title), style = MaterialTheme.typography.titleSmall)
            Text(stringResource(R.string.account_delete_kept_items), style = MaterialTheme.typography.bodyMedium)
        }
        Text(
            text = stringResource(R.string.account_delete_irreversible),
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.error,
        )

        // ── Web の削除の受付ページ（要件 12.6）。外のブラウザで開く ──
        Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
            Text(stringResource(R.string.account_delete_request_page_note), style = MaterialTheme.typography.bodySmall)
            OutlinedButton(
                onClick = {
                    // 開けるアプリが無いと、Compose の窓口は IllegalArgumentException（中身は ActivityNotFoundException）を投げる。
                    // アプリを落とさずに、アドレスを文字で出す
                    try {
                        uriHandler.openUri(requestPageUrl)
                    } catch (e: IllegalArgumentException) {
                        onRequestPageOpenFailed(e)
                    } catch (e: ActivityNotFoundException) {
                        onRequestPageOpenFailed(e)
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(stringResource(R.string.action_open_delete_request_page))
            }
            if (state.requestPageOpenFailed) {
                // 書き写せるように、選べる文字で出す
                SelectionContainer {
                    Text(
                        text = stringResource(R.string.account_delete_request_page_open_failed, requestPageUrl),
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                    )
                }
            }
        }

        // ── パスワード（要件 12.5。iOS のパスワードのアラートの見出しと説明）──
        Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
            Text(stringResource(R.string.account_delete_password_title), style = MaterialTheme.typography.titleSmall)
            Text(stringResource(R.string.account_delete_password_message), style = MaterialTheme.typography.bodySmall)
            OutlinedTextField(
                value = state.password,
                onValueChange = onPasswordChange,
                label = { Text(stringResource(R.string.login_password_placeholder)) },
                isError = state.passwordMissing,
                supportingText = if (state.passwordMissing) {
                    { Text(stringResource(R.string.account_delete_password_required)) }
                } else {
                    null
                },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                // 確定のキーで削除を始めない（取り消せない操作は、ボタンを押したときだけ）
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                modifier = Modifier.fillMaxWidth(),
            )
        }

        state.failure?.let { error -> FailureContent(error) }

        if (!isOnline) {
            Text(stringResource(R.string.account_delete_offline), style = MaterialTheme.typography.bodySmall)
        }

        // 失敗の後は「再試行」（確認のダイアログを出し直さない）。それまでは「確認して削除」→ 確認のダイアログ
        val retrying = state.canRetry
        Button(
            onClick = if (retrying) onRetry else onRequestDelete,
            enabled = isOnline,
            colors = ButtonDefaults.buttonColors(
                containerColor = MaterialTheme.colorScheme.error,
                contentColor = MaterialTheme.colorScheme.onError,
            ),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(stringResource(if (retrying) R.string.action_retry else R.string.action_confirm_delete_account))
        }
    }
}

/**
 * 削除の失敗。止まった段階と原因（言えるときだけ）と、その後どうなっているか・どうすればよいか。
 * 出たときに TalkBack が読み上げるよう、読み上げの領域にする。
 */
@Composable
private fun FailureContent(error: AppError) {
    val text = deletionFailureText(error)
    Column(
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs),
    ) {
        Text(
            text = deletionString(text.title),
            color = MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.titleSmall,
        )
        text.reason?.let { reason ->
            Text(stringResource(reason), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
        }
        Text(stringResource(text.detail), style = MaterialTheme.typography.bodyMedium)
    }
}

/**
 * 削除中の表示（iOS の「アカウントを削除中...」の覆い）。いまの段階の文言を、変わるたびに読み上げる。
 *
 * [isOnline] が false の間は、接続が戻ると削除を続けることを添えて、出たときに読み上げる（フィードバックの送信中のオフラインの
 * 案内 feedback_sending_offline と同じ考え方。レビュー F19）。部品は再認証の後は取り消さず、Firestore の削除は接続が戻るまで待って
 * 続きを消すので「続けます」と言える（サーバーから取り直す段階は待たずに、画像の削除は 30 秒で打ち切って失敗し、失敗の表示に替わる）。
 * iOS の覆いには、この案内は無い。
 */
@Composable
private fun DeletingContent(stage: DeletionStage?, isOnline: Boolean) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(DesignTokens.Spacing.lg),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        CircularProgressIndicator(modifier = Modifier.size(40.dp))
        Text(
            text = deletionString(deletionProgressText(stage)),
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
        if (!isOnline) {
            Text(
                text = stringResource(R.string.account_delete_deleting_offline),
                style = MaterialTheme.typography.bodySmall,
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
    }
}

/** 削除し終えた表示。すぐにログイン前の画面に替わるので、見えるのは一瞬だけ。 */
@Composable
private fun DoneContent() {
    Text(
        text = stringResource(R.string.account_delete_done),
        style = MaterialTheme.typography.bodyLarge,
        modifier = Modifier
            .padding(DesignTokens.Spacing.lg)
            .semantics { liveRegion = LiveRegionMode.Polite },
    )
}

/** [text] を文字列にする（段階の名前を差し込む文言は、名前も文字列にして入れる）。 */
@Composable
private fun deletionString(text: DeletionText): String =
    if (text.arg == null) stringResource(text.res) else stringResource(text.res, stringResource(text.arg))
