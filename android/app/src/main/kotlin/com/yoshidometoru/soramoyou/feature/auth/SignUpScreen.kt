// ⭐️ 新規登録の画面（タスク 14.4・要件 2.3・2.5〜2.7・2.11・16.1）（android-ui-ios-parity タスク 11.4・要件 2.1・2.3・2.5・3.9・5.1・5.2・6.3・6.4）
package com.yoshidometoru.soramoyou.feature.auth

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.feature.settings.PRIVACY_POLICY_URL
import com.yoshidometoru.soramoyou.feature.settings.TERMS_OF_SERVICE_URL
import com.yoshidometoru.soramoyou.feature.settings.UnopenedPageAddress
import com.yoshidometoru.soramoyou.feature.settings.tryOpenUri
import com.yoshidometoru.soramoyou.ui.component.AccentGradientButton
import com.yoshidometoru.soramoyou.ui.component.GlassTextField
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens

/**
 * 新規登録の画面。状態は [AuthViewModel] が持ち、ここは表示と入力の受け渡しだけをする。
 * 文言は iOS の SignUpView と同じ（SessionScreensStringsTest が突き合わせる）。
 *
 * - 送れるのは、メールアドレス・6 文字以上のパスワード・一致する確認が揃ったときだけ（iOS の isFormValid と同じ）。
 *   6 文字に足りない間は、パスワードの欄の下に理由を出す（要件 2.6）。メールアドレスの形式の誤りは、送ったときに失敗の文言で出す
 *   （作成の前に AuthRepository が検証し、通らなければアカウントを作らない：要件 2.5）
 * - 確認を入れ始めたら、一致しているかを出す（iOS も同じ：SignUpView.swift:130-139）
 * - アカウントは作れたが文書の作成に失敗したときは、失敗と「続ける」だけを出す（要件 2.11）。押すまでフィードへ切り替わらない
 * - 高さを固定せず、縦に送れるようにして、文字サイズを大きくしてもはみ出さないようにする（要件 16.6）
 *
 * ガラスの部品（android-ui-ios-parity 要件 2.1・2.5・5.1。ログインの画面と同じ決め方）:
 * - 3 つの入力欄はガラスの入力欄（GlassTextField）、「アカウントを作成」と、文書の作成に失敗した後の「続ける」は
 *   グラデーションのボタン（AccentGradientButton）にする。ラベルの読み上げとボタンの役割は今のまま（要件 6.3）。
 *   同意の案内と「戻る」の文字だけのボタンは今のまま
 * - グラデーションのボタンには、送信中でないときだけ、押せないときに薄くする指定を渡す（入力が足りないときだけ薄くなる。
 *   「続ける」はいつも押せるので薄くならない。押せない部品の色は比の表の対象外：要件 3.9）
 * - 送信中と文書の失敗を見せている間は入力欄を押せなくする（今のまま）。押せない入力欄の地の色は Material 3 の既定（透明）なので、
 *   その間だけガラスの面が消えて空が見える（見え方は端末で確かめる：段階 5）
 * - 余白はトークンの名前で書く。端は iOS の SignUpView と同じ xl（32dp。作業の前は 24dp）、要素の間も iOS と同じ md（16dp）、
 *   縦は今と同じ xxl（48dp）
 * - 雲は、ログインの前の背景（空と雲）が、空の上・この画面の文字・入力欄・ボタンより後ろに描く（タスク 8.2。この画面では描かない）
 */
