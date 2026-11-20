// ⭐️ 投稿詳細の画面：全ての画像・キャプション・ハッシュタグ・投稿者・日時・時間帯・空の種類・いいね・自分の投稿の削除・他人の投稿の通報とブロック（タスク 10.2・18.4・24・29.2・要件 5.1・5.2・5.4・5.5・9.1・10.11・11.1〜11.4・11.6・11.7・16.1・16.2）（android-ui-ios-parity タスク 11.2・要件 2.1・2.6・5.1・5.2・8.3・8.4）
package com.yoshidometoru.soramoyou.feature.detail

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.feature.feed.LikeDisplay
import com.yoshidometoru.soramoyou.feature.feed.feedErrorMessageRes
import com.yoshidometoru.soramoyou.feature.moderation.ModerationAction
import com.yoshidometoru.soramoyou.feature.moderation.ModerationDialogs
import com.yoshidometoru.soramoyou.feature.moderation.ModerationHandlers
import com.yoshidometoru.soramoyou.feature.moderation.ModerationMenuButton
import com.yoshidometoru.soramoyou.feature.moderation.ModerationSendingNotice
import com.yoshidometoru.soramoyou.feature.moderation.ModerationUiState
import com.yoshidometoru.soramoyou.ui.component.ButtonLook
import com.yoshidometoru.soramoyou.ui.component.EmptyContent
import com.yoshidometoru.soramoyou.ui.component.ErrorContent
import com.yoshidometoru.soramoyou.ui.component.LikeButton
import com.yoshidometoru.soramoyou.ui.component.LoadingContent
import com.yoshidometoru.soramoyou.ui.component.OfflineContent
import com.yoshidometoru.soramoyou.ui.component.glassSurface
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens
import com.yoshidometoru.soramoyou.ui.theme.LocalSkyPalette
import java.time.ZoneId

/**
 * 投稿詳細の画面。上に戻るボタン、その下に [state] に応じた表示を出す。
 * 投稿者名・アイコンを押すと、その投稿者のプロフィールへ遷移する（[onOpenAuthor]。要件 5.3・タスク 15.2）。
 *
 * ⚠️ この画面そのもの（Compose の描画・画像の読み込み）は、実機・エミュレータで未検証。
 *
 * 自分の投稿で、削除の書き込みが有効なビルドだけ、戻るの右に「削除」を出す（[deleteState]。タスク 24）。押すと iOS と同じ文言で確認を求め、
 * 失敗したら iOS と同じ見出しのダイアログで理由を出す（HomeView.swift:774-791）。削除中・オフラインの間は押せず、その旨を出す。
 *
 * @param isOnline 接続の有無。オフラインで失敗した後の表示（OfflineContent）が、接続の回復で再試行を押せるようにするのに使う。
 *   削除のボタンも、オフラインの間は押せなくする。
 * @param likes いいねの表示（いいね済み・押した結果の数・押せるか）。
 * @param deleteState 自分の投稿の削除の状態。
 * @param moderation 通報・ブロックの状態（ダイアログと、送っている間の案内を出す。ブロックできたら画面の外が詳細を閉じる）。
 * @param moderationActions 表示している投稿に出す通報・ブロックの操作。他人の投稿を表示できたときだけ空でない（要件 11.7）。
 *   戻るの右に「…」のメニューで出す（iOS の ellipsis.circle の Menu。自分の投稿の削除とは同時に出ない）。
 * @param moderationHandlers 通報・ブロックの操作の入口。
 */
