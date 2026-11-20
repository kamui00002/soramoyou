// ⭐️ 投稿の通報・ブロックの操作の状態の単体テスト（タスク 29.2・要件 11.1〜11.4・11.6・11.7・16.2）
package com.yoshidometoru.soramoyou.feature.moderation

import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.model.ReportReason
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.repository.BlockedUsers
import com.yoshidometoru.soramoyou.data.repository.ModerationRepository
import com.yoshidometoru.soramoyou.feature.FakeWriteGate
import com.yoshidometoru.soramoyou.feature.feed.post
import com.yoshidometoru.soramoyou.feature.immediateScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 操作を出す投稿の判定（[moderationActionsFor]）と、理由の選択 → 送信 → 完了・失敗、確認 → ブロック → 知らせ、の流れを確かめる。
 * 画面（Compose）の描画は端末で確かめる（33.x）。ここでは画面が見る状態だけを見る。
 * 失敗の記録は ModerationRepository が済ませる（DefaultModerationRepositoryTest）ので、この部品は記録の窓口を持たない。
 */
class PostModerationTest {

    private val repository = FakeModerationRepository()
    private val online = MutableStateFlow(true)
    private var signedIn: Uid? = Uid("me")
    private var gate = FakeWriteGate(setOf(WriteCapability.REPORT, WriteCapability.BLOCK))
    private val blockedUsers = BlockedUsers()

    /** ブロックの知らせとして流れた uid。 */
    private val notified = mutableListOf<Uid>()

    init {
        blockedUsers.events.onEach { notified += it }.launchIn(immediateScope())
    }

    private fun moderation() = PostModeration(repository, gate, online, { signedIn }, blockedUsers, immediateScope())

    private val others = post("p1", author = "alice")
    private val own = post("p2", author = "me")

    // ── 操作を出す投稿（要件 11.1・11.7）──

    @Test
    fun `他人の投稿には、通報とブロックをこの順で出す`() {
        assertEquals(listOf(ModerationAction.REPORT, ModerationAction.BLOCK), moderation().actionsFor(others).toList())
    }

    @Test
    fun `自分の投稿には、通報もブロックも出さない`() {
        assertEquals(emptySet(), moderation().actionsFor(own))
    }

    @Test
    fun `ログインしていないときと、投稿者のuidが空の投稿には出さない`() {
        assertEquals(emptySet(), moderationActionsFor(others, ownUid = null, canReport = true, canBlock = true))
        assertEquals(emptySet(), moderationActionsFor(post("p3", author = ""), Uid("me"), canReport = true, canBlock = true))
        assertEquals(emptySet(), moderationActionsFor(post("p4", author = "  "), Uid("me"), canReport = true, canBlock = true))
    }

    @Test
    fun `書き込みが有効な操作だけを出し、どちらも無効なビルドでは何も出さない`() {
        gate = FakeWriteGate(setOf(WriteCapability.REPORT))
        assertEquals(setOf(ModerationAction.REPORT), moderation().actionsFor(others))
        gate = FakeWriteGate(setOf(WriteCapability.BLOCK))
        assertEquals(setOf(ModerationAction.BLOCK), moderation().actionsFor(others))
        // M4 以前のビルド（REPORT・BLOCK が無い）
        gate = FakeWriteGate(setOf(WriteCapability.LIKE, WriteCapability.POST_CREATE))
        assertEquals(emptySet(), moderation().actionsFor(others))
    }

    @Test
    fun `自分の投稿の通報やブロックを求めても、理由の選択も確認も出さず、何も送らない`() {
        val m = moderation()
        m.requestReport(own)
        m.requestBlock(own)

        assertEquals(ModerationUiState(), m.state.value)
        assertEquals(emptyList(), repository.reportCalls)
        assertEquals(emptyList(), repository.blockCalls)
    }

    // ── 通報（要件 11.2・11.3・11.6）──

