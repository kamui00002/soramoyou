// ⭐️ 自分の投稿数をサーバーで数え直して保存する（設計書の部品 PostsCountSynchronizer。タスク 23.1・要件 1.4・7.19・7.20）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.contract.document.ShapeContracts
import com.yoshidometoru.soramoyou.data.remote.read.CountSpec
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade

/** 自分の投稿数を数え直して保存する（設計書の部品 PostsCountSynchronizer。:863）。投稿の作成（タスク 23.3）と削除（タスク 24）の後に呼ぶ。 */
interface PostsCountSynchronizer {

    /**
     * [uid] の投稿を**サーバーで集計し**、全投稿数を `users/{uid}.postsCount` へ、公開投稿数を `publicProfiles/{uid}.postsCount` へ保存する（要件 7.19）。
     * 成功したら全投稿数を返す。
     *
     * 順序（iOS の recountPostsCount と同じ：FirestoreService.swift:678-700）：
     * 1. 全投稿数を数える → 2. 公開投稿数を数える → 3. `users` を更新する → 4. `publicProfiles` を更新する
     *
     * - 集計（1・2）か `users` の更新（3）に失敗したら、その先は行わずに `Err` を返す（iOS も投げる）
     * - `publicProfiles` の更新（4）の失敗は記録して続行し、`Ok`（全投稿数）を返す（iOS も握りつぶしてログに残す。
     *   ドキュメントが無いユーザー〔iOS の移行前のユーザー〕もここに来る）
     *
     * ⚠️ 失敗は**この部品が全て記録する**。呼び出し側は `Err` を記録し直さない（`error_occurred` の件数が二重になる）。
     * ⚠️ `Err` でも投稿の成功は覆さない（要件 7.20）。それを守るのは呼び出し側（タスク 23.3・24）で、`Err` は無視して先へ進む。
     *    数え直しは次の投稿・削除のときにやり直される。
     *
     * 失敗は [AppResult.Err] で返す。例外は投げない（コルーチンの取り消しを除く）。
     */
    suspend fun recount(uid: Uid): AppResult<Long>
}

/**
 * [PostsCountSynchronizer] の実装。集計は読み取り口の [FirestoreReader.count]（常にサーバー）、書き込みは [gateway] を通す
 * （可否は [WriteCapability.POSTS_COUNT_SYNC]。M4 より前のビルドでは `WriteBlocked`）。
 *
 * 書き込むのは `postsCount` だけで、`updatedAt` は書かない（iOS と同じ。契約 [ShapeContracts.USER_POSTS_COUNT]・
 * [ShapeContracts.PUBLIC_PROFILE_POSTS_COUNT] が他の項目を止める）。数え直した値で上書きするので、何度呼んでも同じ結果になる。
 *
 * 記録（`error_occurred`）の取り決め：発生箇所は `PostsCountSynchronizer.recount.<段階>`（`countAll`・`countPublic`・`users`・`publicProfiles`）。
 * 読み取り口は失敗を記録しないので、集計の失敗はここで記録する。書き込みの入口が自分で断って記録済みのもの
 * （[recordForwardedWriteFailure] が除く `WriteBlocked`・`ShapeViolation`）は記録し直さない。
 */
class DefaultPostsCountSynchronizer(
    private val reader: FirestoreReader,
    private val gateway: FirestoreWriteGateway,
    private val analytics: AnalyticsFacade,
) : PostsCountSynchronizer {

    override suspend fun recount(uid: Uid): AppResult<Long> {
        // 1・2. 集計（両方そろってから書く。片方だけ書くと、全投稿数と公開投稿数が別の時点の値になる）
        val allCount = when (val result = reader.count(CountSpec.OwnPosts(uid))) {
            is AppResult.Ok -> result.value
            is AppResult.Err -> {
                analytics.logError(result.error, "$CONTEXT.countAll")
                return result
            }
        }
        val publicCount = when (val result = reader.count(CountSpec.OwnPublicPosts(uid))) {
            is AppResult.Ok -> result.value
            is AppResult.Err -> {
                analytics.logError(result.error, "$CONTEXT.countPublic")
                return result
            }
        }

        // 3. users（本人だけが見る値。非公開・フォロワー限定を含む全投稿数）
        val userResult = gateway.update(
            WriteCapability.POSTS_COUNT_SYNC,
            DocRef.user(uid),
            ShapeContracts.USER_POSTS_COUNT,
            DocumentBuilders.postsCount(allCount),
        )
        if (userResult is AppResult.Err) {
            analytics.recordForwardedWriteFailure(userResult.error, "$CONTEXT.users")
            return userResult
        }

        // 4. publicProfiles（他人に見せる値。公開投稿だけの数）。失敗は記録して続行する
        val publicResult = gateway.update(
            WriteCapability.POSTS_COUNT_SYNC,
            DocRef.publicProfile(uid),
            ShapeContracts.PUBLIC_PROFILE_POSTS_COUNT,
            DocumentBuilders.postsCount(publicCount),
        )
        if (publicResult is AppResult.Err) analytics.recordForwardedWriteFailure(publicResult.error, "$CONTEXT.publicProfiles")

        return AppResult.Ok(allCount)
    }

    private companion object {
        /** 記録の発生箇所の前半（`クラス名.メソッド名`）。後ろに `.段階` を付ける。 */
        const val CONTEXT = "PostsCountSynchronizer.recount"
    }
}
