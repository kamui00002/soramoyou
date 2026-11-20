// ⭐️ プロフィール編集の画面：アイコン・表示名・自己紹介の入力と保存（タスク 16.3・要件 6.2・10.6・10.8・10.10・16.2・16.5）（android-ui-ios-parity タスク 12.1・要件 5.1）
package com.yoshidometoru.soramoyou.feature.profile

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.data.repository.ProfileSaveStage
import com.yoshidometoru.soramoyou.feature.feed.feedErrorMessageRes
import com.yoshidometoru.soramoyou.ui.component.ErrorContent
import com.yoshidometoru.soramoyou.ui.component.LoadingContent
import com.yoshidometoru.soramoyou.ui.component.OfflineContent
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens

/**
 * プロフィール編集の画面。上にキャンセル・題名・保存、その下にアイコンと「画像を変更」、表示名、自己紹介を並べる（iOS の ProfileEditView）。
 *
 * - アイコンはシステムの写真選択画面（フォトピッカー）で 1 枚選ぶ。端末内の画像を読む権限は求めない（要件 6.2。権限の宣言が無いことは
 *   NoMediaPermissionManifestTest が確かめる）
 * - 入力欄の下に、上限までの残りの文字数を出す。超えたら iOS と同じ上限の案内を出し、保存を押せなくする（要件 10.10）
 * - 保存中は読み込み中を出し、入力とボタンを止める（要件 16.2）。失敗したら理由を入力欄の下に出す
 * - オフラインの間は保存を押せなくし、理由を入力欄の下に出す（兄弟の FeedbackScreen と同じ。レビュー R09）。保存の書き込みの途中で
 *   切れたときだけ、接続が戻ると続けることを出す（アイコンの送信中に切れると保存は終わるので出さない。全体レビュー 4 回目 Q05）
 * - 前に開いた編集画面で始めた保存（保存中に閉じたもの）が走っている間は、保存を押せなくし、理由を入力欄の下に出す（全体レビュー 4 回目 Q04）
 * - 保存できたら [onSaved] を呼ぶ（呼び出し側が閉じる）。自分のプロフィールの画面はユーザー文書を監視しているので、見出しは自然に変わる
 * - 縦に送れるようにして、文字を大きくしても欄やボタンが画面の外に出たままにならないようにする（要件 16.6）
 *
 * ⚠️ この画面そのもの（Compose の描画・フォトピッカーの起動・選んだ写真の表示）は、実機・エミュレータで未検証。
 *
 * @param onCancel キャンセル（戻る）。入力は ViewModel ごと捨てられ、残らない。保存中にも押せるが、送り始めた保存は最後まで届く
 *   （ProfileEditor が取り消さない。押せなくすると、保存の途中で電波が切れたときに画面に閉じ込められる。レビュー R03）。
 *   開き直した画面は、その保存が終わるまで保存を押せない（[ProfileEditUiState.isOthersSaving]）
 */
@Composable
fun ProfileEditScreen(
    state: ProfileEditUiState,
    isOnline: Boolean,
    onDisplayNameChange: (String) -> Unit,
    onBioChange: (String) -> Unit,
    onIconPicked: (String?) -> Unit,
    onSave: () -> Unit,
    onRetryLoad: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // 写真選択画面から戻ったら、選んだ写真の URI（選ばずに閉じたら null）を渡す
    val pickIcon = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> onIconPicked(uri?.toString()) }

    Column(modifier = modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = onCancel) { Text(stringResource(R.string.action_cancel)) }
            Text(
                text = stringResource(R.string.profile_edit_title),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onSave, enabled = state.canSave && isOnline) { Text(stringResource(R.string.action_save)) }
        }
        when (val load = state.load) {
            ProfileEditLoad.Loading -> LoadingContent()
            is ProfileEditLoad.Failed ->
                if (load.failedWhileOffline) {
                    OfflineContent(isOnline = isOnline, onRetry = onRetryLoad)
                } else {
                    ErrorContent(onRetry = onRetryLoad, message = stringResource(feedErrorMessageRes(load.error)))
                }
            ProfileEditLoad.Ready -> EditForm(
                state = state,
                isOnline = isOnline,
                onDisplayNameChange = onDisplayNameChange,
                onBioChange = onBioChange,
                onPickIcon = { pickIcon.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
            )
        }
    }
}

