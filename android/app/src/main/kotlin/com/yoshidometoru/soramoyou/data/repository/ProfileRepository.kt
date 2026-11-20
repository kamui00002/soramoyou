// ⭐️ プロフィールと投稿一覧の読み取り（タスク 15.1・要件 1.4・4.10・10.1・10.2・10.4・10.5）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.OwnProfile
import com.yoshidometoru.soramoyou.data.model.PublicProfileView
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.PostDocumentReader
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.RawCursor
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.read.RemoteImageUrlPolicy
import com.yoshidometoru.soramoyou.data.remote.read.remoteImageUrlOf
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.PostDecodeSource
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map

/**
 * 自分・他人のプロフィールと投稿一覧の読み取り（設計書の部品 ProfileRepository。:865-876）。
 * 取得自体の失敗（通信断・権限拒否など）は記録せずに返す（表示と記録は画面の状態が行う。フィードと同じ）。
 */
interface ProfileRepository {

    /**
     * 自分のユーザー文書（`users/{uid}`）を監視し、届くたびに [OwnProfile] を流す（要件 10.1）。
     * 文書が無いときは `Err(NotFound)` を流し、監視は続ける（画面が補完（タスク 14.3）で作れば、次に `Ok` が届く。2026-10-06 ユーザー判断）。
     * オフラインでキャッシュにも無いときは、無いと確かめられないので `Err(Network)` を 1 回流して終わる（レビュー R17）。
     * ログインしていなければ、監視せずに `Err(PermissionDenied)` を 1 回流して終わる。
     */
    fun observeOwn(): Flow<AppResult<OwnProfile>>

    /**
     * 他人の公開プロフィール（`publicProfiles/{uid}`）を取得する（要件 10.4）。中の `id` が [uid] と一致しなければ中身を使わない。
     * 無い・一致しないときは [PublicProfileView.fallback] を `Ok` で返し、`Err` は取得自体の失敗（再試行で変わりうるもの）だけにする。
     */
    suspend fun fetchPublic(uid: Uid): AppResult<PublicProfileView>

    /**
     * 自分の投稿を、公開範囲によらず作成日時の新しい順に 1 ページ（50 件）読む（要件 10.2。[QuerySpec.OwnPosts]）。
     * 壊れた投稿は 1 件ずつ飛ばして `user_posts` で記録する。ログインしていなければ読まずに `Err(PermissionDenied)`。
     *
     * @param after 続きの起点（このメソッドが返した前のページの [FeedPage.next]）。null なら先頭から。
     */
    suspend fun ownPostsPage(after: RawCursor?): AppResult<FeedPage>

    /**
     * [uid] の公開投稿だけを作成日時の新しい順に 1 ページ（50 件）読む（要件 10.4・10.5。[QuerySpec.UserPublicPosts]）。
     * 壊れた投稿は 1 件ずつ飛ばして `public_posts` で記録する。
     *
     * @param after 続きの起点（このメソッドが同じ [uid] で返した前のページの [FeedPage.next]）。null なら先頭から。
     */
    suspend fun userPublicPostsPage(uid: Uid, after: RawCursor?): AppResult<FeedPage>
}

/**
 * [ProfileRepository] の実装。状態（キャッシュ）は持たない（ログアウトで消すものが無いので SessionManager に登録しない）。
 * ページの組み立て（続き・起点・除外件数）はフィードと同じ [feedPageOf] を使う。
 *
 * @param reader 読み取りの唯一の入口。
 * @param postReader 投稿の 1 件単位の変換（タスク 7.2）。
 * @param currentUid いまログインしているユーザーの uid。ログインしていなければ null。呼ぶたびに読む。
 * @param analytics 変換できなかった投稿の記録（`post_decode_failed`）の送り先。
 * @param imageUrls 画面で読み込んでよい画像の URL の形（ビルドの変種ごとに 1 つ。AppContainer が渡す）。アイコンの `photoURL` に使う。
 */
