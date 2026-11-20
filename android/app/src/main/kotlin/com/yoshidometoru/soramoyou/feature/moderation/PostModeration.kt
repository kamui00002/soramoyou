// ⭐️ 投稿の通報とブロックの操作の状態：出す投稿の判定・理由の選択・ブロックの確認・送信・完了と失敗の表示（タスク 29.2・要件 11.1〜11.4・11.6・11.7）
package com.yoshidometoru.soramoyou.feature.moderation

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.model.ReportReason
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.write.WriteGate
import com.yoshidometoru.soramoyou.data.repository.BlockedUsers
import com.yoshidometoru.soramoyou.data.repository.ModerationRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 投稿に出す操作。並びは iOS の「…」のメニューと同じ（通報 → ブロック：HomeView.swift:1138-1147）。 */
enum class ModerationAction { REPORT, BLOCK }

/**
 * 投稿 [post] に出す通報・ブロックの操作（要件 11.1・11.7）。並びは通報 → ブロック。
 *
 * - 自分の投稿（[ownUid] と投稿者が同じ）には何も出さない（要件 11.7。iOS の投稿詳細は自分の投稿にも出すが、要件に従って出さない）
 * - ログインしていない（[ownUid] が null）ときと、投稿者の uid が空（空白だけを含む）の投稿にも出さない
 *   （通報は契約 REPORT_CREATE が空の投稿者を止めて失敗になり、ブロックしても誰も除けないため。rules があるので通常は起きない）
 * - 書き込みが有効なビルドの操作だけを出す（[canReport]＝REPORT・[canBlock]＝BLOCK。M4 以前のビルドでは何も出さない）
 *
 * フィードと投稿詳細の両方が、[PostModeration.actionsFor] を通してこの 1 か所で決める（画面ごとに判定を書かない）。
 */
fun moderationActionsFor(post: PostView, ownUid: Uid?, canReport: Boolean, canBlock: Boolean): Set<ModerationAction> {
    if (ownUid == null || post.userId == ownUid || post.userId.value.isBlank()) return emptySet()
    return buildSet {
        if (canReport) add(ModerationAction.REPORT)
        if (canBlock) add(ModerationAction.BLOCK)
    }
}

/**
 * 通報・ブロックの失敗（要件 11.6）。
 *
 * @property action 失敗した操作（見出しを「通報に失敗しました」「ブロックに失敗しました」で出し分ける）。
 * @property error 失敗の理由（文言はフィードの取得の失敗と同じ対応：feedErrorMessageRes）。
 */
data class ModerationFailure(val action: ModerationAction, val error: AppError)

/**
 * 通報・ブロックの操作の状態。ダイアログは同時に 1 つだけ出る（理由の選択・ブロックの確認・「通報しました」・失敗）。
 *
 * @property reportTarget 通報の理由を選ばせている投稿（null なら選択を出していない）。
 * @property blockTarget ブロックの確認を出している投稿。
 * @property sendingAction 送っている操作（通報かブロック。送っていなければ null）。送っている間は画面に「通報しています」
 *   「ブロックしています」を出す（要件 16.2：moderationSendingNoticeRes）。どちらを送っているかで文言を変えるので、真偽でなく操作で持つ。
 * @property reported 通報が届いた（「通報しました」を出す。iOS と同じ）。閉じたら false。
 * @property blockedAuthor 直前にブロックできた投稿者。投稿詳細は、これが入ったら閉じる（iOS の dismiss()：HomeView.swift:1258-1264）。
 * @property failure 直前の通報・ブロックの失敗。閉じたら null。
 */
data class ModerationUiState(
    val reportTarget: PostView? = null,
    val blockTarget: PostView? = null,
    val sendingAction: ModerationAction? = null,
    val reported: Boolean = false,
    val blockedAuthor: Uid? = null,
    val failure: ModerationFailure? = null,
) {
    /** 通報かブロックを送っている（操作を押せなくし、二重に送らない）。送っている操作は [sendingAction]。 */
    val sending: Boolean
        get() = sendingAction != null

    /** ダイアログ（理由の選択・ブロックの確認・完了・失敗）のどれかを出しているか。 */
    internal val showingDialog: Boolean
        get() = reportTarget != null || blockTarget != null || reported || failure != null
}

/**
 * 画面が通報・ブロックの操作を呼ぶための入口の束（フィードと投稿詳細の画面で同じものを使う）。中身は [PostModeration] のメソッド。
 */
