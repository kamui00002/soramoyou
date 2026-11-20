// ⭐️ 自分がブロック中のユーザーの一覧の取得（タスク 9.1・要件 4.9）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade

/**
 * 自分がブロック中のユーザーの一覧（設計書の部品 BlockListRepository。:771）。
 * ブロック・解除の書き込みと、ブロック中のユーザーの画面は M5（タスク 29.x の ModerationRepository）で足す。
 */
interface BlockListRepository {

    /**
     * 自分のユーザー文書（`users/{uid}`）の `blockedUserIds` を読む（iOS：`FirestoreService.fetchBlockedUserIds`）。
     * ログインしていない・文書が無い・項目が無いときは空。
     *
     * @return 読み取りの失敗は記録したうえで [AppResult.Err] で返す。失敗をどう扱うかは呼び出し側が決める。
     *   フィード（`FeedViewModel.refresh`）は表示を続け、直前のブロック中の集合を使う（空にすると、この画面でブロックした人の投稿が
     *   読み直した一覧に戻るため。iOS の `HomeViewModel.loadBlockedUsers` は空にする＝差。レビュー F16）。
     *   ブロック中のユーザーの画面（[ModerationRepository.blockedProfiles]）は、失敗をそのまま返す。
     *   記録はここで済んでいるので、呼び出し側では記録し直さない。
     */
    suspend fun blockedIds(): AppResult<Set<Uid>>
}

/**
 * [BlockListRepository] の実装。状態（キャッシュ）は持たず、呼ばれるたびに読む（ログアウトで消すものが無い）。
 *
 * @param reader 読み取りの唯一の入口。
 * @param currentUid いまログインしているユーザーの uid。ログインしていなければ null。
 * @param analytics 読み取りの失敗の記録先。
 */
class DefaultBlockListRepository(
    private val reader: FirestoreReader,
    private val currentUid: () -> Uid?,
    private val analytics: AnalyticsFacade,
) : BlockListRepository {

    override suspend fun blockedIds(): AppResult<Set<Uid>> {
        // ログインしていなければブロック中のユーザーもいない（iOS も読まずに空のまま）
        val uid = currentUid() ?: return AppResult.Ok(emptySet())
        return when (val result = reader.get(DocRef.user(uid))) {
            is AppResult.Err -> {
                // 失敗の扱いは呼び出し側が決める（インターフェースの @return）が、iOS と違って記録は残す（設計書「フィード読み込み」の注記）
                analytics.logError(result.error, ERROR_CONTEXT)
                result
            }
            is AppResult.Ok -> AppResult.Ok(uidsOf(result.value?.data?.get(FIELD_BLOCKED_USER_IDS)))
        }
    }

    /**
     * `blockedUserIds` の値を uid の集合にする。配列でなければ空。
     * 文字列でない要素だけを捨て、残りの文字列はブロック中として残す（iOS の `as? [String] ?? []` は 1 つでも混ざると全体を空にするが、
     * それではブロックが外れて見えるため、ブロックを保つ側に倒す。書き込みは arrayUnion の文字列だけなので、通常は差が出ない）。
     */
    private fun uidsOf(value: Any?): Set<Uid> =
        (value as? List<*>)?.filterIsInstance<String>()?.map(::Uid)?.toSet() ?: emptySet()

    internal companion object {
        /** ブロック中の uid の配列の項目名（iOS の FirestoreService と同じ綴り）。 */
        const val FIELD_BLOCKED_USER_IDS = "blockedUserIds"

        /** 読み取りの失敗を記録するときの発生箇所。 */
        const val ERROR_CONTEXT = "BlockListRepository.blockedIds"
    }
}
