// ⭐️ ブロック中のユーザーの画面の状態：一覧の取得・失敗と再試行・解除（タスク 29.2・要件 11.5・11.6・16.2・16.3）
package com.yoshidometoru.soramoyou.feature.settings

import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.BlockedUserView
import com.yoshidometoru.soramoyou.data.repository.ModerationRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** ブロック中のユーザーの画面の中身。 */
sealed interface BlockListContent {

    /** 一覧を読んでいる（要件 16.2）。 */
    data object Loading : BlockListContent

    /** 読めた一覧（ブロックした順）。空なら「ブロック中のユーザーはいません」を出す。 */
    data class Loaded(val users: List<BlockedUserView>) : BlockListContent

    /**
     * 一覧を読めなかった。再試行を出す。
     * @property failedWhileOffline 失敗した時点でオフラインだったか（OfflineContent を出すのはこのときだけ：StateContents.kt の契約）。
     */
    data class Failed(val error: AppError, val failedWhileOffline: Boolean) : BlockListContent
}

/**
 * ブロック中のユーザーの画面の状態。
 *
 * @property content 一覧の中身。
 * @property unblocking 解除を送っているユーザー（その行の解除のボタンを押せなくする。二重に送らない）。
 * @property unblockError 直前の解除の失敗（「ブロックの解除に失敗しました」のダイアログで理由を出す）。閉じたら null。
 */
data class BlockListUiState(
    val content: BlockListContent = BlockListContent.Loading,
    val unblocking: Set<Uid> = emptySet(),
    val unblockError: AppError? = null,
)

/**
 * 設定の下の「ブロック中のユーザー」の画面の ViewModel（設計書の BlockListScreen の状態・要件 11.5）。作った時点で一覧を読む。
 * iOS 版には同じ画面が無い（Android だけ。ブロックの解除の導線が要件 11.5 にあるため）。
 *
 * - 一覧は [ModerationRepository.blockedProfiles]（ブロックした順・名前とアイコンは公開プロフィールから、読めない人は代替表示）。
 *   読めなかったときの記録は BlockListRepository が済ませているので、ここでは記録しない（記録の窓口を持たない）
 * - 解除は [ModerationRepository.unblock]（`blockedUserIds` から arrayRemove で 1 人）。届いたら一覧から除き、失敗したら一覧に残して
 *   理由を出す（要件 11.6）。失敗の記録は ModerationRepository が済ませる（書き込みの待ちの後に記録するので、送った後に画面を
 *   離れても待ちは取り消さない）。確認は出さない（もう一度ブロックすれば戻せるため。
 *   iOS には解除の画面自体が無く、比べる前例が無い）
 * - オフラインの間は解除を送らない（画面は解除のボタンを押せなくして案内を出す）。Firestore の書き込みはオフラインでは失敗せずに
 *   接続を待つので、押せると止まって見える（自分の投稿の削除と同じ扱い）
 * - 解除してもフィードには知らせない。フィードは次の読み直しでブロック中の一覧を読み直して、その人の投稿を戻す（iOS と同じ）
 * - 画面名は送らない（iOS が計測している 4 つの画面に無い：ScreenName。設計書 Q10）
 * - ログアウトで状態を捨てる仕組みは持たない。ログアウトするとログイン後のナビゲーションごと捨てられ、この画面には戻れないため
 *
 * @param isOnline 接続の有無（NetworkMonitor.isOnline）。
 * @param scope この ViewModel の viewModelScope（RootViewModel と同じ理由で外から渡す）。
 */
class BlockListViewModel(
    private val repository: ModerationRepository,
    val isOnline: StateFlow<Boolean>,
    private val scope: CoroutineScope,
) : ViewModel(scope) {

    private val mutableState = MutableStateFlow(BlockListUiState())

    val state: StateFlow<BlockListUiState> = mutableState.asStateFlow()

    /** 一覧を読み込み中か（作った直後の取得と再試行の二重の実行を防ぐ）。 */
    private var loading = false

    init {
        load()
    }

    /** 一覧の失敗の後に読み直す。読み込み中は何もしない。 */
    fun retry() {
        load()
    }

    /**
     * [uid] のブロックを解除する。一覧に無い・送信中・オフラインのときは何もしない。
     * 届いたら一覧から除き、失敗したら一覧に残して [BlockListUiState.unblockError] に理由を入れる。
     */
    fun unblock(uid: Uid) {
        if (!isOnline.value) return
        var start = false
        mutableState.update { state ->
            val listed = (state.content as? BlockListContent.Loaded)?.users?.any { it.uid == uid } == true
            start = listed && uid !in state.unblocking
            if (start) state.copy(unblocking = state.unblocking + uid) else state
        }
        if (!start) return
        scope.launch {
            // 書き込みの待ちは取り消さない。解除を押した後に画面を離れると scope は取り消され、待ちが取り消しで抜けると、
            // ModerationRepository が待ちの後に行う失敗の記録が走らない。通報・ブロック（PostModeration）と同じく NonCancellable で
            // 最後まで待つ。状態の更新はその後（取り消し済みなら捨てられるが、見る画面はもう無い）
            val result = withContext(NonCancellable) { repository.unblock(uid) }
            mutableState.update { state ->
                val rest = state.unblocking - uid
                when (result) {
                    is AppResult.Ok -> state.copy(content = state.content.without(uid), unblocking = rest)
                    is AppResult.Err -> state.copy(unblocking = rest, unblockError = result.error)
                }
            }
        }
    }

    /** 解除の失敗のダイアログを閉じた。 */
    fun dismissUnblockError() {
        mutableState.update { it.copy(unblockError = null) }
    }

    private fun load() {
        if (loading) return
        loading = true
        mutableState.update { it.copy(content = BlockListContent.Loading) }
        scope.launch {
            val next = when (val result = repository.blockedProfiles()) {
                is AppResult.Ok -> BlockListContent.Loaded(result.value)
                is AppResult.Err -> BlockListContent.Failed(result.error, failedWhileOffline = !isOnline.value)
            }
            loading = false
            mutableState.update { it.copy(content = next) }
        }
    }

    /** 一覧から [uid] を除いた中身（一覧でなければそのまま。解除の途中で読み直しが始まったときは、読み直しの結果に任せる）。 */
    private fun BlockListContent.without(uid: Uid): BlockListContent =
        if (this is BlockListContent.Loaded) BlockListContent.Loaded(users.filterNot { it.uid == uid }) else this
}