class DefaultProfileRepository(
    private val reader: FirestoreReader,
    private val postReader: PostDocumentReader,
    private val currentUid: () -> Uid?,
    private val analytics: AnalyticsFacade,
    private val imageUrls: RemoteImageUrlPolicy,
) : ProfileRepository {

    override fun observeOwn(): Flow<AppResult<OwnProfile>> = flow {
        val uid = currentUid()
        if (uid == null) {
            emit(AppResult.Err(AppError.PermissionDenied))
            return@flow
        }
        emitAll(
            reader.observe(DocRef.user(uid)).map { result ->
                when (result) {
                    is AppResult.Err -> result
                    is AppResult.Ok -> result.value?.let { AppResult.Ok(ownProfileOf(uid, it, imageUrls)) } ?: AppResult.Err(AppError.NotFound)
                }
            },
        )
    }

    override suspend fun fetchPublic(uid: Uid): AppResult<PublicProfileView> {
        val ref = try {
            DocRef.publicProfile(uid)
        } catch (e: IllegalArgumentException) {
            // 空や `/` を含む uid。取得せずに代替表示（AuthorProfileCache と同じ扱い）
            return AppResult.Ok(PublicProfileView.fallback(uid))
        }
        return when (val result = reader.get(ref)) {
            is AppResult.Err -> result
            is AppResult.Ok -> AppResult.Ok(publicProfileOf(uid, result.value, imageUrls))
        }
    }

    override suspend fun ownPostsPage(after: RawCursor?): AppResult<FeedPage> {
        val uid = currentUid() ?: return AppResult.Err(AppError.PermissionDenied)
        // サーバーから読む理由はフィードと同じ（DefaultFeedRepository.loadPage）
        return when (val result = reader.query(QuerySpec.OwnPosts(uid, after), ReadSource.SERVER)) {
            is AppResult.Err -> result
            is AppResult.Ok ->
                AppResult.Ok(postReader.feedPageOf(result.value, QuerySpec.OwnPosts.PAGE_SIZE, PostDecodeSource.USER_POSTS, analytics))
        }
    }

    override suspend fun userPublicPostsPage(uid: Uid, after: RawCursor?): AppResult<FeedPage> =
        // 公開投稿は rules が誰にでも許すので、ログインしているかは見ない
        // サーバーから読む理由はフィードと同じ（DefaultFeedRepository.loadPage）
        when (val result = reader.query(QuerySpec.UserPublicPosts(uid, after), ReadSource.SERVER)) {
            is AppResult.Err -> result
            is AppResult.Ok ->
                AppResult.Ok(postReader.feedPageOf(result.value, QuerySpec.UserPublicPosts.PAGE_SIZE, PostDecodeSource.PUBLIC_POSTS, analytics))
        }

    private companion object {
        /** 項目名は iOS の `User`・`PublicProfile` の Firestore 上の名前と同じ。 */
        const val FIELD_ID = "id"
        const val FIELD_DISPLAY_NAME = "displayName"
        const val FIELD_PHOTO_URL = "photoURL"
        const val FIELD_BIO = "bio"
        const val FIELD_POSTS_COUNT = "postsCount"

        /** 自分のユーザー文書を [OwnProfile] にする。表示名・自己紹介は読んだまま（空白だけでも）持つ。 */
        fun ownProfileOf(uid: Uid, document: RawDocument, imageUrls: RemoteImageUrlPolicy): OwnProfile =
            OwnProfile(
                uid = uid,
                displayName = document.data[FIELD_DISPLAY_NAME] as? String,
                photoUrl = remoteImageUrlOf(document.data[FIELD_PHOTO_URL], imageUrls),
                bio = document.data[FIELD_BIO] as? String,
                postsCount = countOf(document.data[FIELD_POSTS_COUNT]),
            )

        /**
         * 公開プロフィールのドキュメントを表示に変える。中の `id` を要求した [uid] と比べる判定は、
         * AuthorProfileCache の displayOf（iOS の `PublicProfile(from:documentId:)`・issue #133）と同じ。
         */
        fun publicProfileOf(uid: Uid, document: RawDocument?, imageUrls: RemoteImageUrlPolicy): PublicProfileView {
            if (document == null || document.data[FIELD_ID] as? String != uid.value) return PublicProfileView.fallback(uid)
            // アイコンの URL は、画面で読み込んでよいもの（このビルドの Storage のダウンロード URL）だけを使う
            val photoUrl = remoteImageUrlOf(document.data[FIELD_PHOTO_URL], imageUrls)
            val name = (document.data[FIELD_DISPLAY_NAME] as? String)?.takeIf { it.isNotBlank() }
            return PublicProfileView(
                uid = uid,
                author = if (name != null) AuthorDisplay.Named(name, photoUrl) else AuthorDisplay.Fallback(photoUrl),
                bio = document.data[FIELD_BIO] as? String,
                postsCount = countOf(document.data[FIELD_POSTS_COUNT]),
            )
        }

        /** 数として読めれば Long に、それ以外（欠落・文字列など）は 0。 */
        fun countOf(value: Any?): Long = (value as? Number)?.toLong() ?: 0L
    }
}