@Composable
fun PostDetailScreen(
    state: PostDetailUiState,
    authors: Map<Uid, AuthorDisplay>,
    isOnline: Boolean,
    likes: LikeDisplay,
    deleteState: PostDeleteUiState,
    onRetry: () -> Unit,
    onToggleLike: () -> Unit,
    onBack: () -> Unit,
    onOpenAuthor: (Uid) -> Unit,
    onRequestDelete: () -> Unit,
    onConfirmDelete: () -> Unit,
    onCancelDelete: () -> Unit,
    onDismissDeleteError: () -> Unit,
    moderation: ModerationUiState,
    moderationActions: Set<ModerationAction>,
    moderationHandlers: ModerationHandlers,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // 戻るは文字のボタン（アイコンの部品は依存に無い：8.3 の設定への入口と同じ理由）。端末の戻る操作でも戻れる
            TextButton(onClick = onBack) {
                Text(stringResource(R.string.action_back))
            }
            Spacer(modifier = Modifier.weight(1f))
            // 削除も文字のボタン（iOS は「…」のメニューの「投稿を削除」。Android はメニューの部品を使わずに直接出す）
            if (deleteState.available) {
                TextButton(onClick = onRequestDelete, enabled = isOnline && !deleteState.deleting && !deleteState.deleted) {
                    Text(stringResource(R.string.action_delete), color = MaterialTheme.colorScheme.error)
                }
            }
            // 他人の投稿の通報・ブロック（自分の投稿・表示できない投稿では moderationActions が空なので出ない）
            (state as? PostDetailUiState.Loaded)?.post?.let { post ->
                ModerationMenuButton(
                    actions = moderationActions,
                    isOnline = isOnline,
                    sending = moderation.sending,
                    onReport = { moderationHandlers.onRequestReport(post) },
                    onBlock = { moderationHandlers.onRequestBlock(post) },
                )
            }
        }
        DeleteNotice(deleteState, isOnline)
        // 通報・ブロックを送っている間の案内（要件 16.2）。削除中の案内と同じ位置・同じ形（削除と通報・ブロックは同じ投稿に同時に出ない）
        ModerationSendingNotice(moderation, modifier = Modifier.padding(horizontal = DesignTokens.Spacing.lg))
        // 状態の表示の再試行は、ガラスのボタンで出す（android-ui-ios-parity 要件 2.1。文言と読み上げは同じ）
        when (state) {
            PostDetailUiState.Loading -> LoadingContent()
            PostDetailUiState.Unavailable -> EmptyContent(message = stringResource(R.string.detail_unavailable))
            is PostDetailUiState.Failed ->
                if (state.failedWhileOffline) {
                    OfflineContent(isOnline = isOnline, onRetry = onRetry, buttonLook = ButtonLook.GLASS)
                } else {
                    ErrorContent(
                        onRetry = onRetry,
                        message = stringResource(feedErrorMessageRes(state.error)),
                        buttonLook = ButtonLook.GLASS,
                    )
                }
            is PostDetailUiState.Loaded -> PostDetail(
                state.post,
                authors[state.post.userId],
                likes,
                onToggleLike = onToggleLike,
                onOpenAuthor = { onOpenAuthor(state.post.userId) },
            )
        }
    }
    DeleteDialogs(deleteState, onConfirm = onConfirmDelete, onCancel = onCancelDelete, onDismissError = onDismissDeleteError)
    ModerationDialogs(moderation, moderationHandlers)
}

/**
 * 削除中・オフラインの案内と、確認・失敗のダイアログ。削除を出していない投稿では何も出さない
 * （失敗のダイアログは削除を出した後にしか起きないので、出していない投稿で出ることはない）。
 */
@Composable
private fun DeleteNotice(state: PostDeleteUiState, isOnline: Boolean) {
    if (!state.available) return
    val notice = when {
        state.deleting -> R.string.detail_deleting
        !isOnline && !state.deleted -> R.string.detail_delete_offline
        else -> null
    }
    notice?.let {
        Text(
            text = stringResource(it),
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(horizontal = DesignTokens.Spacing.lg),
        )
    }
}

