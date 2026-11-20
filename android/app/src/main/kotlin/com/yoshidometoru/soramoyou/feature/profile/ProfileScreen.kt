// ⭐️ 自分と他人のプロフィールの画面：見出し（名前・アイコン・自己紹介・投稿数）と投稿の一覧（タスク 15.2・要件 10.1〜10.4・16.2・16.3）（android-ui-ios-parity タスク 11.3・要件 2.1・5.1・5.2・8.3）
package com.yoshidometoru.soramoyou.feature.profile

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.feature.feed.FeedContent
import com.yoshidometoru.soramoyou.feature.feed.FeedUiState
import com.yoshidometoru.soramoyou.feature.feed.feedContentOf
import com.yoshidometoru.soramoyou.feature.feed.feedErrorMessageRes
import com.yoshidometoru.soramoyou.ui.component.ButtonLook
import com.yoshidometoru.soramoyou.ui.component.EmptyContent
import com.yoshidometoru.soramoyou.ui.component.ErrorContent
import com.yoshidometoru.soramoyou.ui.component.GlassButton
import com.yoshidometoru.soramoyou.ui.component.LoadingContent
import com.yoshidometoru.soramoyou.ui.component.OfflineContent
import com.yoshidometoru.soramoyou.ui.component.glassSurface
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens
import com.yoshidometoru.soramoyou.ui.theme.LocalSkyPalette

/** 一覧の列の数（iOS のプロフィールの投稿の格子と同じ 3 列）。 */
private const val GRID_COLUMNS = 3

/** 末尾からこの件数以内の投稿が見えたら、続きを読む（フィードの 3 件に、1 行の列の数を掛けた数）。 */
private const val LOAD_MORE_THRESHOLD = 3 * GRID_COLUMNS

/**
 * プロフィールの画面（自分・他人の両方）。上に戻るボタン（と [title]）、その下に見出し、その下に投稿の一覧を出す。
 * 見出しと一覧は別々に読み込むので、片方の失敗でもう片方を隠さない。一覧の表示はフィードと同じ [feedContentOf] で決める。
 *
 * ⚠️ この画面そのもの（Compose の描画・スクロールでの続きの取得・引っ張って更新の手触り）は、実機・エミュレータで未検証。
 *
 * @param title 見出しの上に出す画面の名前（自分のプロフィールだけ「プロフィール」。他人は null で出さない）。
 * @param isOnline 接続の有無。オフラインで失敗した後の表示（OfflineContent）が、接続の回復で再試行を押せるようにするのに使う。
 * @param onRefresh 引っ張って更新・一覧の全面の再試行。
 * @param onRetryHeader 見出しの失敗の再試行。
 * @param onEdit プロフィール編集を開く。null なら編集の導線を出さない（他人のプロフィールと、編集の書き込みが無効なビルド：タスク 16.3）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileScreen(
    title: String?,
    header: ProfileHeaderState,
    posts: FeedUiState,
    isOnline: Boolean,
    onRefresh: () -> Unit,
    onLoadMore: () -> Unit,
    onRetryHeader: () -> Unit,
    onOpenPost: (PostId) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onEdit: (() -> Unit)? = null,
) {
    Column(modifier = modifier.fillMaxSize()) {
        // 上の帯。文字を大きくして 1 行に収まらないときは、順序（戻る → 題 → プロフィール編集）を保ったまま次の行へ折り返す
        // （android-ui-ios-parity 13.1。1 行の Row だと、文字 200% で両側のボタンが幅を取り、題の「プロフィール」が 1 文字ずつ縦に並んだ）。
        // フィードの見出しの行と同じ形：外の FlowRow の子は「戻ると題」と「プロフィール編集」の 2 つにする。
        // 1 行に収まるときは、両端に寄せる並べ方で、戻ると題が左・プロフィール編集が右になり、今の見た目と同じになる
        FlowRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.sm),
            horizontalArrangement = Arrangement.SpaceBetween,
            itemVerticalAlignment = Alignment.CenterVertically,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                // 戻るは文字のボタン（アイコンの部品は依存に無い：投稿詳細と同じ）。端末の戻る操作でも戻れる
                TextButton(onClick = onBack) { Text(stringResource(R.string.action_back)) }
                title?.let { Text(it, style = MaterialTheme.typography.titleLarge) }
            }
            onEdit?.let { TextButton(onClick = it) { Text(stringResource(R.string.action_edit_profile)) } }
        }
        ProfileHeader(header, isOnline, onRetryHeader)
        // 引っ張って更新の表示は、投稿があるときの読み直しだけに出す（投稿が無いときは LoadingContent が出る）
        PullToRefreshBox(
            isRefreshing = posts.isRefreshing && posts.posts.isNotEmpty(),
            onRefresh = onRefresh,
            modifier = Modifier.weight(1f),
        ) {
            // 状態の表示の再試行は、ガラスのボタンで出す（android-ui-ios-parity 要件 2.1。文言と読み上げは同じ）
            when (feedContentOf(posts)) {
                FeedContent.LOADING -> LoadingContent()
                FeedContent.ERROR -> ErrorContent(
                    onRetry = onRefresh,
                    message = stringResource(feedErrorMessageRes(requireNotNull(posts.error))),
                    buttonLook = ButtonLook.GLASS,
                )
                FeedContent.OFFLINE -> OfflineContent(isOnline = isOnline, onRetry = onRefresh, buttonLook = ButtonLook.GLASS)
                FeedContent.EMPTY -> EmptyContent(message = stringResource(R.string.feed_empty_title))
                FeedContent.LIST -> PostGrid(posts, onLoadMore, onOpenPost)
            }
        }
    }
}

/**
 * 見出し。名前・アイコン・投稿数と、あれば自己紹介。読み込み中・失敗は、一覧を隠さないよう見出しの場所だけに小さく出す
 * （StateContents の 4 つは空いている場所いっぱいに広がるので、ここでは使わない）。
 *
 * 見出しの場所を、カードのガラス（色の一式の glass の card・角丸 20dp）で包む（android-ui-ios-parity 要件 2.1・5.1・5.2）。
 * 読み込み中・失敗のときも、同じカードの中に出す（見出しの場所の形が、状態で変わらないように）。
 * - 余白：カードの外は md（16dp）、カードの内側は cardPadding（16dp）。中の要素の間とアイコンの横の間は今の値のまま
 * - ガラスの面は修飾子だけで描くので、意味の節が増えず、読み上げの順は今のまま（要件 6.3）
 * - 失敗の再試行は、ガラスのボタンで出す（オフラインのあいだ押せないときは、ガラスのボタンの決まりどおり全体が薄くなる）
 */