    @Test
    fun `通報は理由を選ばせてから、選んだ理由で送り、届いたら「通報しました」を出す`() {
        val m = moderation()
        m.requestReport(others)
        assertEquals(others, m.state.value.reportTarget)

        m.submitReport(ReportReason.SPAM)
        assertNull(m.state.value.reportTarget)
        assertTrue(m.state.value.sending)
        assertEquals(listOf(others to ReportReason.SPAM), repository.reportCalls)

        repository.completeLast(AppResult.Ok(Unit))
        assertFalse(m.state.value.sending)
        assertTrue(m.state.value.reported)
        assertEquals(emptyList(), notified)

        m.dismissReported()
        assertFalse(m.state.value.reported)
    }

    @Test
    fun `理由の選択を閉じたら、何も送らない`() {
        val m = moderation()
        m.requestReport(others)
        m.cancelReport()
        m.submitReport(ReportReason.OTHER)

        assertEquals(ModerationUiState(), m.state.value)
        assertEquals(emptyList(), repository.reportCalls)
    }

    @Test
    fun `通報に失敗したら、どの操作の失敗かと理由を出し、閉じたら消す`() {
        val m = moderation()
        m.requestReport(others)
        m.submitReport(ReportReason.HARASSMENT)
        repository.completeLast(AppResult.Err(AppError.Network))

        assertEquals(ModerationFailure(ModerationAction.REPORT, AppError.Network), m.state.value.failure)
        assertFalse(m.state.value.reported)
        assertFalse(m.state.value.sending)

        m.dismissFailure()
        assertNull(m.state.value.failure)
    }

    @Test
    fun `通報の送信中に持ち主の画面を離れて取り消されても、通報は最後まで待ち、ModerationRepositoryの失敗の記録が走る`() {
        // フィードや投稿詳細は、通報を送った後に戻る操作で離れられ、そのとき持ち主の scope は取り消される。本物の ModerationRepository は
        // 失敗を report の中で（書き込みの await の後に）記録するので、偽物を包んで同じ位置で記録させる（DefaultLikeStateStoreTest の R16 と同じ）。
        // 待ちが取り消しで抜けると、この記録が走らない（rules に断られた通報が監視に残らない）。
        // 取り消し済みの scope に戻った後の状態（failure・sending）は捨てられうるので、見るのは記録と送った回数だけ
        val recorded = mutableListOf<AppError>()
        val recording = object : ModerationRepository by repository {
            override suspend fun report(post: PostView, reason: ReportReason): AppResult<Unit> =
                repository.report(post, reason).also { if (it is AppResult.Err) recorded += it.error }
        }
        val owner = immediateScope()
        val m = PostModeration(recording, gate, online, { signedIn }, blockedUsers, owner)
        m.requestReport(others)
        m.submitReport(ReportReason.SPAM)
        try {
            owner.cancel()
            repository.completeLast(AppResult.Err(AppError.PermissionDenied))

            assertEquals(1, repository.reportCalls.size)
            assertEquals(listOf<AppError>(AppError.PermissionDenied), recorded)
        } finally {
            // 取り消さない待ちを残さない（この scope はテストが待たないので止まりにはならないが、待つ形のテストと同じ書き方にそろえる）
            repository.pending.forEach { it.complete(AppResult.Err(AppError.Network)) }
        }
    }

    // ── ブロック（要件 11.4・11.6）──

    @Test
    fun `ブロックは確認を経てから投稿者を送り、成功したら投稿者を知らせる`() {
        val m = moderation()
        m.requestBlock(others)
        assertEquals(others, m.state.value.blockTarget)
        assertEquals(emptyList(), repository.blockCalls)

        m.confirmBlock()
        assertNull(m.state.value.blockTarget)
        assertTrue(m.state.value.sending)
        assertEquals(listOf(Uid("alice")), repository.blockCalls)

        repository.completeLast(AppResult.Ok(Unit))
        assertFalse(m.state.value.sending)
        assertEquals(Uid("alice"), m.state.value.blockedAuthor)
        assertEquals(listOf(Uid("alice")), notified)
    }

    @Test
    fun `ブロックの確認を閉じたら、何も送らない`() {
        val m = moderation()
        m.requestBlock(others)
        m.cancelBlock()
        m.confirmBlock()

        assertEquals(ModerationUiState(), m.state.value)
        assertEquals(emptyList(), repository.blockCalls)
    }

