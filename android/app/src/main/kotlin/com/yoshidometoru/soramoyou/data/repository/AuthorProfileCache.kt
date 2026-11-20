// ⭐️ 投稿者の名前とアイコンを公開プロフィールから取得して持つ（タスク 9.2・要件 4.4・4.5・4.6）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.RemoteImageUrlPolicy
import com.yoshidometoru.soramoyou.data.remote.read.remoteImageUrlOf
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.platform.SessionManager
import com.yoshidometoru.soramoyou.platform.SessionScopedState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/**
 * 投稿者の名前とアイコンを `publicProfiles/{uid}` から取得し、画面で共有して持つ（設計書の AuthorProfileCache。:770-773）。
 * Firebase Authentication のプロフィールは使わない（要件 4.4。認証の部品を受け取らない）。
 */
interface AuthorProfileCache {

    /** uid ごとの投稿者の表示。まだ取得していない uid は入っていない（画面は読み込み中として扱う）。 */
    val authors: StateFlow<Map<Uid, AuthorDisplay>>

    /** [uids] のうち、まだ取得していないものだけを取得して [authors] に入れる。戻った時点で [uids] の全てが入っている（途中で取り消されたとき・ログアウトしたときを除く）。 */
    suspend fun ensure(uids: Set<Uid>)
}

/**
 * [AuthorProfileCache] の実装。iOS の `HomeViewModel.fetchAuthorsForCurrentPosts`（origin/main `266d428` の HomeViewModel.swift:86-103）と同じく、
 * 未取得の uid だけを並列に取る。
 *
 * - 同時に取得するのは、要求が重なっても合わせて最大 [MAX_CONCURRENT_FETCHES] 件（セマフォはこのインスタンスに 1 つ）。
 * - 代替表示（[AuthorDisplay.Fallback]）にするのは、ドキュメントが無い・取得に失敗した・中の `id` が無いか uid と一致しない・表示名が無いか空のとき。
 *   `id` の検査は iOS の `PublicProfile(from:documentId:)`（PublicProfile.swift:157-161・issue #133）と同じで、
 *   要求した uid（＝[authors] のキー）と比べる。
 * - 覚えるのは結果が確定したもの（読めた・無かった・`id` が合わなかった・ドキュメント ID に使えない uid）だけ。
 *   取得に失敗した uid は代替表示を入れたうえで覚えず、次の [ensure] で取り直す（iOS も失敗を覚えず次のページで取り直す）。
 * - 取得中の uid をもう一度要求されたら、取得し直さずに、その取得が終わるまで待つ。
 * - ログアウトで全てを捨てる（[clearOnSignOut]。作られたときに [SessionManager] へ登録する）。ログアウトの前に始めた取得の結果は書き戻さない。
 *
 * @param reader 読み取りの入口。
 * @param sessionManager ログアウトで捨てる状態の登録先。
 * @param imageUrls 画面で読み込んでよい画像の URL の形（ビルドの変種ごとに 1 つ。AppContainer が渡す）。
 */
