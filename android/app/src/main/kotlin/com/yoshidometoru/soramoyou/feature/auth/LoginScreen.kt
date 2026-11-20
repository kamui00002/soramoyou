// ⭐️ ログイン画面（タスク 8.3・14.4・要件 2.1・2.3・2.7・16.2）（android-ui-ios-parity タスク 11.4・要件 2.1・2.3・2.5・3.9・5.1・5.2・6.3・6.4）
package com.yoshidometoru.soramoyou.feature.auth

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.ui.component.AccentGradientButton
import com.yoshidometoru.soramoyou.ui.component.GlassTextField
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens

/**
 * ログイン画面。状態は [AuthViewModel] が持ち、ここは表示と入力の受け渡しだけをする。
 * 文言は iOS の LoginView と同じ（SessionScreensStringsTest が突き合わせる）。
 *
 * - 新規登録の導線は、[LoginUiState.canCreateAccount] が true のビルドだけで、ログインのボタンの下に出す。M1 では false なので何も出さない。
 *   iOS は最初の画面（WelcomeView）に新規登録とログインを並べるが、Android は最初からログインの画面を出すので、入口をここに置く。
 * - 高さを固定せず、縦に送れるようにして、文字サイズを大きくしてもはみ出さないようにする（要件 16.6）。
 * - 送信中はボタンの中に読み込み中の表示を出す（要件 16.2。iOS も同じ：LoginView.swift:130-133）。
 *
 * ガラスの部品（android-ui-ios-parity 要件 2.1・2.5・5.1）:
 * - 入力欄はガラスの入力欄（GlassTextField）、ログインのボタンはグラデーションのボタン（AccentGradientButton）にする。
 *   どちらも Material 3 の部品を包むので、入力欄のラベルの読み上げとボタンの役割は今のまま（要件 6.3）。新規登録への文字だけのボタンは今のまま
 * - ログインのボタンは、送信中でないときだけ、押せないときに薄くする。送信中も押せなくなる（canSubmit が false）ので、
 *   こうして入力が足りないときだけ薄くする（iOS と同じ。押せない部品の色は比の表の対象外：要件 3.9）
 * - 余白はトークンの名前で書く。端は iOS の LoginView と同じ xl（32dp。作業の前は 24dp）、要素の間も iOS と同じ md（16dp）、
 *   縦は今と同じ xxl（48dp）
 * - 雲は、ログインの前の背景（空と雲）が、空の上・この画面の文字・入力欄・ボタンより後ろに描く（タスク 8.2。この画面では描かない）
 */
@Composable
fun LoginScreen(
    state: LoginUiState,
    onEmailChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onSignIn: () -> Unit,
    onShowSignUp: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = DesignTokens.Spacing.xl, vertical = DesignTokens.Spacing.xxl),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(stringResource(R.string.login_title), style = MaterialTheme.typography.headlineMedium)

        GlassTextField(
            value = state.email,
            onValueChange = onEmailChange,
            label = { Text(stringResource(R.string.login_email_placeholder)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Next),
            modifier = Modifier.fillMaxWidth(),
        )
        GlassTextField(
            value = state.password,
            onValueChange = onPasswordChange,
            label = { Text(stringResource(R.string.login_password_placeholder)) },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { onSignIn() }),
            modifier = Modifier.fillMaxWidth(),
        )

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

        AccentGradientButton(
            onClick = onSignIn,
            enabled = state.canSubmit,
            modifier = Modifier.fillMaxWidth(),
            dimWhenDisabled = !state.isSubmitting,
        ) {
            if (state.isSubmitting) {
                // 輪はボタンの文字の色（グラデーションの上の白）で描く（輪の既定の主色は、グラデーションの上で見えにくい）
                CircularProgressIndicator(color = LocalContentColor.current)
            } else {
                Text(stringResource(R.string.action_sign_in))
            }
        }
        if (state.canCreateAccount) {
            TextButton(onClick = onShowSignUp, enabled = !state.isSubmitting) {
                Text(stringResource(R.string.action_sign_up))
            }
        }
    }
}
