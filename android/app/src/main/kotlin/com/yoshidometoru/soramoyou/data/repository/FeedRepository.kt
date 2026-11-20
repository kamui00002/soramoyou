// ⭐️ 公開投稿のフィードのページ取得（タスク 9.1・要件 4.1・4.2・4.3・4.10）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.PostDocumentReader
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.remote.read.RawPage
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.read.readAll
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.PostDecodeSource

/**
 * フィードの 1 ページ（設計書の FeedPage。:764）。
 *
 * 「続きがあるか」と「次の起点」は、表示できる投稿の件数でなく、**変換前に実際に読んだドキュメント**で決める
 * （iOS の `PostPage.isExhausted`・PR #150／#154。#154 は 2026-10-05 時点で未マージ）。壊れた投稿を飛ばしたページで件数を数えると、満杯のページでも
 * 「続きなし」と誤判定して続きを読まなくなり、起点を変換後の最後の 1 件にすると、末尾が壊れたページを読み直す。
 *
 * @property posts 表示できる投稿（変換できない投稿は除いてある）。クエリの順（作成日時の新しい順）。
 * @property next 次のページの起点（変換前の生の最後の 1 件。除外した投稿を含む）。読んだのが 0 件なら null。
 * @property skippedCount 変換できずに除外した件数（読んだ件数 − [posts] の件数）。
 * @property reachedEnd 続きが無いか。読んだ件数が 1 ページの件数（20）より少ないときだけ true。
 */
data class FeedPage(
    val posts: List<PostView>,
    val next: RawCursor?,
    val skippedCount: Int,
    val reachedEnd: Boolean,
) {
    /**
     * [blocked] の投稿者の投稿だけを除いたページを返す（要件 4.9。iOS の `PostPage.filteringPosts`・PR #156。2026-10-05 時点で未マージ）。
     * ブロックの除外は、フィードの画面の状態（FeedViewModel・タスク 9.4）が、取得したページにこれを使って行う（設計書のフロー図）。
     *
     * [next]・[reachedEnd]・[skippedCount] は除く前のまま残す。除いても、実際に読んだ位置と「続きがあるか」は変わらないため
     * （件数で決め直すと、ブロック中のユーザーの投稿だけのページで「続きなし」と誤判定する）。
     * [skippedCount] は変換できなかった件数のままで、ブロックで除いた件数は足さない。
     */
    fun excludingAuthors(blocked: Set<Uid>): FeedPage =
        if (blocked.isEmpty()) this else copy(posts = posts.filterNot { it.userId in blocked })
}

/**
 * 公開投稿のフィードのページ取得（設計書の部品 FeedRepository）。
 * ブロック中のユーザーの投稿の除外はしない（呼び出し側が [BlockListRepository] で得た一覧で [FeedPage.excludingAuthors] を使う）。
 */
interface FeedRepository {

    /**
     * 公開投稿を作成日時の新しい順に 1 ページ（20 件）読み、1 件ずつ表示用に変換する（要件 4.1・4.2・4.10）。
     * 変換できない投稿だけを除き、`post_decode_failed` で記録する（記録は [readAll]）。
     *
     * @param after 続きの起点（前のページの [FeedPage.next]）。null なら先頭から取得し直す（引っ張って更新：要件 4.3）。
     * @return 取得自体の失敗（通信断・権限拒否など）は [AppResult.Err]。記録はしない（表示と記録は画面の状態が行う：要件 4.12）。
     */
    suspend fun loadPage(after: RawCursor?): AppResult<FeedPage>
}

/**
 * [FeedRepository] の実装。状態（キャッシュ）は持たない（ログアウトで消すものが無いので SessionManager に登録しない）。
 *
 * @param reader 読み取りの唯一の入口。フィードの形は [QuerySpec.PublicFeed] だけを使う。
 * @param postReader 投稿の 1 件単位の変換（タスク 7.2）。
 * @param analytics 変換できなかった投稿の記録（`post_decode_failed`）の送り先。
 */
class DefaultFeedRepository(
    private val reader: FirestoreReader,
    private val postReader: PostDocumentReader,
    private val analytics: AnalyticsFacade,
) : FeedRepository {

    override suspend fun loadPage(after: RawCursor?): AppResult<FeedPage> =
        // サーバーから読む（ReadSource.SERVER）。既定の DEFAULT は通信できないと失敗せずにキャッシュを読み、
        // キャッシュはメモリだけで一覧が残らないので「0 件で成功」になる（要件 4.12・タスク 11.3 の端末確認で発見）
        when (val result = reader.query(QuerySpec.PublicFeed(after), ReadSource.SERVER)) {
            // 取得自体の失敗は記録せずに返す（表示と記録は画面の状態：要件 4.12）
            is AppResult.Err -> result
            is AppResult.Ok ->
                AppResult.Ok(postReader.feedPageOf(result.value, QuerySpec.PublicFeed.PAGE_SIZE, PostDecodeSource.HOME_FEED, analytics))
        }
}

/**
 * クエリの結果 [raw] を、1 件ずつ表示用に変換して [FeedPage] にする。フィードとプロフィールの投稿一覧（タスク 15.1）で同じ規則を使う。
 * 壊れた投稿は 1 件ずつ飛ばして [source] を付けて記録し、同じページの他の投稿は表示する（要件 4.10）。
 * 起点と「続きなし」は変換前に読んだドキュメントで決める（変換後の件数・最後の 1 件で決めない。[FeedPage] の説明）。
 *
 * @param pageSize そのクエリの 1 ページの件数。読んだ件数がこれより少ないときだけ「続きなし」にする。
 */
internal fun PostDocumentReader.feedPageOf(
    raw: RawPage,
    pageSize: Int,
    source: PostDecodeSource,
    analytics: AnalyticsFacade,
): FeedPage {
    val posts = readAll(raw.documents, source, analytics)
    return FeedPage(
        posts = posts,
        next = raw.cursor,
        skippedCount = raw.documents.size - posts.size,
        reachedEnd = raw.documents.size < pageSize,
    )
}