/** 入力欄。保存中は全て止める。 */
@Composable
private fun EditForm(
    state: ProfileEditUiState,
    isOnline: Boolean,
    onDisplayNameChange: (String) -> Unit,
    onBioChange: (String) -> Unit,
    onPickIcon: () -> Unit,
) {
    val editable = !state.isSaving
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(DesignTokens.Spacing.md),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
    ) {
        // アイコン：新しく選んだ写真があればそれを、無ければいまのアイコンを出す。飾りなので TalkBack には読ませない（下のボタンを読む）
        AsyncImage(
            model = state.newIcon?.uri ?: state.currentPhotoUrl,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .align(Alignment.CenterHorizontally)
                .size(100.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant),
        )
        // 「画像を削除」は置かない（MVP にアイコンを消す操作は無い：ProfileEdit）
        OutlinedButton(onClick = onPickIcon, enabled = editable, modifier = Modifier.align(Alignment.CenterHorizontally)) {
            Text(stringResource(R.string.action_change_image))
        }

        OutlinedTextField(
            value = state.displayName,
            onValueChange = onDisplayNameChange,
            enabled = editable,
            label = { Text(stringResource(R.string.profile_edit_display_name)) },
            supportingText = { Text(stringResource(R.string.profile_edit_remaining, state.displayNameRemaining.coerceAtLeast(0))) },
            // 赤くするのは保存を止めるときだけ（読んだ値から変えていない表示名と、iOS より多く数える古い端末では赤くしない。
            // 残りは 0 で止めて出す。全体レビュー 4 回目 R21 の利用者の決定）
            isError = state.displayNameOverLimit,
            // 1 行にする。確定のキーで改行が入り、名前が 2 行に割れたまま保存されないように（iOS の TextField も改行を入れない。レビュー R19）。
            // 確定のキーは次の欄（自己紹介）へ進む。貼り付けた改行や前後の空白は取り除かない（前後の空白を取り除かない既決のまま）
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = state.bio,
            onValueChange = onBioChange,
            enabled = editable,
            label = { Text(stringResource(R.string.profile_edit_bio)) },
            supportingText = { Text(stringResource(R.string.profile_edit_remaining, state.bioRemaining.coerceAtLeast(0))) },
            isError = state.bioOverLimit,
            // 自己紹介は複数行（iOS は TextEditor）。最低 3 行の高さにして、それ以上は入力に合わせて伸びる
            minLines = 3,
            modifier = Modifier.fillMaxWidth(),
        )

        // 上限を超えている間は、iOS と同じ案内を出す（ProfileEditView.swift:79-88）
        if (!state.isWithinLimits) {
            Text(
                text = stringResource(R.string.profile_edit_too_long),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
            )
        }
        state.error?.let { error ->
            Text(text = stringResource(profileEditErrorMessageRes(error)), color = MaterialTheme.colorScheme.error)
        }
        // オフラインの間は保存を押せないので、その理由を出す（兄弟の FeedbackScreen と同じ。レビュー R09）。
        // 保存の書き込み（users・publicProfiles）の途中で切れたときだけ、送り始めた保存が接続を待っていることを出す（読み込み中のまま
        // 理由なく止まって見えないように）。アイコンの送信中に切れると、送信は再試行の上限で失敗して保存が終わるので、保存していない
        // ときと同じ理由にする（全体レビュー 4 回目 Q05。投稿の画面のアップロード中と同じ）
        if (!isOnline) {
            Text(
                text = stringResource(if (state.saveStage == ProfileSaveStage.SAVING) R.string.compose_saving_offline else R.string.offline_title),
                style = MaterialTheme.typography.bodySmall,
            )
        }
        // 前に開いた編集画面で始めた保存（保存中に閉じたもの）が走っている間は、この画面の保存を押せない理由を出す（全体レビュー 4 回目 Q04）
        if (state.isOthersSaving) {
            Text(text = stringResource(R.string.profile_edit_previous_saving), style = MaterialTheme.typography.bodySmall)
        }
        if (state.isSaving) CircularProgressIndicator(modifier = Modifier.align(Alignment.CenterHorizontally))
    }
}
