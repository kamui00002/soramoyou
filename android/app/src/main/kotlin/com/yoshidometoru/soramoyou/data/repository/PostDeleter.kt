// ⭐️ 自分の投稿の削除：文書の削除・投稿数の数え直し・画像の削除・一覧への知らせ（設計書の部品 PostDeleter。タスク 24・要件 10.11）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.data.remote.write.StorageGateway
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** 自分の投稿の削除（設計書の部品 PostDeleter。:864）。投稿詳細（タスク 24）が使う。 */
interface PostDeleter {

    /**
     * 自分の投稿 [postId] を消す。順序は iOS と同じ（FirestoreService.swift:354-372 → StorageService.swift:332-350）：
     * 1. 文書をサーバーから読み直し、いまのユーザーの投稿であることを確かめ、消す画像のパスを控える
     * 2. 文書を削除する
     * 3. 投稿数を数え直す（終わるまで待つ）
     * 4. 画像（本体・サムネイル・元画像）をベストエフォートで削除する
     * 5. 消したことを一覧へ知らせる（[DeletedPosts]）
     *
     * - 1 か 2 に失敗したら、その先は行わずに `Err` を返す（画像には触らない）
     * - 3 の失敗（`Err`）と 4 の失敗は削除の成功を覆さない（要件 7.20。画像の失敗は記録して残りを続ける）
 * - 4 は画像 1 つごとに待つ時間に上限がある（返事の無い 1 本で、削除が終わらないままにしない）
     * - 2 から先は取り消さない。呼んだ画面を離れて取り消されても最後まで行い、消し残しを作らない。
     *   ログアウトは、この間の終わりを上限（10 秒）まで待ってから行う。上限を過ぎてもまだ消していれば、残りはログアウトの後に断られる（全体レビュー 4 回目 Q03）
     *
     * 失敗は [AppResult.Err] で返す。記録はこの部品が行うので、呼び出し側は記録し直さない。例外は投げない（コルーチンの取り消しを除く）。
     */
    suspend fun delete(postId: PostId): AppResult<Unit>
}

/**
 * [PostDeleter] の実装。書き込みは全て [gateway]・[storage] を通す（可否は [WriteCapability.POST_DELETE]。M3 以前のビルドでは `WriteBlocked`）。
 *
 * 持ち主とパスは、削除の直前に**サーバーから**読み直した文書で確かめる（画面が持つ投稿の値は信じない。表示用の PostView は
 * Storage のパスを持たない）。キャッシュの古い文書で削除を進めないよう、読み取り元はサーバーに限る（オフラインなら `Network` ですぐ失敗する）。
 *
 * 記録（`error_occurred`）の取り決め：発生箇所は `PostDeleter.delete.<段階>`。
 * - `read`：文書の読み直しの失敗・文書が無い（読み取り口は記録しないので、ここで記録する）
 * - `owner`：いまのユーザーの投稿でない（画面は自分の投稿にしか削除を出さないので、起きれば不具合）
 * - `document`：文書の削除の失敗（入口が断って記録済みの `WriteBlocked`・`ShapeViolation` は記録し直さない）
 * - `images`：画像の削除の失敗（無い〔`NotFound`〕のは消せたものとみなして記録しない。入口が記録済みの `WriteBlocked` も記録しない）。
 *   上限の時間までに返事が無いものは `Network` として記録する
 * - 未ログインは `PostDeleter.delete` で `PermissionDenied`（PostPublisher と同じ）
 * - 投稿数の数え直しの失敗は [PostsCountSynchronizer] が記録する。削除のイベントは送らない（iOS に無い）
 *
 * @param currentUid いまログインしているユーザーの uid（いなければ null）。呼ぶたびに読む
 * @param inFlight 走っている取り消さない書き込みの数（アプリ全体で 1 つ。ログアウトの [DefaultAuthRepository] と同じもの）
 * @param imageDeleteTimeout 画像 1 つの削除を待つ上限（2026-10-11 ユーザー判断）。端末確認で、Storage が返事をしない削除が
 *   10 分以上「削除しています」のまま続いたため（Storage の SDK は返事の無い要求を打ち切らない）。単体テストでは短くする
 */
