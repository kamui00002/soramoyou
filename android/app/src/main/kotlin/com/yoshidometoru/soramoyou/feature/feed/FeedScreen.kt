// ⭐️ フィードの画面：公開投稿の一覧・引っ張って更新・末尾で続き・状態ごとの表示・通報とブロック（タスク 9.4・29.2・要件 4.1〜4.9・4.12・4.13・9.1・11.1〜11.4・11.6・11.7・16.2・16.3）（android-ui-ios-parity タスク 10.3・11.1・要件 2.1・3.7・5.1・5.2・7.1・7.2・8.3・8.4）
package com.yoshidometoru.soramoyou.feature.feed

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
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
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.repository.LikeCountOverride
import com.yoshidometoru.soramoyou.data.repository.displayedLikeCount
import com.yoshidometoru.soramoyou.feature.moderation.ModerationAction
import com.yoshidometoru.soramoyou.feature.moderation.ModerationDialogs
import com.yoshidometoru.soramoyou.feature.moderation.ModerationHandlers
import com.yoshidometoru.soramoyou.feature.moderation.ModerationMenuButton
import com.yoshidometoru.soramoyou.feature.moderation.ModerationSendingNotice
import com.yoshidometoru.soramoyou.feature.moderation.ModerationUiState
import com.yoshidometoru.soramoyou.ui.component.ButtonLook
import com.yoshidometoru.soramoyou.ui.component.EmptyContent
import com.yoshidometoru.soramoyou.ui.component.ErrorContent
import com.yoshidometoru.soramoyou.ui.component.GlassButton
import com.yoshidometoru.soramoyou.ui.component.LikeButton
import com.yoshidometoru.soramoyou.ui.component.LoadingContent
import com.yoshidometoru.soramoyou.ui.component.OfflineContent
import com.yoshidometoru.soramoyou.ui.component.glassSurface
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens
import com.yoshidometoru.soramoyou.ui.theme.LocalSkyPalette

/** 末尾からこの件数以内の投稿が見えたら、続きを読む。 */
private const val LOAD_MORE_THRESHOLD = 3

