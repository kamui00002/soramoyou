// ⭐️ 読み込み中・0 件・エラーと再試行・オフラインと再試行の共通の表示（タスク 5.2・要件 16.2・16.3・16.6）（android-ui-ios-parity タスク 10.2・12.3・要件 2.1・2.2・5.1・6.4）
package com.yoshidometoru.soramoyou.ui.component

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens

/*
 * 画面の中身の代わりに出す 4 つの表示。どれも状態を持たず、出すかどうか・接続の有無は画面の側（ViewModel）が決めて渡す。
 * NetworkMonitor を直接は読まない（画面が isOnline を集めて OfflineContent に渡す）。
 *
 * 文字サイズを大きくしてもはみ出さないための作り（要件 16.6）:
 * - 高さを固定しない。ボタンは Material 3 の Button のまま（最小の高さだけが決まっていて、文字が増えれば伸びる）
 * - 文言は行数を制限せず、折り返す
 * - 中身が画面より高くなったら縦に送れる（StateLayout）。収まるときは画面の中央に置く
 * FixedHeightInUiTest が ui/ の下に高さを固定する書き方が無いことを確かめる。
 *
 * 置き方: 一覧の代わりに置くか、PullToRefreshBox の直下に置く。スクロールする親（LazyColumn の item・verticalScroll の中）の
 * 子にはしない（4 つとも空いている場所いっぱいに広がり、中で縦に送るため。理由は StateLayout を参照）。
 * 空いている場所の全体が縦に送れる面になるので、PullToRefreshBox の直下では画面のどこから引いても更新できる（タスク 11.4・要件 4.3）。
 */

/** 通信や処理の完了を待っているあいだの表示（要件 16.2）。iOS の LoadingStateView と同じ「読み込み中...」を出す。 */
@Composable
fun LoadingContent(modifier: Modifier = Modifier) {
    StateLayout(modifier) {
        CircularProgressIndicator()
        StateMessage(stringResource(R.string.state_loading))
    }
}

/**
 * 表示するものが 0 件のときの表示。
 *
 * @param message 0 件であることの説明。画面ごとに具体的な文言（例:「投稿がありません」）を渡す。既定は iOS の既定の 0 件の見出し
 */
@Composable
fun EmptyContent(modifier: Modifier = Modifier, message: String = stringResource(R.string.state_empty_title)) {
    StateLayout(modifier) {
        StateTitle(message)
    }
}

/**
 * 取得や処理に失敗したときの表示と、再試行のボタン。
 *
 * @param onRetry 再試行のボタンを押したときの処理
 * @param message 失敗の説明。既定は iOS の「エラーが発生しました」
 * @param retryEnabled 再試行を押せるか（処理中で押せないときなどに false）
 * @param buttonLook 再試行のボタンの見た目。既定は今の Material 3 の形。ガラスの 5 画面は [ButtonLook.GLASS] を渡す（[RetryButton]）
 */
@Composable
fun ErrorContent(
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
    message: String = stringResource(R.string.state_error_title),
    retryEnabled: Boolean = true,
    buttonLook: ButtonLook = ButtonLook.MATERIAL,
) {
    StateLayout(modifier) {
        StateTitle(message)
        RetryButton(onRetry = onRetry, enabled = retryEnabled, look = buttonLook)
    }
}

/**
 * ネットワークに接続できないときの表示と、再試行のボタン（要件 16.3）。
 * オフラインのあいだは再試行を押せず、接続が戻ると見出しが変わって押せるようになる（[offlineRetryState]）。
 * 見出しは変わったときに TalkBack が読み上げる（ボタンが押せるようになったことに、画面を見ずに気づけるように）。
 *
 * 呼び出し側の契約: この表示を出すのは、取得や処理に失敗した時点で `!isOnline`（オフライン）だったときだけにする。
 * オンラインのまま失敗したら [ErrorContent] を出す（この表示を出すと、接続が切れていないのに「接続が戻りました」と出る）。
 * 出した後は [isOnline] を渡し続け、接続が戻ったら見出しと再試行の可否を切り替える。
 * NetworkMonitor が判断できないときにオンラインとみなす（fail-open）のは、「誤ってオンラインと判断しても、失敗はエラーと
 * 再試行の表示になるだけで済む」ことを前提にしている。この契約がその前提にあたる（監視が働かなくても、押せない再試行の画面にならない）。
 *
 * @param isOnline 接続の有無（NetworkMonitor.isOnline を画面で集めた値）
 * @param onRetry 再試行のボタンを押したときの処理
 * @param buttonLook 再試行のボタンの見た目。既定は今の Material 3 の形。ガラスの 5 画面は [ButtonLook.GLASS] を渡す
 *   （オフラインのあいだ押せない再試行は、ガラスのボタンの決まりどおり全体が薄くなる。[RetryButton]）
 */
