// ⭐️ Firestore からの読み取りの唯一の入口の実装：形の展開 → 実行 → カーソル → 失敗の写し（タスク 7.1・15.1・23.1・31.1・要件 1.4・4.1・4.2・7.19・10.2・10.4・10.5・12.3）
package com.yoshidometoru.soramoyou.data.remote.read

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map

/**
 * [FirestoreReader] の実装。クエリは次の順で進める。
 *
 * 1. 形の展開：[planOf] で [QuerySpec] を [QueryPlan]（コレクション・等値の条件・並び順・件数・起点）に展開する。
 *    形を決めるのはここだけで、SDK の実装（[FirebaseFirestoreReadClient]）はそれをそのまま適用する
 * 2. 実行：[sourceOf] で決めた取得元で [client] を呼ぶ。退会の取得（[QuerySpec.DrainByField]・[QuerySpec.AllOwned]）は、
 *    呼び出し側が何を渡しても SERVER にする（通信が切れたときにキャッシュの一部を「全件」と誤認させないため。要件 12.3）
 * 3. カーソル：結果の最後の 1 件（変換前の生のもの）を、続きの起点にする。0 件なら null
 * 4. 失敗の写し：[FirestoreReadFailure] は写した種類で、写せない例外は `Unknown`（例外の型名だけを載せる）で返す
 *
 * 監視（[observe]）も、届いた中身を `Ok` に、失敗を同じ規則で `Err` に写す。
 * 集計（[count]）は [countPlanOf] で [CountSpec] を [CountPlan] に展開し、サーバーで数えた件数を返す（失敗は同じ規則で写す）。
 *
 * 失敗の記録（分析・Crashlytics）はしない。読み取りの失敗を表示するか・記録するかは、呼び出し側のリポジトリが決める。
 * コルーチンの取り消し（CancellationException）は失敗に写さず、そのまま伝える（書き込みの入口と同じ）。
 */