    @Test
    fun `ブロックに失敗したら失敗を出し、投稿者を知らせない`() {
        val m = moderation()
        m.requestBlock(others)
        m.confirmBlock()
        repository.completeLast(AppResult.Err(AppError.PermissionDenied))

        assertEquals(ModerationFailure(ModerationAction.BLOCK, AppError.PermissionDenied), m.state.value.failure)
        assertNull(m.state.value.blockedAuthor)
        assertEquals(emptyList(), notified)
    }

    @Test
    fun `ブロックの送信中に持ち主の画面を離れて取り消されても、届いたら投稿者を知らせる`() {
        // 投稿詳細はブロックを送った後に戻る操作で離れられ、そのとき持ち主（PostDetailViewModel）の scope は取り消される。
        // 書き込みは Firestore が後で確定させるので、ここで知らせを失うと、戻った先のフィードにその投稿者の投稿が残る（要件 11.4）。
        // 取り消し済みの scope に戻った後の状態（blockedAuthor・sending）は捨てられうるので、見るのは知らせと送った相手だけ
        val owner = immediateScope()
        val m = PostModeration(repository, gate, online, { signedIn }, blockedUsers, owner)
        m.requestBlock(others)
        m.confirmBlock()
        owner.cancel()

        repository.completeLast(AppResult.Ok(Unit))
        assertEquals(listOf(Uid("alice")), repository.blockCalls)
        assertEquals(listOf(Uid("alice")), notified)
    }

    @Test
    fun `取り消された後にブロックの失敗が届いたら、投稿者を知らせない`() {
        val owner = immediateScope()
        val m = PostModeration(repository, gate, online, { signedIn }, blockedUsers, owner)
        m.requestBlock(others)
        m.confirmBlock()
        owner.cancel()

        repository.completeLast(AppResult.Err(AppError.Network))
        assertEquals(emptyList(), notified)
    }

    // ── 二重の送信・オフライン ──

    @Test
    fun `送信中は、通報もブロックも求め直せず、二重に送らない`() {
        val m = moderation()
        m.requestReport(others)
        m.submitReport(ReportReason.SPAM)

        m.requestReport(others)
        m.submitReport(ReportReason.SPAM)
        m.requestBlock(post("p5", author = "bob"))
        m.confirmBlock()

        assertNull(m.state.value.reportTarget)
        assertNull(m.state.value.blockTarget)
        assertEquals(1, repository.reportCalls.size)
        assertEquals(emptyList(), repository.blockCalls)
    }

    @Test
    fun `オフラインの間は、通報もブロックも求めても何も出さない`() {
        online.value = false
        val m = moderation()
        m.requestReport(others)
        m.requestBlock(others)

        assertEquals(ModerationUiState(), m.state.value)
    }

    @Test
    fun `確認を出した後にオフラインになっても、確かめたら送る`() {
        // 削除と同じ扱い（PostDetailViewModel.confirmDelete）。書き込みは接続を待ち、戻れば届く
        val m = moderation()
        m.requestBlock(others)
        online.value = false
        m.confirmBlock()

        assertEquals(listOf(Uid("alice")), repository.blockCalls)
    }

    // ── 送信中の表示（要件 16.2）──

    @Test
    fun `通報を送っている間だけ「通報しています」を出す`() {
        val m = moderation()
        assertNull(moderationSendingNoticeRes(m.state.value))
        // 理由を選ばせている間は、まだ送っていない
        m.requestReport(others)
        assertNull(moderationSendingNoticeRes(m.state.value))

        m.submitReport(ReportReason.SPAM)
        assertEquals(R.string.report_sending, moderationSendingNoticeRes(m.state.value))

        repository.completeLast(AppResult.Ok(Unit))
        assertNull(moderationSendingNoticeRes(m.state.value))
    }

    @Test
    fun `ブロックを送っている間だけ「ブロックしています」を出し、失敗が届いたら消す`() {
        val m = moderation()
        // 確認を出している間は、まだ送っていない
        m.requestBlock(others)
        assertNull(moderationSendingNoticeRes(m.state.value))

        m.confirmBlock()
        assertEquals(R.string.block_sending, moderationSendingNoticeRes(m.state.value))

        repository.completeLast(AppResult.Err(AppError.Network))
        assertNull(moderationSendingNoticeRes(m.state.value))
    }
}
