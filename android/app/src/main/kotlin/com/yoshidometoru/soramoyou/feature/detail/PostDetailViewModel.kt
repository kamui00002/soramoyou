// ⭐️ 投稿詳細の画面の状態：投稿 1 件の取得・表示できない投稿・失敗と再試行・自分の投稿の削除・通報とブロック（タスク 10.2・24・29.2・要件 5.1・5.5・10.11・11.1・11.4・11.7・16.2・16.3）
package com.yoshidometoru.soramoyou.feature.detail

import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.write.WriteGate
import com.yoshidometoru.soramoyou.data.repository.AuthorProfileCache
import com.yoshidometoru.soramoyou.data.repository.BlockedUsers
import com.yoshidometoru.soramoyou.data.repository.LikeCountOverride
import com.yoshidometoru.soramoyou.data.repository.LikeStateStore
import com.yoshidometoru.soramoyou.data.repository.ModerationRepository
import com.yoshidometoru.soramoyou.data.repository.PostDeleter
import com.yoshidometoru.soramoyou.data.repository.PostLookup
import com.yoshidometoru.soramoyou.data.repository.PostReadRepository
import com.yoshidometoru.soramoyou.feature.moderation.ModerationAction
import com.yoshidometoru.soramoyou.feature.moderation.ModerationUiState
import com.yoshidometoru.soramoyou.feature.moderation.PostModeration
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 投稿詳細の画面の状態。 */
sealed interface PostDetailUiState {

    /** 投稿を読んでいる（要件 16.2）。 */
    data object Loading : PostDetailUiState

    /** 表示できる投稿。 */
    data class Loaded(val post: PostView) : PostDetailUiState

    /** 削除済み・閲覧の権限が無い・変換できない投稿（要件 5.5）。文言は 1 つで、再試行は出さない。 */
    data object Unavailable : PostDetailUiState

    /**
     * 取得自体の失敗（通信断など）。再試行を出す。
     * @property failedWhileOffline 失敗した時点でオフラインだったか（OfflineContent を出すのはこのときだけ：StateContents.kt の契約）。
     */
    data class Failed(val error: AppError, val failedWhileOffline: Boolean) : PostDetailUiState
}

/**
 * 自分の投稿の削除の状態（タスク 24・要件 10.11）。
 *
 * @property available 削除の操作を出すか。表示できている投稿がいまのユーザーの投稿で、かつ削除の書き込みが有効なビルドのときだけ true。
 * @property confirming 確認のダイアログを出しているか。
 * @property deleting 削除中か（ボタンを押せなくして「削除しています」を出す）。
 * @property error 削除の失敗（「削除に失敗しました」のダイアログで理由を出す）。ダイアログを閉じたら null。
 * @property deleted 削除が終わったか（画面が詳細を閉じる。iOS の `dismiss()`）。
 */
data class PostDeleteUiState(
    val available: Boolean = false,
    val confirming: Boolean = false,
    val deleting: Boolean = false,
    val error: AppError? = null,
    val deleted: Boolean = false,
)

/** 日時の書式。iOS の `date.formatted(date: .abbreviated, time: .shortened)` を日本語の端末で出したものと同じ形（例「2026年10月5日 8:42」）。 */
private val DETAIL_DATE_FORMAT: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy年M月d日 H:mm", Locale.JAPAN)

/**
 * 投稿詳細に出す日時（撮影日時・投稿日時）の文字列。[zone] は端末のタイムゾーン（iOS も端末のタイムゾーンで出す）。
 * タイムゾーンを引数にして、単体テストで書式を固定する。
 */
fun detailDateText(instant: Instant, zone: ZoneId): String = DETAIL_DATE_FORMAT.format(instant.atZone(zone))