class DefaultFirestoreReader internal constructor(
    private val client: FirestoreReadClient,
) : FirestoreReader {

    override suspend fun get(ref: DocRef, source: ReadSource): AppResult<RawDocument?> =
        guarded { client.get(ref.path, source) }

    override suspend fun query(spec: QuerySpec, source: ReadSource): AppResult<RawPage> =
        guarded {
            val snapshots = client.query(planOf(spec), sourceOf(spec, source))
            RawPage(
                documents = snapshots.map { it.document },
                cursor = snapshots.lastOrNull()?.let { RawCursor(it.token) },
            )
        }

    override suspend fun count(spec: CountSpec): AppResult<Long> =
        guarded { client.count(countPlanOf(spec)) }

    override fun observe(ref: DocRef): Flow<AppResult<RawDocument?>> =
        client.observe(ref.path)
            .map<RawDocument?, AppResult<RawDocument?>> { AppResult.Ok(it) }
            .catch { e ->
                // 取り消しと、Exception でないもの（Error）は写さずにそのまま伝える（guarded と同じ）
                if (e is CancellationException || e !is Exception) throw e
                emit(AppResult.Err(errorOf(e)))
            }

    /** [block] を実行し、結果を [AppResult] にする。 */
    private suspend fun <T> guarded(block: suspend () -> T): AppResult<T> =
        try {
            AppResult.Ok(block())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            AppResult.Err(errorOf(e))
        }

    /** [FirestoreReadFailure] は写した種類に、写せない例外は `Unknown`（例外の型名だけを載せる）にする。 */
    private fun errorOf(e: Exception): AppError =
        if (e is FirestoreReadFailure) e.error else AppError.Unknown(e.javaClass.simpleName)

    internal companion object {
        /** 投稿のコレクション（iOS の FirestoreService と同じ綴り。書き込み先の DocRef.post も同じ名前を別に綴っている）。 */
        private const val POSTS = "posts"
        private const val FIELD_VISIBILITY = "visibility"
        private const val FIELD_USER_ID = "userId"
        private const val FIELD_CREATED_AT = "createdAt"

        // 退会の取得で使うコレクション・フィールド（iOS の FirestoreService と同じ綴り）
        private const val FOLLOWS = "follows"
        private const val LIKES = "likes"
        private const val COMMENTS = "comments"
        private const val DRAFTS = "drafts"
        private const val FAVORITES = "favorites"
        private const val FIELD_FOLLOWER_ID = "followerId"
        private const val FIELD_FOLLOWEE_ID = "followeeId"

        /**
         * [spec] を SDK に渡すクエリの中身に展開する。形ごとの条件はここにだけ書く（設計書のクエリ×インデックス表）。
         * 新しい形を [QuerySpec] に足すと、この when が網羅でなくなりコンパイルが止まる。
         */
        internal fun planOf(spec: QuerySpec): QueryPlan = when (spec) {
            // 表の 1：複合インデックス visibility+createdAt
            is QuerySpec.PublicFeed -> QueryPlan(
                collection = POSTS,
                equalTo = listOf(FIELD_VISIBILITY to Visibility.PUBLIC.raw),
                orderByDescending = listOf(FIELD_CREATED_AT),
                limit = QuerySpec.PublicFeed.PAGE_SIZE,
                after = spec.after,
            )
            // 表の 2：複合インデックス userId+createdAt。公開範囲では絞らない（要件 10.2）
            is QuerySpec.OwnPosts -> QueryPlan(
                collection = POSTS,
                equalTo = listOf(FIELD_USER_ID to spec.uid.value),
                orderByDescending = listOf(FIELD_CREATED_AT),
                limit = QuerySpec.OwnPosts.PAGE_SIZE,
                after = spec.after,
            )
            // 表の 3：複合インデックス visibility+userId+createdAt。公開範囲の条件は外せない（要件 10.5）
            is QuerySpec.UserPublicPosts -> QueryPlan(
                collection = POSTS,
                equalTo = listOf(FIELD_VISIBILITY to Visibility.PUBLIC.raw, FIELD_USER_ID to spec.uid.value),
                orderByDescending = listOf(FIELD_CREATED_AT),
                limit = QuerySpec.UserPublicPosts.PAGE_SIZE,
                after = spec.after,
            )
            // 表の 6・7：単一フィールドのインデックス。並び順は付けない（複合インデックスを要求しない）。
            // 件数は必ず付ける（follows の rules は limit <= 50 を課す）。続きの起点は無く、呼び出し側が消してから先頭を取り直す
            is QuerySpec.DrainByField -> {
                val (collection, field) = when (spec.target) {
                    DrainTarget.FOLLOWS_AS_FOLLOWER -> FOLLOWS to FIELD_FOLLOWER_ID
                    DrainTarget.FOLLOWS_AS_FOLLOWEE -> FOLLOWS to FIELD_FOLLOWEE_ID
                    DrainTarget.LIKES -> LIKES to FIELD_USER_ID
                    DrainTarget.COMMENTS -> COMMENTS to FIELD_USER_ID
                }
                QueryPlan(
                    collection = collection,
                    equalTo = listOf(field to spec.uid.value),
                    orderByDescending = emptyList(),
                    limit = QuerySpec.DrainByField.PAGE_SIZE,
                    after = null,
                )
            }
            // 表の 8・9：件数の上限も並び順も付けない（全件）。お気に入りは users/{uid} の下位で、条件は要らない
            is QuerySpec.AllOwned -> when (spec.collection) {
                OwnedCollection.POSTS -> allOwnedByUserId(POSTS, spec.uid)
                OwnedCollection.DRAFTS -> allOwnedByUserId(DRAFTS, spec.uid)
                // パスの組み立ては DocRef.user の検査に任せる（空・`/` は IllegalArgumentException）
                OwnedCollection.FAVORITES -> QueryPlan(
                    collection = "${DocRef.user(spec.uid).path}/$FAVORITES",
                    equalTo = emptyList(),
                    orderByDescending = emptyList(),
                    limit = null,
                    after = null,
                )
            }
        }

        /** [collection] の `userId == uid` を、件数の上限も並び順もなしで全件取る計画。 */
        private fun allOwnedByUserId(collection: String, uid: Uid): QueryPlan = QueryPlan(
            collection = collection,
            equalTo = listOf(FIELD_USER_ID to uid.value),
            orderByDescending = emptyList(),
            limit = null,
            after = null,
        )

        /**
         * [spec] を実行する取得元を決める。退会の取得は [requested] によらず SERVER に固定する。
         * 既定の取得元は通信が切れるとキャッシュへ落ち、キャッシュにある一部だけを「全件」と誤認して、残りを消さずに退会を終えてしまうため
         * （iOS FirestoreService.swift:960-965）。
         * 他の形は呼び出し側の指定のままにする。新しい形を [QuerySpec] に足すと、この when が網羅でなくなりコンパイルが止まる。
         */
        internal fun sourceOf(spec: QuerySpec, requested: ReadSource): ReadSource = when (spec) {
            is QuerySpec.DrainByField, is QuerySpec.AllOwned -> ReadSource.SERVER
            is QuerySpec.PublicFeed, is QuerySpec.OwnPosts, is QuerySpec.UserPublicPosts -> requested
        }

        /**
         * [spec] を SDK に渡す集計の中身に展開する。形ごとの条件はここにだけ書く（設計書のクエリ×インデックス表の 4・5）。
         * 条件の並びは iOS の recountPostsCount（FirestoreService.swift:680-684）と同じ順にした（投稿者 → 公開範囲）。
         */
        internal fun countPlanOf(spec: CountSpec): CountPlan = when (spec) {
            // 表の 4：単一フィールドのインデックス。公開範囲では絞らない
            is CountSpec.OwnPosts -> CountPlan(
                collection = POSTS,
                equalTo = listOf(FIELD_USER_ID to spec.uid.value),
            )
            // 表の 5：等値の条件 2 本だけ（複合インデックスは要らない）
            is CountSpec.OwnPublicPosts -> CountPlan(
                collection = POSTS,
                equalTo = listOf(FIELD_USER_ID to spec.uid.value, FIELD_VISIBILITY to Visibility.PUBLIC.raw),
            )
        }
    }
}
