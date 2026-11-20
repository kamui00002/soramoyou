// ⭐️ 作った投稿を、フィードと自分のプロフィールの一覧へ知らせる（タスク 23.3・要件 7.22）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.data.model.PostView
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * 作った投稿の知らせ（iOS の `.postCreated` 通知に当たる：PostViewModel.swift:677）。アプリ全体で 1 つ。
 *
 * 投稿の文書の保存（[DefaultPostDocumentSaver]）が成功したら 1 回 [notify] し、フィードと自分のプロフィールは [events] を集めて
 * 一覧の先頭に差し込む（読み直さない。2026-10-10 ユーザー判断）。iOS のプロフィールは知らせを受けて読み直すが、
 * Android はスクロールの位置を保ち、読み取りを増やさないために差し込む。
 *
 * - 後から集め始めた画面には届かない（replay 0）。まだ無い画面は、作られたときにサーバーから読むので新しい投稿も入る
 * - 画面が受け取り損ねても投稿は消えない（次の読み直しで出る）。だから知らせは失敗を返さず、詰まったら古いものを捨てる
 * - ログアウトで捨てるものは持たない（溜めないので）。SessionManager には登録しない
 */
class CreatedPosts {

    private val flow = MutableSharedFlow<PostView>(extraBufferCapacity = BUFFER, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** 作った投稿（表示用の形）。画面の ViewModel が集める。 */
    val events: SharedFlow<PostView> = flow.asSharedFlow()

    /** [post] を作ったことを知らせる。待たない（保存の処理を画面の集め方で止めない）。 */
    fun notify(post: PostView) {
        flow.tryEmit(post)
    }

    private companion object {
        /** 集める側が追いつくまで預かる数。投稿は 1 回に 1 件なので、少なくて足りる。 */
        const val BUFFER = 8
    }
}
