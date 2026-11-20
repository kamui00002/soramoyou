// ⭐️ ブロック中のユーザー 1 人の表示（タスク 29.1・要件 11.5）
package com.yoshidometoru.soramoyou.data.model

import com.yoshidometoru.soramoyou.contract.Uid

/**
 * 設定画面の「ブロック中のユーザー」に出す 1 人（設計書の `BlockedUserView`。:952）。作るのは ModerationRepository だけである。
 * 名前とアイコンは投稿者の表示と同じく `publicProfiles/{uid}` からだけ取り、読めなかったときは [AuthorDisplay.Fallback]
 * （名前は常に「ユーザー」。uid の一部を名前に使うことはない。要件 4.5）。
 *
 * @property uid ブロック中のユーザーの uid。解除の操作（`unblock`）に渡す。
 * @property author 一覧に出す名前とアイコン。
 */
data class BlockedUserView(
    val uid: Uid,
    val author: AuthorDisplay,
)
