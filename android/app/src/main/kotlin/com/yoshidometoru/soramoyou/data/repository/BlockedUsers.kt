// ⭐️ ブロックしたユーザーを、表示中のフィードへ知らせる（タスク 29.2・要件 4.9・11.4）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.Uid
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * ブロックしたユーザーの知らせ（消した投稿の知らせ [DeletedPosts] と同じ形）。アプリ全体で 1 つ。
 *
 * 通報・ブロックの操作（フィードと投稿詳細。feature/moderation の PostModeration）がブロックの書き込みに成功したら 1 回 [notify] し、
 * フィードは [events] を集めて、その投稿者の投稿を表示中の一覧からすぐに除く（要件 11.4。読み直さない）。
 * 投稿詳細からブロックしたときも、詳細の下に残っているフィードが同じ知らせで除くので、詳細を閉じて戻った一覧には出ない
 * （iOS は詳細を閉じるだけで、下のフィードは次の読み直しまで残る：HomeView.swift:1258-1264）。
 *
 * - 後から集め始めた画面には届かない（replay 0）。まだ無い画面は、作られたときにブロック中の一覧をサーバーから読むので入らない
 * - 画面が受け取り損ねても、次の読み直しで除かれる。だから知らせは失敗を返さず、詰まったら古いものを捨てる
 * - 解除（ブロック中のユーザーの画面）は知らせない。フィードは次の読み直しでブロック中の一覧を読み直して戻す（iOS と同じ）
 * - ログアウトで捨てるものは持たない（溜めないので）。SessionManager には登録しない
 */
class BlockedUsers {

    private val flow = MutableSharedFlow<Uid>(extraBufferCapacity = BUFFER, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** ブロックしたユーザーの uid。フィードの ViewModel が集める。 */
    val events: SharedFlow<Uid> = flow.asSharedFlow()

    /** [uid] をブロックしたことを知らせる。待たない（ブロックの処理を画面の集め方で止めない）。 */
    fun notify(uid: Uid) {
        flow.tryEmit(uid)
    }

    private companion object {
        /** 集める側が追いつくまで預かる数。ブロックは 1 回に 1 人なので、少なくて足りる。 */
        const val BUFFER = 8
    }
}