@Composable
private fun ProfileHeader(header: ProfileHeaderState, isOnline: Boolean, onRetry: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(DesignTokens.Spacing.md)
            .glassSurface(LocalSkyPalette.current.glass.card)
            .padding(DesignTokens.Spacing.cardPadding),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
    ) {
        when (header) {
            ProfileHeaderState.Loading -> CircularProgressIndicator(modifier = Modifier.align(Alignment.CenterHorizontally))
            is ProfileHeaderState.Failed -> {
                Text(
                    text = stringResource(if (header.failedWhileOffline) R.string.offline_title else feedErrorMessageRes(header.error)),
                    textAlign = TextAlign.Center,
                    modifier = Modifier.align(Alignment.CenterHorizontally),
                )
                // オフラインのあいだは押せない（接続が戻ったら押せる：OfflineContent と同じ考え方）
                GlassButton(
                    onClick = onRetry,
                    enabled = !header.failedWhileOffline || isOnline,
                    modifier = Modifier.align(Alignment.CenterHorizontally),
                ) { Text(stringResource(R.string.action_retry)) }
            }
            is ProfileHeaderState.Shown -> {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)) {
                    // アイコンは名前の横に出す飾りなので、TalkBack には読ませない（名前を読む）
                    AsyncImage(
                        model = header.author.photoUrl,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .size(72.dp)
                            .clip(CircleShape)
                            .background(MaterialTheme.colorScheme.surfaceVariant),
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(text = header.author.name, style = MaterialTheme.typography.titleLarge)
                        // 投稿数は iOS と同じく数の下に「投稿」（0 未満は 0）
                        Text(text = header.postsCount.coerceAtLeast(0L).toString(), style = MaterialTheme.typography.titleMedium)
                        Text(text = stringResource(R.string.profile_posts_label), style = MaterialTheme.typography.bodySmall)
                    }
                }
                // 自己紹介は空白だけなら出さない（iOS も空なら出さない）
                header.bio?.takeIf { it.isNotBlank() }?.let { Text(text = it, style = MaterialTheme.typography.bodyMedium) }
            }
        }
    }
}

/** 投稿の格子。末尾付近が見えたら [onLoadMore] を呼ぶ。末尾には、続きの読み込み中・失敗と再試行を出す。 */
@Composable
private fun PostGrid(state: FeedUiState, onLoadMore: () -> Unit, onOpenPost: (PostId) -> Unit) {
    val gridState = rememberLazyGridState()
    val nearEnd by remember {
        derivedStateOf {
            val last = gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1
            last >= gridState.layoutInfo.totalItemsCount - 1 - LOAD_MORE_THRESHOLD
        }
    }
    // 件数が増えた・読み込みが終わったときにも判定し直す（FeedScreen と同じ。失敗の後は再試行のボタンを押したときだけ読む）
    LaunchedEffect(nearEnd, state.posts.size, state.isLoadingMore, state.isRefreshing) {
        if (nearEnd && state.error == null) onLoadMore()
    }
    LazyVerticalGrid(columns = GridCells.Fixed(GRID_COLUMNS), state = gridState, modifier = Modifier.fillMaxSize()) {
        items(state.posts, key = { it.postId.value }) { post -> PostTile(post, onClick = { onOpenPost(post.postId) }) }
        item(key = "footer", span = { GridItemSpan(maxLineSpan) }) { GridFooter(state, onLoadMore) }
    }
}

/** 投稿 1 件の正方形のサムネイル。押すと投稿詳細を開く。 */
@Composable
private fun PostTile(post: PostView, onClick: () -> Unit) {
    val description = stringResource(R.string.profile_open_post)
    AsyncImage(
        model = post.coverImage.listUrl,
        // 画像だけのボタンなので、TalkBack には「投稿を開く」と読ませる
        contentDescription = description,
        contentScale = ContentScale.Crop,
        modifier = Modifier
            .padding(1.dp)
            .aspectRatio(1f)
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .clickable(onClick = onClick),
    )
}

/** 格子の末尾（FeedScreen の ListFooter と同じ出し分け。再試行も同じくガラスのボタン：android-ui-ios-parity 要件 2.1）。 */
@Composable
private fun GridFooter(state: FeedUiState, onRetry: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(DesignTokens.Spacing.md),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
    ) {
        val error = state.error
        when {
            state.isLoadingMore -> CircularProgressIndicator()
            error != null -> {
                Text(
                    text = stringResource(if (state.failedWhileOffline) R.string.offline_title else feedErrorMessageRes(error)),
                    textAlign = TextAlign.Center,
                )
                GlassButton(onClick = onRetry) { Text(stringResource(R.string.action_retry)) }
            }
            state.reachedEnd && state.posts.isNotEmpty() ->
                Text(stringResource(R.string.feed_reached_end), style = MaterialTheme.typography.bodySmall)
        }
    }
}