/**
 * フィードの画面。見出し（「ホーム」）と、自分のプロフィール（タスク 15.2）・設定への入口の下に、[feedContentOf] で決めた表示を出す。
 * 表示は [state] と [authors] から作るだけで、取得の判断は ViewModel が持つ（単体テストは FeedViewModelTest・FeedContentTest）。
 *
 * ⚠️ この画面そのもの（Compose の描画・スクロールでの続きの取得・引っ張って更新の手触り）は、実機・エミュレータで未検証。
 *
 * @param isOnline 接続の有無。オフラインで失敗した後の表示（OfflineContent）が、接続の回復で再試行を押せるようにするのに使う。
 * @param likes いいねの表示（いいね済み・押した結果の数・押せるか）。
 * @param moderation 通報・ブロックの状態（ダイアログと、送っている間の案内を出す）。
 * @param moderationActionsFor 投稿ごとに出す通報・ブロックの操作（自分の投稿には空：要件 11.7）。投稿の右上の「…」のメニューに出す。
 * @param moderationHandlers 通報・ブロックの操作の入口。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FeedScreen(
    state: FeedUiState,
    authors: Map<Uid, AuthorDisplay>,
    isOnline: Boolean,
    likes: LikeDisplay,
    onRefresh: () -> Unit,
    onLoadMore: () -> Unit,
    onToggleLike: (PostView) -> Unit,
    onOpenProfile: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenPost: (PostId) -> Unit,
    moderation: ModerationUiState,
    moderationActionsFor: (PostView) -> Set<ModerationAction>,
    moderationHandlers: ModerationHandlers,
    modifier: Modifier = Modifier,
    onCompose: (() -> Unit)? = null,
) {
    // 投稿ごとの「…」のメニュー（他人の投稿にだけ出る。オフラインと送信中は押せない）
    val moderationMenu: @Composable (PostView) -> Unit = { post ->
        ModerationMenuButton(
            actions = moderationActionsFor(post),
            isOnline = isOnline,
            sending = moderation.sending,
            onReport = { moderationHandlers.onRequestReport(post) },
            onBlock = { moderationHandlers.onRequestBlock(post) },
        )
    }
    Column(modifier = modifier.fillMaxSize()) {
        // 見出しの行。横の余白は投稿のカードと同じ画面の端の余白にして、見出しとカードの左端をそろえる（iOS の HomeView も screenMargin）。
        // 文字を大きくして 1 行に収まらないときは、順序（見出し → 投稿 → プロフィール → 設定）を保ったまま次の行へ折り返す
        // （android-ui-ios-parity 要件 7.1・7.2。作業の前の 1 行の並びでは、文字 200% で「設定」が画面の右の外に切れていた）。
        // - 外の FlowRow の子は「見出し」と「ボタンの塊」の 2 つにする。1 行に収まるときは、両端に寄せる並べ方で
        //   見出しが左・ボタンの塊が右になり、今の見た目と同じになる（4 つを平らに並べると、ボタンどうしの間も広がってしまう）
        // - ボタンの塊も FlowRow にする。塊だけで画面の幅を超えるときは、塊の中でも順序のまま折り返す
        FlowRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.screenMargin, vertical = DesignTokens.Spacing.sm),
            horizontalArrangement = Arrangement.SpaceBetween,
            itemVerticalAlignment = Alignment.CenterVertically,
        ) {
            Text(stringResource(R.string.feed_title), style = MaterialTheme.typography.headlineSmall)
            // 自分のプロフィールへの入口は、ボトムナビゲーションが無いあいだは設定の隣に置く（2026-10-06 ユーザー判断）
            FlowRow(itemVerticalAlignment = Alignment.CenterVertically) {
                // 投稿の導線は、投稿の書き込みが有効なビルドだけに出す（null なら出さない。プロフィールの編集の onEdit と同じ形）
                if (onCompose != null) {
                    TextButton(onClick = onCompose) { Text(stringResource(R.string.compose_title)) }
                }
                TextButton(onClick = onOpenProfile) { Text(stringResource(R.string.profile_title)) }
                TextButton(onClick = onOpenSettings) { Text(stringResource(R.string.settings_title)) }
            }
        }
        // 通報・ブロックを送っている間の案内（要件 16.2）。送信中は全ての投稿の「…」の項目が押せなくなるので、その理由も兼ねて一覧の上に出す。
        // 横の余白は見出しの行と同じ画面の端の余白
        ModerationSendingNotice(moderation, modifier = Modifier.padding(horizontal = DesignTokens.Spacing.screenMargin))
        // 引っ張って更新の表示は、投稿があるときの読み直しだけに出す（投稿が無いときは LoadingContent が出る）
        PullToRefreshBox(
            isRefreshing = state.isRefreshing && state.posts.isNotEmpty(),
            onRefresh = onRefresh,
            modifier = Modifier.fillMaxSize(),
        ) {
            // 状態の表示の再試行は、ガラスのボタンで出す（android-ui-ios-parity 要件 2.1。文言と読み上げは同じ）
            when (feedContentOf(state)) {
                FeedContent.LOADING -> LoadingContent()
                FeedContent.ERROR -> ErrorContent(
                    onRetry = onRefresh,
                    message = stringResource(feedErrorMessageRes(requireNotNull(state.error))),
                    buttonLook = ButtonLook.GLASS,
                )
                FeedContent.OFFLINE -> OfflineContent(isOnline = isOnline, onRetry = onRefresh, buttonLook = ButtonLook.GLASS)
                FeedContent.EMPTY -> EmptyContent(message = stringResource(R.string.feed_empty_title))
                FeedContent.LIST -> PostList(state, authors, likes, onLoadMore, onToggleLike, onOpenPost, moderationMenu)
            }
        }
    }
    ModerationDialogs(moderation, moderationHandlers)
}

/** 投稿の一覧。末尾付近が見えたら [onLoadMore] を呼ぶ（要件 4.2）。末尾には、続きの読み込み中・失敗と再試行・続きなしを出す。 */
@Composable
private fun PostList(
    state: FeedUiState,
    authors: Map<Uid, AuthorDisplay>,
    likes: LikeDisplay,
    onLoadMore: () -> Unit,
    onToggleLike: (PostView) -> Unit,
    onOpenPost: (PostId) -> Unit,
    moderationMenu: @Composable (PostView) -> Unit,
) {
    val listState = rememberLazyListState()
    val nearEnd by remember {
        derivedStateOf {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1
            last >= listState.layoutInfo.totalItemsCount - 1 - LOAD_MORE_THRESHOLD
        }
    }
    // 件数が増えた・読み込みが終わったときにも判定し直す（末尾が見えたままでも続きを読む。0 件の先読みを上限で止めたときの経路）。
    // 失敗の後は自動で読み直さない（再試行のボタンを押したときだけ）
    LaunchedEffect(nearEnd, state.posts.size, state.isLoadingMore, state.isRefreshing) {
        if (nearEnd && state.error == null) onLoadMore()
    }
    // 余白は iOS のフィード（HomeView の LazyVStack）と同じ選び方にする（android-ui-ios-parity 要件 5.1）。
    // 画面の端は screenMargin（20dp）・上は sm（8dp）・カードの間は lg（24dp）。末尾の表示も同じ端の余白の内側に置く。
    // ⚠️ 上の sm とカードの間の lg は、contentPadding と spacedBy に入れず、各カード（と末尾）の外側の上の余白で付ける。
    //    見た目は同じで、iOS と同じく中身と一緒に流れる。一覧の設定で付けると、TalkBack が一覧を 1 ページ送った後に
    //    通り過ぎたカードが一覧の上に残り、TalkBack がそこにフォーカスして何も読まない（android-ui-ios-parity タスク 11.1・13.5）。
    //    - 上の contentPadding があると、1 ページ送る量が「一覧の高さ − 上の余白」になり、前のカードの下の帯が残る
    //    - spacedBy があると、間がカードの後ろに付くので、カードを通り過ぎても間の分だけそのカードが先頭の項目として残る
    //    すき間用の項目を足すと一覧の件数の読み上げ（「6 items」など）が変わるので、項目は足さない
    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            start = DesignTokens.Spacing.screenMargin,
            end = DesignTokens.Spacing.screenMargin,
        ),
    ) {
        itemsIndexed(state.posts, key = { _, post -> post.postId.value }) { index, post ->
            PostCard(
                post,
                authors[post.userId],
                likes,
                onToggleLike = { onToggleLike(post) },
                onClick = { onOpenPost(post.postId) },
                moderationMenu = { moderationMenu(post) },
                // 1 枚目は一覧の上の余白、2 枚目から後はカードの間（上の注記）。ガラスの面と押せる塊の外に付けるので、
                // カードの大きさと押せる範囲は変わらない
                modifier = Modifier.padding(top = if (index == 0) DesignTokens.Spacing.sm else DesignTokens.Spacing.lg),
            )
        }
        item(key = "footer") { ListFooter(state, onLoadMore, modifier = Modifier.padding(top = DesignTokens.Spacing.lg)) }
    }
}

