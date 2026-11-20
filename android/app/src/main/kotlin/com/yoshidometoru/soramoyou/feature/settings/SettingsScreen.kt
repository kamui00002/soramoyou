// ⭐️ 設定画面：項目（ご意見・ご要望・ブロック中のユーザー）とログアウト・アカウントを削除（タスク 8.3・29.2・30・31.5・要件 2.9・11.5・12.1・13.1・16.2）（android-ui-ios-parity タスク 12.1・要件 5.1）
package com.yoshidometoru.soramoyou.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.feature.auth.authErrorMessageRes
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens

/**
 * 設定画面。見出しの下に項目を縦に 1 行ずつ並べ（[SettingsItem]）、その下にログアウトを置く。
 * 見出しの上には文字のボタンの「戻る」を置く（ブロック中のユーザーの画面と同じ文字。端末の戻る操作でも戻れる）。
 * ログアウトは iOS と同じく確認のダイアログを経る（SettingsView.swift:99-115。文言も同じ）。
 * 処理中はボタンの中に読み込み中の表示を出す（要件 16.2）。
 *
 * 項目の並びは iOS の SettingsView に合わせる（法的情報の節 → サポートの節 → アカウントの節：SettingsView.swift:49-64）。
 * 「プライバシーポリシー」（レビュー R01）と「利用規約」（R02）は法的情報の節にあたるので、iOS と同じ順でサポートの項目より上の先頭に置き、外のブラウザで開く。
 * 「ご意見・ご要望」（タスク 30）は iOS のサポートの節にある項目なので、先頭に置く。iOS に無い「ブロック中のユーザー」（タスク 29.2）は、
 * アカウントの節にあたるログアウトの直上に置く。この後に足す項目は、iOS と同じ並びになる位置に 1 行ずつ足す
 * （31.5 の「アカウントを削除」は iOS と同じくログアウトの下）。
 *
 * @param onBack 「戻る」を押した（設定を閉じて、開く前の画面に戻る）。
 * @param onOpenBlockedUsers 「ブロック中のユーザー」を開く。null なら項目を出さない（BLOCK の書き込みが無効なビルド。
 *   投稿の導線の onCompose と同じ形）。
 * @param onOpenFeedback 「ご意見・ご要望」を開く。null なら項目を出さない（FEEDBACK の書き込みが無効なビルド。onOpenBlockedUsers と同じ形）。
 * @param onOpenAccountDeletion 「アカウントを削除」を開く（タスク 31.5・要件 12.1）。null なら項目を出さない（ACCOUNT_DELETE の書き込みが
 *   無効なビルド。onOpenBlockedUsers と同じ形）。iOS と同じくログアウトの下に置く（SettingsView.swift の accountSection）。
 */
@Composable
fun SettingsScreen(
    state: SettingsUiState,
    onSignOut: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onOpenBlockedUsers: (() -> Unit)? = null,
    onOpenFeedback: (() -> Unit)? = null,
    onOpenAccountDeletion: (() -> Unit)? = null,
) {
    var confirming by rememberSaveable { mutableStateOf(false) }
    val uriHandler = LocalUriHandler.current
    // 開けなかった法的情報のページのアドレス（null なら出さない）。回転しても消えないように残す
    var unopenedLegalUrl by rememberSaveable { mutableStateOf<String?>(null) }
    // 法的情報のページを開く窓口。開けるアプリが無くても落とさず、開けなかったアドレスを下に出す
    val openLegalPage: (String) -> Unit = { url -> if (!uriHandler.tryOpenUri(url)) unopenedLegalUrl = url }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(DesignTokens.Spacing.lg),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
    ) {
        // 戻るは文字のボタン（ブロック中のユーザーの画面と同じ。アイコンの部品は依存に無い）。縦送りの中に置くので、下へ送ると一緒に流れる。
        // 横の余白は足さない（この Column が余白を持つので、足すと字下げが二重になる。素の TextButton なら下の項目と文字の左端がそろう）
        TextButton(onClick = onBack) { Text(stringResource(R.string.action_back)) }
        Text(stringResource(R.string.settings_title), style = MaterialTheme.typography.headlineSmall)

        // ── 項目（iOS の並び：法的情報 → サポート → アカウント）──
        // プライバシーポリシーは外のブラウザで開く。開けなくても落とさず、アドレスを文字で出す（AccountDeletionScreen の受付ページと同じ作り）。
        // 書き込みの有無に関わらず常に出す
        SettingsItem(stringResource(R.string.privacy_policy_title), onClick = { openLegalPage(PRIVACY_POLICY_URL) })
        // 利用規約も同じく外のブラウザで開く（iOS の法的情報の節と同じく、プライバシーポリシーの次。レビュー R02）
        SettingsItem(stringResource(R.string.terms_of_service_title), onClick = { openLegalPage(TERMS_OF_SERVICE_URL) })
        unopenedLegalUrl?.let { UnopenedPageAddress(it) }
        onOpenFeedback?.let { SettingsItem(stringResource(R.string.feedback_title), onClick = it) }
        onOpenBlockedUsers?.let { SettingsItem(stringResource(R.string.blocked_users_title), onClick = it) }

        OutlinedButton(onClick = { confirming = true }, enabled = !state.isSigningOut, modifier = Modifier.fillMaxWidth()) {
            if (state.isSigningOut) CircularProgressIndicator() else Text(stringResource(R.string.action_sign_out))
        }

        state.error?.let { kind ->
            Text(
                text = stringResource(authErrorMessageRes(kind)),
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }

        // ログアウトの下（iOS のアカウントの節と同じ並び）。ログアウトの失敗の表示とは離さないよう、その後に置く
        onOpenAccountDeletion?.let { SettingsItem(stringResource(R.string.account_delete_title), onClick = it) }
    }

    if (confirming) {
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text(stringResource(R.string.sign_out_confirm_title)) },
            text = { Text(stringResource(R.string.sign_out_confirm_message)) },
            confirmButton = {
                TextButton(onClick = {
                    confirming = false
                    onSignOut()
                }) { Text(stringResource(R.string.action_sign_out), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { confirming = false }) { Text(stringResource(R.string.action_cancel)) }
            },
        )
    }
}

/**
 * 設定の 1 項目（押すと別の画面を開く。iOS の SettingsRow にあたる）。行の幅いっぱいを押せる文字のボタンにし、文字は左に寄せる。
 * 高さは固定しない（文字サイズを大きくすると行が伸びる：要件 16.6）。アイコンの部品は依存に無いので、iOS の行の絵は出さない。
 */
@Composable
private fun SettingsItem(title: String, onClick: () -> Unit) {
    TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth()) {
        Text(text = title, modifier = Modifier.fillMaxWidth())
    }
}