/**
 * 投稿詳細の画面の ViewModel（設計書の PostDetailScreen の状態）。作った時点で [postId] の投稿を読む。
 *
 * - 表示できる投稿なら、投稿者の名前とアイコンを [AuthorProfileCache.ensure] で取りに行く（取得を待たずに表示する）。
 * - 表示できる投稿なら、その 1 件のいいね済みを [LikeStateStore.refresh] で確かめる（要件 9.2。iOS の詳細も表示のたびに 1 件だけ確かめる）。
 * - 削除済み・権限なしは、表示できない旨にして記録しない（あり得る状態で、失敗ではないため）。
 * - 変換できない投稿は、表示できない旨にしたうえで `error_occurred` で記録する（設計書のエラー処理の表：1 件飛ばし以外の
 *   変換の失敗は system_error）。`post_decode_failed` は一覧で 1 件飛ばしたときだけのイベントで、取得元の値も iOS と同じ 3 つに
 *   閉じているため使わない。記録には理由の定数だけを載せ、投稿 ID（パス）は載せない。
 * - 取得自体の失敗は記録し、失敗した時点の接続で、エラーかオフラインの表示にする。再試行で読み直す。
 * - 画面名は送らない（iOS が計測している 4 つの画面に投稿詳細は無い：ScreenName）。
 * - ログアウトで状態を捨てる仕組みは持たない。ログアウトするとログイン後のナビゲーションごと捨てられ、この画面には戻れないため。
 * - 自分の投稿で、削除の書き込みが有効なビルドだけ、削除を出す（[deleteState]。要件 10.11）。押すと確認を求め、確かめたら
 *   [PostDeleter] で消す。オフラインの間は押せない（2026-10-11 ユーザー判断）。失敗の記録は PostDeleter が済ませるので、ここでは記録しない。
 *   削除は画面を離れても最後まで進む（PostDeleter が文書の削除から先を取り消さない）。消した投稿は知らせで一覧から除かれる。
 * - 他人の投稿を表示できたときだけ、通報とブロックの操作を出す（[moderationActions]・[moderation]。要件 11.1・11.7。判定は
 *   moderationActionsFor の 1 か所で、フィードと同じ）。ブロックできたら投稿者を知らせ（下に残っているフィードが除く）、
 *   [ModerationUiState.blockedAuthor] で詳細を閉じる合図を出す（iOS の dismiss()：HomeView.swift:1258-1264）。
 *
 * @param likeStateStore いいねの表示状態（アプリ全体で 1 つ）。
 * @param postDeleter 自分の投稿の削除（アプリ全体で 1 つ）。
 * @param writeGate 書き込みの可否。いいねの書き込みが無効なビルドでは、いいねのボタンを押せなくする（[canLike]）。
 *   削除の書き込みが無効なビルドでは、削除を出さない（[PostDeleteUiState.available]）。
 * @param isOnline 接続の有無（NetworkMonitor.isOnline）。
 * @param currentUid いまログインしているユーザーの uid（いなければ null）。投稿を読めたときに、自分の投稿かを決めるのに読む。
 * @param scope この ViewModel の viewModelScope（RootViewModel と同じ理由で外から渡す）。
 * @param moderationRepository 通報・ブロックの書き込み（[moderation] が使う。失敗の記録も行う）。
 * @param blockedUsers ブロックできたことの知らせ（アプリ全体で 1 つ）。
 */