@Composable
fun SignUpScreen(
    state: SignUpUiState,
    onEmailChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onConfirmPasswordChange: (String) -> Unit,
    onSignUp: () -> Unit,
    onContinue: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // 送信中と、文書の失敗を見せている間は、入力を変えさせない（送った内容と表示がずれないように）
    val editable = !state.isSubmitting && !state.bootstrapFailed
    val uriHandler = LocalUriHandler.current
    // 開けなかった法的情報のページのアドレス（null なら出さない）。回転しても消えないように残す
    var unopenedLegalUrl by rememberSaveable { mutableStateOf<String?>(null) }
    // 法的情報のページを開く窓口。開けるアプリが無くても落とさず、開けなかったアドレスを下に出す（設定の画面と同じ作り）
    val openLegalPage: (String) -> Unit = { url -> if (!uriHandler.tryOpenUri(url)) unopenedLegalUrl = url }
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = DesignTokens.Spacing.xl, vertical = DesignTokens.Spacing.xxl),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(stringResource(R.string.signup_title), style = MaterialTheme.typography.headlineMedium)
        Text(stringResource(R.string.signup_subtitle), style = MaterialTheme.typography.bodyMedium)

        GlassTextField(
            value = state.email,
            onValueChange = onEmailChange,
            label = { Text(stringResource(R.string.login_email_placeholder)) },
            enabled = editable,
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Next),
            modifier = Modifier.fillMaxWidth(),
        )
        GlassTextField(
            value = state.password,
            onValueChange = onPasswordChange,
            label = { Text(stringResource(R.string.signup_password_placeholder)) },
            enabled = editable,
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Next),
            isError = state.passwordTooShort,
            // 6 文字に足りない理由は iOS の失敗の文言（AuthService.swift の weakPassword）をそのまま使う
            supportingText = if (state.passwordTooShort) {
                { Text(stringResource(R.string.auth_error_weak_password)) }
            } else {
                null
            },
            modifier = Modifier.fillMaxWidth(),
        )
        GlassTextField(
            value = state.confirmPassword,
            onValueChange = onConfirmPasswordChange,
            label = { Text(stringResource(R.string.signup_confirm_password_placeholder)) },
            enabled = editable,
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { onSignUp() }),
            modifier = Modifier.fillMaxWidth(),
        )
        if (state.confirmPassword.isNotEmpty()) {
            Text(
                text = stringResource(if (state.passwordsMatch) R.string.signup_passwords_match else R.string.signup_passwords_mismatch),
                color = if (state.passwordsMatch) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        state.error?.let { kind ->
            // 失敗の文言は、出たときに TalkBack が読み上げる
            Text(
                text = stringResource(authErrorMessageRes(kind)),
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
        }

        if (state.bootstrapFailed) {
            Text(
                text = stringResource(R.string.signup_bootstrap_failed),
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier
                    .fillMaxWidth()
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
            AccentGradientButton(
                onClick = onContinue,
                enabled = true,
                modifier = Modifier.fillMaxWidth(),
                dimWhenDisabled = !state.isSubmitting,
            ) {
                Text(stringResource(R.string.action_continue))
            }
        } else {
            AccentGradientButton(
                onClick = onSignUp,
                enabled = state.canSubmit,
                modifier = Modifier.fillMaxWidth(),
                dimWhenDisabled = !state.isSubmitting,
            ) {
                if (state.isSubmitting) {
                    // 輪はボタンの文字の色（グラデーションの上の白）で描く（輪の既定の主色は、グラデーションの上で見えにくい）
                    CircularProgressIndicator(color = LocalContentColor.current)
                } else {
                    Text(stringResource(R.string.action_create_account))
                }
            }
            Text(
                text = stringResource(R.string.signup_terms_notice),
                style = MaterialTheme.typography.bodySmall,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            // 案内が指すプライバシーポリシーを、登録の前に読めるようにする（レビュー R01）。外のブラウザで開く（開けなければアドレスを出す）
            TextButton(onClick = { openLegalPage(PRIVACY_POLICY_URL) }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.privacy_policy_title))
            }
            // 案内が指す利用規約も、登録の前に読めるようにする（レビュー R02）。外のブラウザで開く（開けなければアドレスを出す）
            TextButton(onClick = { openLegalPage(TERMS_OF_SERVICE_URL) }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.terms_of_service_title))
            }
            unopenedLegalUrl?.let { UnopenedPageAddress(it) }
            // iOS はシートを閉じる×ボタン。Android は 1 つの画面の中で切り替えるので、ログインの画面へ戻るボタンにする
            TextButton(onClick = onBack, enabled = !state.isSubmitting) {
                Text(stringResource(R.string.action_back))
            }
        }
    }
}