class DefaultPostDeleter(
    private val reader: FirestoreReader,
    private val gateway: FirestoreWriteGateway,
    private val storage: StorageGateway,
    private val countSynchronizer: PostsCountSynchronizer,
    private val deletedPosts: DeletedPosts,
    private val analytics: AnalyticsFacade,
    private val currentUid: () -> Uid?,
    private val inFlight: InFlightWrites,
    private val imageDeleteTimeout: Duration = IMAGE_DELETE_TIMEOUT,
) : PostDeleter {

    override suspend fun delete(postId: PostId): AppResult<Unit> {
        val uid = currentUid() ?: return refuse(AppError.PermissionDenied, CONTEXT)
        // 文書 ID に使えない投稿 ID（空・/ を含む）は、そもそも存在しえないので読まずに「無い」とする（PostReadRepository と同じ）
        val ref = try {
            DocRef.post(postId)
        } catch (e: IllegalArgumentException) {
            return refuse(AppError.NotFound, "$CONTEXT.read")
        }

        // 1. 読み直し・持ち主の確認・パスを控える（文書を消すと、もう読めないので先に控える）
        val document = when (val read = reader.get(ref, ReadSource.SERVER)) {
            is AppResult.Err -> return refuse(read.error, "$CONTEXT.read")
            is AppResult.Ok -> read.value ?: return refuse(AppError.NotFound, "$CONTEXT.read")
        }
        if (document.data["userId"] != uid.value) return refuse(AppError.PermissionDenied, "$CONTEXT.owner")
        val paths = postImagePathsOf(document.data, uid)

        // 2〜5 は取り消さない：文書の削除を送った後で止めると、数え直しと画像の削除をしないまま投稿だけが消える。
        // 取り消さない範囲は、走っている書き込みとして数える（ログアウトがその終わりを待つ。全体レビュー 4 回目 Q03）
        return inFlight.track {
            withContext(NonCancellable) {
                // 2. 文書の削除
                val deleted = gateway.delete(WriteCapability.POST_DELETE, ref)
                if (deleted is AppResult.Err) {
                    analytics.recordForwardedWriteFailure(deleted.error, "$CONTEXT.document")
                    return@withContext deleted
                }
                // 3. 数え直し。Err は数え直しが記録済みで、削除の成功は覆さない（7.20）ので無視する
                countSynchronizer.recount(uid)
                // 4. 画像。5. 知らせ
                deleteImages(paths)
                deletedPosts.notify(postId)
                AppResult.Ok(Unit)
            }
        }
    }

    /**
     * [paths] を並列に消す（iOS も並列：StorageService.swift:333）。1 つ失敗しても残りを消し、失敗は記録の取り決めに従って記録する。
     * 1 つごとに [imageDeleteTimeout] まで待ち、返事が無ければ打ち切って `Network` とする（iOS は打ち切らない＝差）。
     * 打ち切った削除は Storage に届いていれば後で終わることもある（ベストエフォート）。
     */
    private suspend fun deleteImages(paths: List<StoragePath>) {
        val results = coroutineScope {
            paths.map { path ->
                async {
                    withTimeoutOrNull(imageDeleteTimeout) { storage.delete(WriteCapability.POST_DELETE, path) }
                        ?: AppResult.Err(AppError.Network)
                }
            }.awaitAll()
        }
        // 記録は終わってから、パスの並びの順に行う（並列の終わる順で記録の順が変わらないように）
        results.forEach { result ->
            if (result is AppResult.Err && result.error != AppError.NotFound) {
                analytics.recordForwardedStorageFailure(result.error, "$CONTEXT.images")
            }
        }
    }

    /** [error] を [context] で記録して、その失敗を返す。 */
    private fun refuse(error: AppError, context: String): AppResult.Err {
        analytics.logError(error, context)
        return AppResult.Err(error)
    }

    private companion object {
        /** 記録の発生箇所の前半（`クラス名.メソッド名`）。後ろに `.段階` を付ける。 */
        const val CONTEXT = "PostDeleter.delete"

        /** 画像 1 つの削除を待つ上限。遅い回線で 30 本（10 枚の本体・サムネイル・元画像）を並列に消しても足りる長さにする。 */
        val IMAGE_DELETE_TIMEOUT: Duration = 30.seconds
    }
}
