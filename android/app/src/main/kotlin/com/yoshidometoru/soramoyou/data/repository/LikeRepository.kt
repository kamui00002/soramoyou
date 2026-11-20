// ⭐️ 「押した結果どうなってほしいか」を指定する、いいねの書き込み（タスク 18.2・要件 9.2〜9.6・9.8）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.contract.document.ShapeContracts
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import java.time.Clock
import java.time.Instant
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * いいねの書き込みと、いいね済みかどうかの確認（設計書の部品 LikeRepository。:796-818）。
 * 楽観的な表示と、全画面で共有する状態は LikeStateStore（タスク 18.3）の仕事で、この部品は状態を持たない。
 */
interface LikeRepository {

    /**
     * 投稿 [postId] のいいねを、押した結果こうなってほしい状態 [desired]（true＝いいね済み）にそろえ、書き込み後のサーバー上の
     * `likesCount` を返す（iOS の `FirestoreService.setLike`：FirestoreService.swift:1536-1582）。トグルでなく状態を指定するので、
     * 表示が古くても「いいねする」を押してサーバーで「外す」になることはない（何度呼んでも同じ結果になる）。
     *
     * - 1 つのトランザクションで、自分のいいね文書（`likes/{uid}_{postId}`）と投稿（`posts/{postId}`）を読み、
     *   望む状態と違うときだけ、いいね文書の作成または削除と、`likesCount` の ±1 を書く（要件 9.3・9.4・9.6）
     * - 既に望む状態なら何も書かず、いま読んだ `likesCount` を返す
     * - 投稿に書くのは `likesCount` の増減だけ（契約 POST_LIKE_COUNTER。更新日時も書かない。要件 9.5）
     * - 投稿の読み取り権限を失っている（フォローを外した後のフォロワー限定投稿など）と、投稿の読み取りで `PermissionDenied` になる（要件 9.8）
     * - 投稿が無いときも iOS と同じく分岐を足さない（`likesCount` の更新がドキュメントの不在で失敗し、`NotFound` が返る）
     * - 可否は [WriteCapability.LIKE]。無効なビルド（M2 以前）では Firebase に届かずに `WriteBlocked` を返す
     *
     * 失敗は [AppResult.Err] で返し、記録はこの部品が行う（発生箇所は `LikeRepository.setLike`。入口が記録済みのものは記録しない）。
     * 呼び出し側（LikeStateStore）は、表示を戻すだけで記録し直さない。
     */
    suspend fun setLike(postId: PostId, desired: Boolean): AppResult<Long>

    /**
     * [postIds] のうち、自分がいいね済みの投稿を返す（iOS の `checkLikeStatus` を投稿ごとに呼ぶのと同じ。要件 9.2）。
     * 自分のいいね文書（`likes/{uid}_{postId}`）の有無を、投稿ごとに個別に、サーバーから読んで確かめる。
     *
     * - 空の列なら読まずに空集合を返す。同じ ID が重なっていても 1 回だけ読む
     * - 1 件でも読めなければ、全体を `Err` で返す（一部だけの結果を `Ok` で返すと、読めなかった投稿を「いいねしていない」として
     *   上書きしてしまう。LikeStateStore の確認は、問い合わせた範囲をこの結果で置き換えるため）
     * - キャッシュでなくサーバーから読む（端末のキャッシュに残った古い有無で、表示を上書きしないため）
     * - 失敗の記録はしない（ログインしていないときの `PermissionDenied` も含む。扱いは呼び出し側（LikeStateStore）が決める。PostReadRepository と同じ）
     */
    suspend fun likedAmong(postIds: List<PostId>): AppResult<Set<PostId>>
}

/**
 * [LikeRepository] の実装。書き込みは必ず [gateway]、読み取りは [reader] を通す。
 *
 * @param currentUid いまログインしているユーザーの uid（いなければ null）。呼ぶたびに読む。
 * @param clock 端末の時刻（設計書 QC。iOS の `Like` も端末の時刻）。1 回の書き込みで 1 度だけ読み、いいね文書の `createdAt` に使う。
 */
class DefaultLikeRepository(
    private val gateway: FirestoreWriteGateway,
    private val reader: FirestoreReader,
    private val analytics: AnalyticsFacade,
    private val currentUid: () -> Uid?,
    private val clock: Clock = Clock.systemUTC(),
) : LikeRepository {

    override suspend fun setLike(postId: PostId, desired: Boolean): AppResult<Long> {
        val uid = currentUid() ?: return refuseNotSignedIn(SET_LIKE_CONTEXT)
        val likeRef = DocRef.like(uid, postId)
        val postRef = DocRef.post(postId)
        // 時刻はトランザクションの外で 1 回だけ読む（中身は SDK にやり直されることがあり、やり直すたびに値が変わらないように）
        val now = Instant.now(clock)

        val result = gateway.transaction(WriteCapability.LIKE) {
            // 読み取りは、全ての書き込みより前に 2 つとも行う（トランザクションの規則）
            val likeDoc = get(likeRef)
            val postDoc = get(postRef)
            // 投稿の読み込み（PostDocumentReader）と同じ解釈：欠けているか整数でなければ 0
            val currentCount = postDoc?.data?.get("likesCount") as? Long ?: 0L
            val liked = likeDoc != null
            when {
                desired && !liked -> {
                    create(likeRef, ShapeContracts.LIKE_CREATE, DocumentBuilders.likeCreate(uid, postId, now))
                    update(postRef, ShapeContracts.POST_LIKE_COUNTER, DocumentBuilders.likeCounter(+1))
                    currentCount + 1
                }
                !desired && liked -> {
                    delete(likeRef)
                    update(postRef, ShapeContracts.POST_LIKE_COUNTER, DocumentBuilders.likeCounter(-1))
                    currentCount - 1
                }
                // 既に望む状態：何も書かない（数も動かさない）
                else -> currentCount
            }
        }

        if (result is AppResult.Err) analytics.recordForwardedWriteFailure(result.error, SET_LIKE_CONTEXT)
        return result
    }

    override suspend fun likedAmong(postIds: List<PostId>): AppResult<Set<PostId>> {
        // ログインしていないときも記録しない（読み取りの失敗と同じく、扱いは呼び出し側が決める。ログアウト直後の確認で記録を出さないため）
        val uid = currentUid() ?: return AppResult.Err(AppError.PermissionDenied)
        val distinct = postIds.distinct()
        if (distinct.isEmpty()) return AppResult.Ok(emptySet())

        // 投稿ごとに個別に読む（同時に投げる）。結果は問い合わせの順のまま
        val reads = coroutineScope {
            distinct.map { postId -> async { postId to reader.get(DocRef.like(uid, postId), ReadSource.SERVER) } }.awaitAll()
        }
        val liked = mutableSetOf<PostId>()
        for ((postId, read) in reads) {
            when (read) {
                is AppResult.Err -> return read
                is AppResult.Ok -> if (read.value != null) liked += postId
            }
        }
        return AppResult.Ok(liked)
    }

    /** ログインしていないときの書き込みは誤りなので、入口の「未ログイン」の断りと同じ扱いで記録して返す。 */
    private fun refuseNotSignedIn(context: String): AppResult.Err {
        analytics.logError(AppError.PermissionDenied, context)
        return AppResult.Err(AppError.PermissionDenied)
    }

    private companion object {
        /** 記録の発生箇所（`クラス名.メソッド名`）。 */
        const val SET_LIKE_CONTEXT = "LikeRepository.setLike"
    }
}