class PostDetailViewModel(
    private val postId: PostId,
    private val repository: PostReadRepository,
    private val authorProfileCache: AuthorProfileCache,
    private val likeStateStore: LikeStateStore,
    private val postDeleter: PostDeleter,
    writeGate: WriteGate,
    private val analytics: AnalyticsFacade,
    val isOnline: StateFlow<Boolean>,
    private val currentUid: () -> Uid?,
    private val scope: CoroutineScope,
    moderationRepository: ModerationRepository,
    blockedUsers: BlockedUsers,
) : ViewModel(scope) {

    private val mutableState = MutableStateFlow<PostDetailUiState>(PostDetailUiState.Loading)

    val state: StateFlow<PostDetailUiState> = mutableState.asStateFlow()

    /** 投稿者の表示（uid → 名前とアイコン）。まだ入っていない uid は読み込み中。 */
    val authors: StateFlow<Map<Uid, AuthorDisplay>> = authorProfileCache.authors

    /** いいね済みの投稿（全画面で共有）。 */
    val liked: StateFlow<Set<PostId>> = likeStateStore.liked

    /** 押した結果のいいね数（全画面で共有）。画面は displayedLikeCount で数を出す。 */
    val likeCountOverrides: StateFlow<Map<PostId, LikeCountOverride>> = likeStateStore.countOverrides

    /** いいねのボタンを押せるか（このビルドでいいねの書き込みが有効か）。 */
    val canLike: Boolean = writeGate.isEnabled(WriteCapability.LIKE)

    /** このビルドで自分の投稿の削除の書き込みが有効か（ビルド時に決まるので、作った時点で 1 回だけ読む）。 */
    private val canDelete: Boolean = writeGate.isEnabled(WriteCapability.POST_DELETE)

    private val mutableDeleteState = MutableStateFlow(PostDeleteUiState())

    /** 自分の投稿の削除の状態。 */
    val deleteState: StateFlow<PostDeleteUiState> = mutableDeleteState.asStateFlow()

    /**
     * 通報・ブロックの操作（要件 11.1〜11.4・11.6・11.7）。画面は [PostModeration.state] でダイアログを出し、
     * [PostModeration.handlers] で操作を呼ぶ。ブロックできたら [ModerationUiState.blockedAuthor] が入る（画面が詳細を閉じる）。
     */
    val moderation: PostModeration = PostModeration(moderationRepository, writeGate, isOnline, currentUid, blockedUsers, scope)

    private val mutableModerationActions = MutableStateFlow<Set<ModerationAction>>(emptySet())

    /** 表示している投稿に出す通報・ブロックの操作。読み込み中・表示できない・失敗・自分の投稿では空。 */
    val moderationActions: StateFlow<Set<ModerationAction>> = mutableModerationActions.asStateFlow()

    /** 読み込み中か（作った直後の取得と再試行の二重の実行を防ぐ）。 */
    private var loading = false

    init {
        load()
    }

    /** 失敗の後に読み直す。読み込み中は何もしない。 */
    fun retry() {
        load()
    }

    /** 表示している投稿のいいねを押す（要件 9.7〜9.9）。表示できる投稿が無ければ何もしない。 */
    fun toggleLike() {
        val post = (mutableState.value as? PostDetailUiState.Loaded)?.post ?: return
        scope.launch { likeStateStore.toggle(post.postId, post.likesCount) }
    }

    /** 削除を押した。確認のダイアログを出す。削除を出していない・削除中・削除の後・オフラインの間は何もしない。 */
    fun requestDelete() {
        mutableDeleteState.update { state ->
            val ready = state.available && !state.deleting && !state.deleted && isOnline.value
            if (ready) state.copy(confirming = true) else state
        }
    }

    /** 確認のダイアログを閉じた（キャンセル・外を押した・戻る操作）。 */
    fun cancelDelete() {
        mutableDeleteState.update { it.copy(confirming = false) }
    }

    /**
     * 確認のダイアログで「削除」を押した。ダイアログを閉じて削除を始める。ダイアログを出していなければ何もしない（二度押しを通さない）。
     * ダイアログを出している間にオフラインになっても止めない（読み直しがサーバーに届かず `Network` の失敗になり、理由を出す）。
     */
    fun confirmDelete() {
        val post = (mutableState.value as? PostDetailUiState.Loaded)?.post ?: return
        var start = false
        mutableDeleteState.update { state ->
            start = state.confirming && !state.deleting
            if (start) state.copy(confirming = false, deleting = true, error = null) else state
        }
        if (!start) return
        scope.launch {
            val result = postDeleter.delete(post.postId)
            mutableDeleteState.update { state ->
                when (result) {
                    is AppResult.Ok -> state.copy(deleting = false, deleted = true)
                    is AppResult.Err -> state.copy(deleting = false, error = result.error)
                }
            }
        }
    }

    /** 削除の失敗のダイアログを閉じた。 */
    fun dismissDeleteError() {
        mutableDeleteState.update { it.copy(error = null) }
    }

    private fun load() {
        if (loading) return
        loading = true
        mutableState.value = PostDetailUiState.Loading
        scope.launch {
            val next = when (val result = repository.fetch(postId)) {
                is AppResult.Err -> {
                    analytics.logError(result.error, CONTEXT)
                    PostDetailUiState.Failed(result.error, failedWhileOffline = !isOnline.value)
                }
                is AppResult.Ok -> when (val lookup = result.value) {
                    is PostLookup.Found -> {
                        scope.launch { authorProfileCache.ensure(setOf(lookup.post.userId)) }
                        scope.launch { likeStateStore.refresh(listOf(lookup.post.postId)) }
                        PostDetailUiState.Loaded(lookup.post)
                    }
                    PostLookup.Deleted, PostLookup.NoPermission -> PostDetailUiState.Unavailable
                    is PostLookup.Unreadable -> {
                        analytics.logError(AppError.Unknown("PostDecode.${lookup.reason}"), CONTEXT)
                        PostDetailUiState.Unavailable
                    }
                }
            }
            loading = false
            mutableState.value = next
            // 削除を出すのは、表示できた投稿がいまのユーザーの投稿のときだけ
            val own = next is PostDetailUiState.Loaded && next.post.userId == currentUid()
            mutableDeleteState.update { it.copy(available = canDelete && own) }
            // 通報・ブロックを出すのは、表示できた投稿が他人の投稿のときだけ（判定はフィードと同じ 1 か所）
            mutableModerationActions.value = if (next is PostDetailUiState.Loaded) moderation.actionsFor(next.post) else emptySet()
        }
    }

    private companion object {
        /** 記録の発生箇所。 */
        const val CONTEXT = "PostDetailViewModel.load"
    }
}