data class ModerationHandlers(
    val onRequestReport: (PostView) -> Unit,
    val onRequestBlock: (PostView) -> Unit,
    val onSubmitReport: (ReportReason) -> Unit,
    val onCancelReport: () -> Unit,
    val onConfirmBlock: () -> Unit,
    val onCancelBlock: () -> Unit,
    val onDismissReported: () -> Unit,
    val onDismissFailure: () -> Unit,
)

/**
 * 投稿の通報とブロックの操作の状態を持つ部品（設計書の ModerationRepository を画面から使う側。ViewModel ではない）。
 * フィード（FeedViewModel）と投稿詳細（PostDetailViewModel）が 1 つずつ持ち、自分の viewModelScope を渡す
 * （ProfilePostsLoader と同じく、2 つの画面で同じ振る舞いを 1 か所に書くため）。
 *
 * - 操作を出す投稿は [actionsFor]（[moderationActionsFor]）で決める。出さない投稿の通報・ブロックを求められても何もしない
 * - 通報は iOS と同じく、理由を選ばせてから送り（選んだら確認せずに送る）、届いたら「通報しました」を出す（要件 11.2・11.3）
 * - ブロックは iOS と同じく、確認を経てから送る。届いたら [BlockedUsers] に知らせ、表示中のフィードがその投稿者の投稿を除く（要件 11.4）
 * - 失敗は、どの操作の失敗かと理由を出す（要件 11.6。iOS は reportError を作るだけで画面に出さない）。記録は ModerationRepository が
 *   済ませるので、ここでは記録しない（記録の窓口を持たない）
 * - オフラインの間は、通報・ブロックを求めても選択や確認を出さない（画面は操作を押せなくして案内を出す）。Firestore の書き込みは
 *   オフラインでは失敗せずに接続を待つので、押せると止まって見える（自分の投稿の削除と同じ扱い。2026-10-11 ユーザー判断の流儀）。
 *   選択や確認を出した後にオフラインになったときは止めない（接続を待ち、戻れば届く。削除の confirmDelete と同じ）
 * - 送信中と、ほかのダイアログを出している間は、通報・ブロックを求め直せない（二重に送らない）
 *
 * @param repository 通報・ブロックの書き込み（失敗の記録も行う）。
 * @param writeGate 書き込みの可否。REPORT・BLOCK が無効なビルドでは、その操作を出さない（ビルド時に決まるので作った時点で 1 回だけ読む）。
 * @param isOnline 接続の有無（NetworkMonitor.isOnline）。
 * @param currentUid いまログインしているユーザーの uid（いなければ null）。自分の投稿かを決めるのに、呼ぶたびに読む。
 * @param blockedUsers ブロックできたことの知らせ（アプリ全体で 1 つ）。
 * @param scope 持ち主の ViewModel の viewModelScope。画面を離れると、通報の結果（「通報しました」・失敗）の表示は捨てられる。
 *   通報とブロックの書き込みは、取り消されても届くまで待つ（通報は ModerationRepository の失敗の記録を落とさないため：[submitReport]。
 *   ブロックは届いたら [blockedUsers] に知らせるため：[confirmBlock]）。
 */
