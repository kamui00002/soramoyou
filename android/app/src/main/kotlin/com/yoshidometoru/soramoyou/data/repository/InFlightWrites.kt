// ⭐️ 取り消さない書き込み（プロフィールの保存・投稿の削除の後半）が走っている数。ログアウトがその終わりを待つ（全体レビュー 4 回目 Q03）
package com.yoshidometoru.soramoyou.data.repository

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update

/**
 * 画面を離れても最後まで行う書き込みが、いくつ走っているか。アプリ全体で 1 つ（AppContainer が作り、[DefaultProfileEditor]・
 * [DefaultPostDeleter] と、ログアウトの [DefaultAuthRepository] に同じものを渡す）。
 *
 * 2 つの部品の後半（プロフィールはアイコンの送信から `publicProfiles` まで、投稿は文書の削除から知らせまで）は取り消しでは止まらない
 * （NonCancellable。レビュー R03）。ところがログアウトで認証の SDK の `currentUser` が null になると、書き込みの入口が残りの書き込みを
 * 未ログインとして断り、途中までの書き込みだけが残る（プロフィールなら profile.jpg だけ上書き・`users` だけ新しい。投稿なら投稿数が古いまま・
 * 画像が残る）。そこでログアウトは、セッションを破棄する前に、ここが 0 になるのを待つ。待つ上限はログアウトの側が持つ（2026-11-05 ユーザー判断）。
 *
 * - 数えるのは取り消さない範囲だけ。その手前（アイコンの変換・削除の前の読み直し）は、取り消されればそこで止まり、何も書いていない
 * - 0 になった瞬間を見逃しても（1→0→1 と速く変わったとき）、待つ側は次に 0 になるか上限まで待つだけで、壊れない
 * - ログアウトで捨てるものは持たない（走っている間だけ数える）。SessionManager には登録しない
 */
class InFlightWrites {

    private val running = MutableStateFlow(0)

    /** [block] を、走っている書き込みとして数えながら行う。終わり方（成功・失敗・例外・取り消し）によらず、終わったら数から外す。 */
    suspend fun <T> track(block: suspend () -> T): T {
        running.update { it + 1 }
        try {
            return block()
        } finally {
            running.update { it - 1 }
        }
    }

    /** 走っている書き込みが無くなるまで待つ（無ければすぐ戻る）。上限は呼ぶ側が付ける（[DefaultAuthRepository.signOut]）。 */
    suspend fun awaitIdle() {
        running.first { it == 0 }
    }
}
