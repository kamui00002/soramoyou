// ⭐️ 消した投稿を、フィードと自分のプロフィールの一覧へ知らせる（タスク 24・要件 10.11）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.PostId
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * 消した投稿の知らせ（作った投稿の知らせ [CreatedPosts] の逆向き。2026-10-11 ユーザー判断で別の部品にした）。アプリ全体で 1 つ。
 *
 * 自分の投稿の削除（[DefaultPostDeleter]）が全て終わったら 1 回 [notify] し、フィードと自分のプロフィールは [events] を集めて、
 * その投稿を一覧から除く（読み直さない）。iOS は詳細を閉じたときの呼び出し（`onPostDeleted`：GalleryDetailView.swift:240）や、
 * プロフィールの配列からの除去（ProfileViewModel.swift:669）で同じことをする。
 *
 * - 後から集め始めた画面には届かない（replay 0）。まだ無い画面は、作られたときにサーバーから読むので消した投稿は入らない
 * - 画面が受け取り損ねても、次の読み直しで消える。だから知らせは失敗を返さず、詰まったら古いものを捨てる
 * - ログアウトで捨てるものは持たない（溜めないので）。SessionManager には登録しない
 */
class DeletedPosts {

    private val flow = MutableSharedFlow<PostId>(extraBufferCapacity = BUFFER, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** 消した投稿の ID。画面の ViewModel が集める。 */
    val events: SharedFlow<PostId> = flow.asSharedFlow()

    /** [postId] を消したことを知らせる。待たない（削除の処理を画面の集め方で止めない）。 */
    fun notify(postId: PostId) {
        flow.tryEmit(postId)
    }

    private companion object {
        /** 集める側が追いつくまで預かる数。削除は 1 回に 1 件なので、少なくて足りる。 */
        const val BUFFER = 8
    }
}