/** 削除の確認と、削除の失敗のダイアログ。ダイアログは不透明のまま（ガラスにしない。android-ui-ios-parity 要件 2.6）。 */
@Composable
private fun DeleteDialogs(state: PostDeleteUiState, onConfirm: () -> Unit, onCancel: () -> Unit, onDismissError: () -> Unit) {
    if (state.confirming) {
        // 外を押す・戻る操作はキャンセルと同じ（iOS の alert の「キャンセル」）
        AlertDialog(
            onDismissRequest = onCancel,
            title = { Text(stringResource(R.string.detail_delete_confirm_title)) },
            text = { Text(stringResource(R.string.detail_delete_confirm_message)) },
            confirmButton = {
                TextButton(onClick = onConfirm) {
                    Text(stringResource(R.string.action_delete), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = onCancel) { Text(stringResource(R.string.action_cancel)) } },
        )
    }
    state.error?.let { error ->
        // 理由の文言はフィードの取得の失敗と同じ対応（通信・権限・その他）。iOS は error.userFriendlyMessage
        AlertDialog(
            onDismissRequest = onDismissError,
            title = { Text(stringResource(R.string.detail_delete_failed_title)) },
            text = { Text(stringResource(feedErrorMessageRes(error))) },
            confirmButton = { TextButton(onClick = onDismissError) { Text(stringResource(R.string.action_ok)) } },
        )
    }
}

/**
 * 表示できる投稿の中身。縦に送って全てを見られるようにする（高さを固定しない：要件 16.6）。
 *
 * 投稿者からいいねまでを、カードのガラス（色の一式の glass の card・角丸 20dp）で包む（android-ui-ios-parity 要件 2.1・5.1・5.2）。
 * - 余白：カードの外は md（16dp）、カードの内側は cardPadding（16dp）、中の要素の間は md（16dp。作業の前は 12dp）
 * - ガラスの面は修飾子だけで描くので、意味の節が増えず、押せる塊（投稿者の行）と読み上げの順は今のまま（要件 6.3）
 * - 写真はカードの中身として、ガラスの面より手前に描かれる。半透明の面を写真に重ねない（要件 8.4）。
 *   写真の切り抜き・縦横の比・角丸 12dp は今のまま（要件 8.3。角丸 12dp はトークンに無い外した値として設計書の表にある）
 */
@Composable
private fun PostDetail(post: PostView, author: AuthorDisplay?, likes: LikeDisplay, onToggleLike: () -> Unit, onOpenAuthor: () -> Unit) {
    val zone = ZoneId.systemDefault()
    // 縦に送る面は画面いっぱい。カードはその中で、外の余白の内側に置く（カードの高さは中身の量で決まる）
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(DesignTokens.Spacing.md),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .glassSurface(LocalSkyPalette.current.glass.card)
                .padding(DesignTokens.Spacing.cardPadding),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
        ) {
            // 投稿者（author が null なら読み込み中なので名前を出さない）。アイコンは名前の横に出す飾りなので TalkBack には読ませない。
            // 名前とアイコンの行ごと押せる（要件 5.3。clickable はボタンの役割を TalkBack に伝え、名前を読む）
            Row(
                modifier = Modifier.clickable(onClick = onOpenAuthor),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
            ) {
                AsyncImage(
                    model = author?.photoUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                )
                Text(text = author?.name.orEmpty(), style = MaterialTheme.typography.titleMedium)
            }
            // 全ての画像を表示順に（images は order の昇順に並んでいる）。一覧と違い、サムネイルでなく本体を読む
            post.images.forEach { image ->
                AsyncImage(
                    model = image.url,
                    contentDescription = null,
                    contentScale = ContentScale.FillWidth,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(MaterialTheme.colorScheme.surfaceVariant),
                )
            }
            post.caption?.let { Text(text = it, style = MaterialTheme.typography.bodyLarge) }
            // ハッシュタグは # を外して保存されている（設計書：ハッシュタグ）ので、表示で付ける
            post.hashtags?.takeIf { it.isNotEmpty() }?.let { tags ->
                Text(text = tags.joinToString(" ") { "#$it" }, color = MaterialTheme.colorScheme.primary)
            }
            // 空の種類・時間帯は iOS と同じ表示名（:contract の displayName。UiStringsTest が iOS と一致を確かめている）
            post.skyType?.let { Text(text = it.displayName, style = MaterialTheme.typography.bodyMedium) }
            post.timeOfDay?.let { Text(text = it.displayName, style = MaterialTheme.typography.bodyMedium) }
            post.capturedAt?.let {
                Text(text = stringResource(R.string.detail_captured_at, detailDateText(it, zone)), style = MaterialTheme.typography.bodySmall)
            }
            post.createdAt?.let {
                Text(text = stringResource(R.string.detail_posted_at, detailDateText(it, zone)), style = MaterialTheme.typography.bodySmall)
            }
            LikeButton(
                isLiked = post.postId in likes.liked,
                count = likes.countOf(post),
                enabled = likes.canLike,
                onClick = onToggleLike,
            )
        }
    }
}