@Composable
fun OfflineContent(
    isOnline: Boolean,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
    buttonLook: ButtonLook = ButtonLook.MATERIAL,
) {
    val state = offlineRetryState(isOnline)
    StateLayout(modifier) {
        StateTitle(
            text = stringResource(state.titleRes),
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
        StateMessage(stringResource(state.messageRes))
        RetryButton(onRetry = onRetry, enabled = state.retryEnabled, look = buttonLook)
    }
}

/**
 * 4 つの表示の共通の配置。空いている場所いっぱいを使い、中身を中央に置く。
 * 中身が高すぎるときは、中央に置く代わりに縦に送れるようにする（文字サイズを大きくしたとき）。
 *
 * 縦に送れる面（verticalScroll）を、中身の大きさでなく空いている場所いっぱいに広げる（タスク 11.4）。
 * PullToRefreshBox は、縦に送れる子が送り切れずに余らせた引っ張りを受け取って更新する。送れる面が中身の大きさしか無いと、
 * 文字の周りから引いたときだけ更新され、上の方の余白から引いても何も起きない。
 * - verticalScroll の内側では高さの上限が無くなるので、そこで fillMaxSize を付けても広がらない。代わりに
 *   heightIn(min = 空いている高さ) で「最低でも空いている高さ」にする。収まるときは中央に置かれ、高すぎるときは伸びて送れる
 * - 修飾子の順番が大事：verticalScroll が外、heightIn が内（逆だと送る面は広がるが、中の Column は中身の高さに戻り、縦の中央に置かれない）
 *
 * スクロールする親（LazyColumn の item・verticalScroll の中）の子にしない。そこでは高さに上限が無いので、
 * 空いている場所いっぱいに広がれず、中の縦の送りが入れ子になる（Compose は、高さの上限が無い中で縦の送りを測ると例外を投げる）。
 * 一覧の代わりに置くか、PullToRefreshBox の直下に置く。
 */
@Composable
private fun StateLayout(modifier: Modifier, content: @Composable ColumnScope.() -> Unit) {
    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        // maxHeight は空いている場所の高さ（BoxWithConstraints が親から受け取った上限）
        val availableHeight = maxHeight
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .heightIn(min = availableHeight)
                .padding(DesignTokens.Spacing.lg),
            horizontalAlignment = Alignment.CenterHorizontally,
            // 中身どうしの間隔を 16dp にしたまま、まとまりを縦の中央に置く
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md, Alignment.CenterVertically),
            content = content,
        )
    }
}

/** 見出しの文言。行数は制限せず、中央に揃えて折り返す。 */
@Composable
private fun StateTitle(text: String, modifier: Modifier = Modifier) {
    Text(text = text, modifier = modifier, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
}

/** 補足の文言。行数は制限せず、中央に揃えて折り返す。 */
@Composable
private fun StateMessage(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
    )
}

/**
 * 再試行のボタン（文字を持つので、TalkBack は「再試行、ボタン」と読む）。
 * [look] で見た目だけを出し分ける。どちらも Material 3 の Button なので、役割と文言の読み上げは同じ（要件 6.3）。
 * 見出しの読み上げの領域（オフラインの見出し）はボタンの外にあるので、見た目を変えても今のまま保たれる（要件 6.4）。
 * - [ButtonLook.MATERIAL]：今の Material 3 の塗りのボタン。背景だけの画面と無地の画面（要件 2.2）
 * - [ButtonLook.GLASS]：ガラスのボタン（[GlassButton]）。押せないときは、色を変えずに全体が薄くなる（要件 2.1）
 */
@Composable
private fun RetryButton(onRetry: () -> Unit, enabled: Boolean, look: ButtonLook) {
    when (look) {
        ButtonLook.MATERIAL -> Button(onClick = onRetry, enabled = enabled) { RetryLabel() }
        ButtonLook.GLASS -> GlassButton(onClick = onRetry, enabled = enabled) { RetryLabel() }
    }
}

/** 再試行のボタンの文言。どちらの見た目でも同じ文言を、中央に揃えて折り返す（行数は制限しない）。 */
@Composable
private fun RetryLabel() {
    Text(text = stringResource(R.string.action_retry), textAlign = TextAlign.Center)
}