class PostModeration(
    private val repository: ModerationRepository,
    writeGate: WriteGate,
    private val isOnline: StateFlow<Boolean>,
    private val currentUid: () -> Uid?,
    private val blockedUsers: BlockedUsers,
    private val scope: CoroutineScope,
) {

    private val canReport: Boolean = writeGate.isEnabled(WriteCapability.REPORT)

    private val canBlock: Boolean = writeGate.isEnabled(WriteCapability.BLOCK)

    private val mutableState = MutableStateFlow(ModerationUiState())

    /** 通報・ブロックの操作の状態。 */
    val state: StateFlow<ModerationUiState> = mutableState.asStateFlow()

    /** 画面に渡す入口の束（作った時点で 1 回だけ作る。描き直しのたびに別の束にならないように）。 */
    val handlers: ModerationHandlers = ModerationHandlers(
        onRequestReport = ::requestReport,
        onRequestBlock = ::requestBlock,
        onSubmitReport = ::submitReport,
        onCancelReport = ::cancelReport,
        onConfirmBlock = ::confirmBlock,
        onCancelBlock = ::cancelBlock,
        onDismissReported = ::dismissReported,
        onDismissFailure = ::dismissFailure,
    )

    /** 投稿 [post] に出す操作。 */
    fun actionsFor(post: PostView): Set<ModerationAction> = moderationActionsFor(post, currentUid(), canReport, canBlock)

    /** 「この投稿を通報」を押した。理由の選択を出す。 */
    fun requestReport(post: PostView) {
        open(post, ModerationAction.REPORT) { it.copy(reportTarget = post) }
    }

    /** 理由の選択を閉じた（キャンセル・外を押した・戻る操作）。 */
    fun cancelReport() {
        mutableState.update { it.copy(reportTarget = null) }
    }

    /**
     * 理由 [reason] を選んだ。選択を閉じて通報を送る。選択を出していなければ何もしない（二度押しを通さない）。
     * 送った後に持ち主の画面を離れて scope が取り消されても、届くまで待つ（ModerationRepository の失敗の記録を落とさない）。
     */
    fun submitReport(reason: ReportReason) {
        var target: PostView? = null
        mutableState.update { state ->
            target = state.reportTarget?.takeIf { !state.sending }
            if (target != null) state.copy(reportTarget = null, sendingAction = ModerationAction.REPORT) else state
        }
        val post = target ?: return
        scope.launch {
            // 書き込みの待ちは取り消さない。通報を送った後に戻る操作で画面を離れると持ち主の scope は取り消され、待ちが取り消しで
            // 抜けると、ModerationRepository が待ちの後に行う失敗の記録が走らない（rules に断られた通報が監視に残らない）。
            // ブロック（confirmBlock）・いいね（LikeStateStore.toggle）と同じく NonCancellable で最後まで待つ。状態の更新はその後
            // （取り消し済みなら捨てられるが、見る画面はもう無い）
            val result = withContext(NonCancellable) { repository.report(post, reason) }
            mutableState.update { state ->
                when (result) {
                    is AppResult.Ok -> state.copy(sendingAction = null, reported = true)
                    is AppResult.Err -> state.copy(sendingAction = null, failure = ModerationFailure(ModerationAction.REPORT, result.error))
                }
            }
        }
    }

    /** 「このユーザーをブロック」を押した。ブロックの確認を出す。 */
    fun requestBlock(post: PostView) {
        open(post, ModerationAction.BLOCK) { it.copy(blockTarget = post) }
    }

    /** ブロックの確認を閉じた（キャンセル・外を押した・戻る操作）。 */
    fun cancelBlock() {
        mutableState.update { it.copy(blockTarget = null) }
    }

    /**
     * ブロックの確認で「ブロック」を押した。確認を閉じて投稿者のブロックを送る。確認を出していなければ何もしない。
     * 届いたら [BlockedUsers] に知らせ、[ModerationUiState.blockedAuthor] に投稿者を入れる。
     * 送った後に持ち主の画面を離れて scope が取り消されても、届くまで待って知らせる（知らせだけは失わない）。
     */
    fun confirmBlock() {
        var target: PostView? = null
        mutableState.update { state ->
            target = state.blockTarget?.takeIf { !state.sending }
            if (target != null) state.copy(blockTarget = null, sendingAction = ModerationAction.BLOCK) else state
        }
        val author = target?.userId ?: return
        scope.launch {
            // 書き込みの待ちと知らせは取り消さない。投稿詳細はブロックを送った後に戻る操作で離れられ、そのとき持ち主の scope は
            // 取り消される。待ちが取り消しで抜けると知らせを流せないのに、書き込みは Firestore が後で確定させるので、戻った先の
            // フィードにその投稿者の投稿が残る（要件 11.4）。自分の投稿の削除（PostDeleter）と同じく NonCancellable で最後まで行う。
            // 状態の更新はその後（取り消し済みなら捨てられるが、見る画面はもう無い）
            val result = withContext(NonCancellable) {
                repository.block(author).also { if (it is AppResult.Ok) blockedUsers.notify(author) }
            }
            mutableState.update { state ->
                when (result) {
                    is AppResult.Ok -> state.copy(sendingAction = null, blockedAuthor = author)
                    is AppResult.Err -> state.copy(sendingAction = null, failure = ModerationFailure(ModerationAction.BLOCK, result.error))
                }
            }
        }
    }

    /** 「通報しました」を閉じた。 */
    fun dismissReported() {
        mutableState.update { it.copy(reported = false) }
    }

    /** 失敗のダイアログを閉じた。 */
    fun dismissFailure() {
        mutableState.update { it.copy(failure = null) }
    }

    /**
     * [post] に [action] を出していて、オンラインで、送信中でもダイアログを出している最中でもなければ、[show] で選択か確認を出す。
     */
    private inline fun open(post: PostView, action: ModerationAction, show: (ModerationUiState) -> ModerationUiState) {
        if (action !in actionsFor(post) || !isOnline.value) return
        mutableState.update { state -> if (state.sending || state.showingDialog) state else show(state) }
    }
}
