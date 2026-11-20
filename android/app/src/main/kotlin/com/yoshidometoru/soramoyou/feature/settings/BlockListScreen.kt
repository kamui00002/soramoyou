// ⭐️ ブロック中のユーザーの画面：一覧・解除・状態ごとの表示（タスク 29.2・要件 11.5・11.6・16.2・16.3・16.5・16.6）（android-ui-ios-parity タスク 12.1・要件 5.1）
package com.yoshidometoru.soramoyou.feature.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.BlockedUserView
import com.yoshidometoru.soramoyou.feature.feed.feedErrorMessageRes
import com.yoshidometoru.soramoyou.ui.component.EmptyContent
import com.yoshidometoru.soramoyou.ui.component.ErrorContent
import com.yoshidometoru.soramoyou.ui.component.LoadingContent
import com.yoshidometoru.soramoyou.ui.component.OfflineContent
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens

/**
 * 設定の下の「ブロック中のユーザー」の画面（設計書の BlockListScreen・要件 11.5）。上に戻るボタンと見出し、その下に [state] に応じた表示を出す。
 * 1 人ずつ名前とアイコンと「ブロックを解除」を並べる。解除の失敗はダイアログで理由を出す（要件 11.6）。
 * バナー広告は出さない（設定の下の画面：SoramoyouApp.kt の ROUTES_WITHOUT_BANNER）。
 *
 * ⚠️ この画面そのもの（Compose の描画・画像の読み込み・文字サイズ 200%）は、実機で未検証（33.x）。
 *   エミュレータでは、android-ui-ios-parity 13.1 で文字 100%・200% の描画を撮って確かめた（アイコンの画像は種まきのデータに無く、読み込みは見ていない）。
 *
 * @param isOnline 接続の有無。オフラインで失敗した後の表示（OfflineContent）が接続の回復で再試行を押せるようにするのと、
 *   オフラインの間は解除のボタンを押せなくするのに使う。
 */
@Composable
fun BlockListScreen(
    state: BlockListUiState,
    isOnline: Boolean,
    onRetry: () -> Unit,
    onUnblock: (Uid) -> Unit,
    onDismissUnblockError: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxSize()) {
        // 戻るは文字のボタン（投稿詳細と同じ。端末の戻る操作でも戻れる）
        TextButton(onClick = onBack, modifier = Modifier.padding(horizontal = DesignTokens.Spacing.sm)) {
            Text(stringResource(R.string.action_back))
        }
        Text(
            text = stringResource(R.string.blocked_users_title),
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.padding(horizontal = DesignTokens.Spacing.lg, vertical = DesignTokens.Spacing.sm),
        )
        when (val content = state.content) {
            BlockListContent.Loading -> LoadingContent()
            is BlockListContent.Failed ->
                if (content.failedWhileOffline) {
                    OfflineContent(isOnline = isOnline, onRetry = onRetry)
                } else {
                    ErrorContent(onRetry = onRetry, message = stringResource(feedErrorMessageRes(content.error)))
                }
            is BlockListContent.Loaded ->
                if (content.users.isEmpty()) {
                    EmptyContent(message = stringResource(R.string.blocked_users_empty))
                } else {
                    BlockedUserList(content.users, state.unblocking, isOnline, onUnblock)
                }
        }
    }
    state.unblockError?.let { error ->
        AlertDialog(
            onDismissRequest = onDismissUnblockError,
            title = { Text(stringResource(R.string.unblock_failed_title)) },
            text = { Text(stringResource(feedErrorMessageRes(error))) },
            confirmButton = { TextButton(onClick = onDismissUnblockError) { Text(stringResource(R.string.action_ok)) } },
        )
    }
}

/** ブロック中のユーザーの一覧。オフラインの間は、解除できない旨を一覧の上に出す。 */
@Composable
private fun BlockedUserList(users: List<BlockedUserView>, unblocking: Set<Uid>, isOnline: Boolean, onUnblock: (Uid) -> Unit) {
    Column(modifier = Modifier.fillMaxSize()) {
        if (!isOnline) {
            Text(
                text = stringResource(R.string.unblock_offline),
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = DesignTokens.Spacing.lg),
            )
        }
        LazyColumn(modifier = Modifier.fillMaxSize()) {
            items(users, key = { it.uid.value }) { user ->
                BlockedUserRow(user, enabled = isOnline && user.uid !in unblocking, onUnblock = { onUnblock(user.uid) })
            }
        }
    }
}

/** 名前に残す最小の幅の文字数。これより狭くなるときは「ブロックを解除」を次の行へ回す（android-ui-ios-parity 13.1）。 */
private const val NAME_MIN_CHARS = 4

/**
 * 1 人分の行。アイコン・名前（読めない人は「ユーザー」）・「ブロックを解除」。
 * 名前は折り返して全てを出し、ボタンは押せる大きさのまま横に置く（高さを固定しない：要件 16.6）。
 * 名前に [NAME_MIN_CHARS] 文字ぶんの幅も残せないとき（文字 200% など）は、ボタンを次の行へ回す（android-ui-ios-parity 13.1）。
 */
@Composable
private fun BlockedUserRow(user: BlockedUserView, enabled: Boolean, onUnblock: () -> Unit) {
    // 名前の最小の幅は、名前の文字の大きさ（sp）の 4 文字ぶん。sp から dp に直すので、端末の文字の大きさに合わせて広がる
    val nameMinWidth = with(LocalDensity.current) { (MaterialTheme.typography.titleMedium.fontSize * NAME_MIN_CHARS).toDp() }
    // 1 行の Row だと、文字 200% で「ブロックを解除」が幅を取り、名前が 1 文字ずつ縦に並んだ（android-ui-ios-parity 13.1）。
    // FlowRow は weight の付いた子を、最小の幅で行に入るかを決める。そこで「アイコンと名前」の塊に、残りの幅をもらう weight を付け、
    // 名前には最小の幅を付ける。名前に 4 文字ぶん残せるときは今と同じ 1 行（名前は残りの幅で折り返す）、残せないときはボタンが次の行へ回る
    FlowRow(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DesignTokens.Spacing.lg, vertical = DesignTokens.Spacing.sm),
        // アイコン・名前・ボタンの間は md（16dp）。作業の前の 12dp はトークンに無いので、16dp に寄せた（android-ui-ios-parity 要件 5.1）
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
        itemVerticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier.weight(1f),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
        ) {
            // アイコンは名前の横に出す飾りなので、TalkBack には読ませない（名前を読む）
            AsyncImage(
                model = user.author.photoUrl,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceVariant),
            )
            Text(
                text = user.author.name,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.widthIn(min = nameMinWidth),
            )
        }
        OutlinedButton(onClick = onUnblock, enabled = enabled) {
            Text(stringResource(R.string.action_unblock))
        }
    }
}