/**
 * 一覧の末尾。StateContents の 4 つは一覧の中に置けない（StateContents.kt の注記）ので、ここでは素の部品で書く。
 * 再試行は、状態の表示と同じくガラスのボタンで出す（android-ui-ios-parity 要件 2.1）。
 */
@Composable
private fun ListFooter(state: FeedUiState, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(DesignTokens.Spacing.md),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
    ) {
        val error = state.error
        when {
            state.isLoadingMore -> {
                CircularProgressIndicator()
                Text(stringResource(R.string.state_loading), style = MaterialTheme.typography.bodySmall)
            }
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

/**
 * 投稿 1 件。投稿者の名前とアイコン（[author] が null なら読み込み中なので名前を出さない）と、その右端の「…」のメニュー
 * （[moderationMenu]。他人の投稿にだけ出る）、先頭の画像（サムネイル優先）、複数枚の表示、いいねのボタンといいね数（0 未満は 0：要件 9.1）。
 *
 * 投稿の全体を、投稿のカードのガラス（色の一式の glass の postCard・角丸 20dp）で包む（android-ui-ios-parity 要件 2.1・5.1・5.2）。
 * - 修飾子の順番：ガラスの面（切り抜き・面・縁）→ 押せる塊 → 内側の余白（cardPadding・16dp）。面の切り抜きの後に押せる塊を置くので、
 *   押したときの波紋もカードの角丸で切れる。内側の余白は押せる塊の内側なので、余白を含むカード全体が押せる（今と同じ 1 つの押せる塊）
 * - [modifier]（一覧の上の余白・カードの間）は、ガラスの面より外側に付く
 * - 写真・名前・ボタンはカードの中身として、ガラスの面より手前に描かれる。半透明の面を写真に重ねない（要件 8.4）。
 *   写真の切り抜き・縦横の比・角丸 12dp は今のまま（要件 8.3。角丸 12dp はトークンに無い外した値として設計書の表にある）
 */
@Composable
private fun PostCard(
    post: PostView,
    author: AuthorDisplay?,
    likes: LikeDisplay,
    onToggleLike: () -> Unit,
    onClick: () -> Unit,
    moderationMenu: @Composable () -> Unit,
    modifier: Modifier = Modifier,
) {
    // カード全体を押すと投稿詳細を開く（要件 5.1）。clickable はボタンの役割を TalkBack に伝える。
    // ガラスの面は修飾子だけで描くので、意味の節が増えず、押せる塊と読み上げは今のまま（android-ui-ios-parity 要件 6.3）
    Column(
        modifier = modifier
            .fillMaxWidth()
            .glassSurface(LocalSkyPalette.current.glass.postCard)
            .clickable(onClick = onClick)
            .padding(DesignTokens.Spacing.cardPadding),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
        ) {
            // アイコンは名前の横に出す飾りなので、TalkBack には読ませない（名前を読む）
            AsyncImage(
                model = author?.photoUrl,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(32.dp)
                    .clip(CircleShape)
                    .background(MaterialTheme.colorScheme.surfaceVariant),
            )
            // 名前が残りの幅を取り、「…」のメニューを右端に寄せる（ボタンを押してもカードの「詳細を開く」は動かない）
            Text(text = author?.name.orEmpty(), style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            moderationMenu()
        }
        Box(modifier = Modifier.padding(top = DesignTokens.Spacing.sm)) {
            AsyncImage(
                model = post.coverImage.listUrl,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(1f)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant),
            )
            // 複数枚の表示は文字なので、TalkBack はそのまま「3枚」と読む
            if (post.hasMultipleImages) {
                val count = stringResource(R.string.feed_image_count, post.images.size)
                // 札の色は色の一式から読む（黒 60% の面に白い文字。白い写真と黒い写真のどちらの上でも 4.5 を保つ。android-ui-ios-parity 要件 3.7）
                val badge = LocalSkyPalette.current.photoBadge
                // 札の角丸 8dp と、札の外と中の余白は今の値のまま、トークンの名前で書く（android-ui-ios-parity 要件 5.1・5.2）
                Surface(
                    shape = RoundedCornerShape(DesignTokens.Radius.sm),
                    color = badge.scrim,
                    contentColor = badge.text,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(DesignTokens.Spacing.sm),
                ) {
                    Text(
                        text = count,
                        modifier = Modifier.padding(horizontal = DesignTokens.Spacing.sm, vertical = DesignTokens.Spacing.xs),
                    )
                }
            }
        }
        // ボタンを押してもカードの「詳細を開く」は動かない（中のボタンが押下を受け取る）
        LikeButton(
            isLiked = post.postId in likes.liked,
            count = likes.countOf(post),
            enabled = likes.canLike,
            onClick = onToggleLike,
        )
    }
}

/**
 * 画面に出すいいねの表示（タスク 18.4）。LikeStateStore の状態を画面へ渡すためにまとめたもの。
 *
 * @property liked いいね済みの投稿。
 * @property countOverrides 押した結果のいいね数。
 * @property canLike いいねのボタンを押せるか（いいねの書き込みが有効なビルドか）。
 */
data class LikeDisplay(
    val liked: Set<PostId>,
    val countOverrides: Map<PostId, LikeCountOverride>,
    val canLike: Boolean,
) {
    /** [post] に出すいいね数（押した結果の数があればそれ、0 未満は 0。要件 9.1）。 */
    fun countOf(post: PostView): Long = displayedLikeCount(countOverrides[post.postId], post.likesCount)
}