class DefaultAuthorProfileCache(
    private val reader: FirestoreReader,
    sessionManager: SessionManager,
    private val imageUrls: RemoteImageUrlPolicy,
) : AuthorProfileCache, SessionScopedState {

    private val state = MutableStateFlow<Map<Uid, AuthorDisplay>>(emptyMap())
    override val authors: StateFlow<Map<Uid, AuthorDisplay>> = state.asStateFlow()

    /** 同時に取得する件数の上限。要求をまたいで共有する。 */
    private val permits = Semaphore(MAX_CONCURRENT_FETCHES)

    /** 以下の 3 つは [lock] の中でだけ読み書きする（中で中断しないので、コルーチンのロックでなく synchronized で足りる）。 */
    private val lock = Any()

    /** 結果が確定して、取り直さない uid。 */
    private val settled = mutableSetOf<Uid>()

    /** 取得中の uid と、その取得の終わりの合図。 */
    private val inFlight = mutableMapOf<Uid, CompletableDeferred<Unit>>()

    /** ログアウトのたびに 1 増やす。取得を始めたときの値と違えば、結果を書き戻さない。 */
    private var generation = 0L

    init {
        sessionManager.register(this)
    }

    override suspend fun ensure(uids: Set<Uid>) {
        // 自分が取得する uid と、ほかの要求が取得中なので待つだけの合図を、1 回のロックで振り分ける
        val toFetch = mutableListOf<Pair<Uid, CompletableDeferred<Unit>>>()
        val toWait = mutableListOf<CompletableDeferred<Unit>>()
        val startedAt: Long
        synchronized(lock) {
            startedAt = generation
            uids.forEach { uid ->
                if (uid in settled) return@forEach
                val running = inFlight[uid]
                if (running != null) {
                    toWait += running
                } else {
                    val done = CompletableDeferred<Unit>()
                    inFlight[uid] = done
                    toFetch += uid to done
                }
            }
        }
        coroutineScope {
            toFetch.forEach { (uid, done) ->
                launch {
                    try {
                        val (display, isSettled) = fetch(uid)
                        store(uid, display, isSettled, startedAt)
                    } finally {
                        // 取り消されたときも合図を出し、待っている要求を取り残さない（その uid は入らないまま。次の要求で取り直す）
                        synchronized(lock) { if (inFlight[uid] === done) inFlight.remove(uid) }
                        done.complete(Unit)
                    }
                }
            }
        }
        toWait.forEach { it.await() }
    }

    /** [uid] の表示を取得する。2 つ目の値は、結果が確定したか（false なら次の要求で取り直す）。 */
    private suspend fun fetch(uid: Uid): Pair<AuthorDisplay, Boolean> {
        val ref = try {
            DocRef.publicProfile(uid)
        } catch (e: IllegalArgumentException) {
            // 空や `/` を含む uid（投稿の userId が空文字でも、変換は文字列として通す：タスク 7.2）。取得せず、何度来ても代替表示
            return AuthorDisplay.Fallback(null) to true
        }
        return when (val result = permits.withPermit { reader.get(ref) }) {
            is AppResult.Ok -> displayOf(uid, result.value) to true
            is AppResult.Err -> AuthorDisplay.Fallback(null) to false
        }
    }

    /** 公開プロフィールのドキュメント [document] を表示に変える。項目名は iOS の `PublicProfile.toFirestoreData` と同じ。 */
    private fun displayOf(uid: Uid, document: RawDocument?): AuthorDisplay {
        if (document == null || document.data["id"] as? String != uid.value) return AuthorDisplay.Fallback(null)
        // アイコンの URL は、画面で読み込んでよいもの（このビルドの Storage のダウンロード URL）だけを使う
        val photoUrl = remoteImageUrlOf(document.data["photoURL"], imageUrls)
        // iOS は空の表示名をそのまま（空の名前として）出すが、名前が無いのと同じに扱って代替表示にする
        val name = (document.data["displayName"] as? String)?.takeIf { it.isNotBlank() }
        return if (name != null) AuthorDisplay.Named(name, photoUrl) else AuthorDisplay.Fallback(photoUrl)
    }

    /** 取得を始めた後にログアウトしていなければ、結果を入れる。 */
    private fun store(uid: Uid, display: AuthorDisplay, isSettled: Boolean, startedAt: Long) {
        synchronized(lock) {
            if (generation != startedAt) return
            if (isSettled) settled += uid
            state.update { it + (uid to display) }
        }
    }

    override fun clearOnSignOut() {
        synchronized(lock) {
            generation++
            settled.clear()
            // 取得中のものは、終わったときに世代の違いで捨てられる。合図は取得した側が出すので、ここでは外すだけ
            inFlight.clear()
            state.value = emptyMap()
        }
    }

    companion object {
        /** 同時に取得する件数の上限（設計書 :773・タスク 9.2）。 */
        const val MAX_CONCURRENT_FETCHES: Int = 8
    }
}
