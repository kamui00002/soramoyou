// ⭐️ 投稿 1 件の取得（タスク 10.1・要件 5.1・5.5）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.PostDocumentReader
import com.yoshidometoru.soramoyou.data.remote.read.ReadOutcome
import com.yoshidometoru.soramoyou.data.remote.write.DocRef

/** 投稿 1 件を読んだ結果。表示できなかった理由を区別する（要件 5.5。画面の文言は 1 つでよい）。 */
sealed interface PostLookup {

    /** 表示できる投稿。 */
    data class Found(val post: PostView) : PostLookup

    /**
     * 投稿が無い（削除済み）。
     * ⚠️ 削除済みの投稿は、多くの場合 [NoPermission] として届く（2026-10-05 にエミュレータの REST で実測：認証なしで 403・管理者で 404。本番では未実測）。
     * 投稿の読み取りのルールは `resource.data.visibility` を見ている（firestore.rules の posts の read）ので、文書が無いと
     * `resource` が null で評価が失敗し、読み取りが拒否されるため。
     */
    data object Deleted : PostLookup

    /** 閲覧の権限が無い（非公開・フォロワー限定の投稿、または上の注記のとおり削除済み）。 */
    data object NoPermission : PostLookup

    /** 文書はあるが、表示用に変換できない。[reason] は [com.yoshidometoru.soramoyou.data.remote.read.DefaultPostDocumentReader] の理由の定数。 */
    data class Unreadable(val reason: String) : PostLookup
}

/** 投稿 1 件の取得（設計書の部品 PostReadRepository）。投稿詳細（タスク 10.2）が使う。 */
interface PostReadRepository {

    /**
     * `posts/{postId}` を読み、フィードと同じ規則（タスク 7.2 の PostDocumentReader）で表示用に変換する。
     *
     * @return 表示できない理由（削除・権限なし・変換できない）は [AppResult.Ok] の [PostLookup] で、
     *   それ以外の取得の失敗（通信断など）は [AppResult.Err] で返す。記録はしない（記録するかは画面の状態が決める）。
     */
    suspend fun fetch(postId: PostId): AppResult<PostLookup>
}

/**
 * [PostReadRepository] の実装。状態（キャッシュ）は持たない（ログアウトで消すものが無いので SessionManager に登録しない）。
 *
 * iOS の `FirestoreService.fetchPost`（origin/main `266d428` の :336-350）は、文書が無いと `notFound`、変換できないと
 * その例外を投げる。Android は例外でなく [PostLookup] で区別して返す。
 */
class DefaultPostReadRepository(
    private val reader: FirestoreReader,
    private val postReader: PostDocumentReader,
) : PostReadRepository {

    override suspend fun fetch(postId: PostId): AppResult<PostLookup> {
        // 文書 ID に使えない投稿 ID（空・/ を含む）は、そもそも存在しえないので読まずに「無い」とする
        val ref = try {
            DocRef.post(postId)
        } catch (e: IllegalArgumentException) {
            return AppResult.Ok(PostLookup.Deleted)
        }
        return when (val result = reader.get(ref)) {
            is AppResult.Err -> when (result.error) {
                AppError.PermissionDenied -> AppResult.Ok(PostLookup.NoPermission)
                AppError.NotFound -> AppResult.Ok(PostLookup.Deleted)
                else -> result
            }
            is AppResult.Ok -> {
                val raw = result.value ?: return AppResult.Ok(PostLookup.Deleted)
                when (val outcome = postReader.read(raw)) {
                    is ReadOutcome.Ok -> AppResult.Ok(PostLookup.Found(outcome.post))
                    is ReadOutcome.Skipped -> AppResult.Ok(PostLookup.Unreadable(outcome.reason))
                }
            }
        }
    }
}
