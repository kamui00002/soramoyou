// ⭐️ 投稿の文書を作り、投稿数の数え直し・post_completed・一覧への反映を行う（設計書の部品 PostPublisher の後半。タスク 23.3・要件 7.10〜7.14・7.17〜7.20・7.22・15.3）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.contract.document.NewPost
import com.yoshidometoru.soramoyou.contract.document.ShapeContracts
import com.yoshidometoru.soramoyou.contract.document.UploadedImage
import com.yoshidometoru.soramoyou.data.image.CapturedAtSource
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.PostDocumentReader
import com.yoshidometoru.soramoyou.data.remote.read.ReadOutcome
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.data.remote.write.toSdkData
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import java.time.Clock
import java.time.Instant

/**
 * [PostDocumentSaver] の実装（[DefaultPostPublisher] が全ての画像を上げ終えてから 1 回呼ぶ）。順序は iOS と同じ
 * （`FirestoreService.createPost`：FirestoreService.swift:216-234 → `PostViewModel.savePost` の続き：PostViewModel.swift:614-677）：
 *
 * 1. `posts/{postId}` を作る（[DocumentBuilders.postCreate]・契約 [ShapeContracts.POST_CREATE]・可否は [WriteCapability.POST_CREATE]）。
 *    失敗したら記録して `Err` を返す（画像は [DefaultPostPublisher] が消す。要件 7.18）
 * 2. 投稿数を数え直す（[PostsCountSynchronizer.recount]。終わるまで待つ）。`Err` は記録し直さずに無視する（記録は数え直しの部品が済ませる。要件 7.20）
 * 3. `post_completed` を送る（値は [postCompletedParams]。要件 15.3）
 * 4. 作った投稿を [createdPosts] で知らせ、フィードと自分のプロフィールの一覧に差し込ませる（要件 7.22）
 *
 * 2〜4 のどれが失敗しても `Ok` を返す（文書はできているので、投稿は成功している）。
 *
 * 記録（`error_occurred`）の発生箇所は `PostDocumentSaver.save`。書き込みの入口が自分で断って記録済みのもの
 * （[recordForwardedWriteFailure] が除く `WriteBlocked`・`ShapeViolation`）は記録し直さない。
 *
 * ⚠️ Firestore の書き込みは、オフラインでも失敗せずにサーバーが受け付けるまで待つ（ローカルキャッシュをメモリだけにしていても同じ）。
 *    [DefaultPostPublisher] はこれを取り消さずに呼ぶので、オフラインの間は保存中のまま止まる。表示は投稿画面（タスク 23.5）で扱う。
 *
 * @param reader 知らせる投稿を、書いた文書から作る（フィードが同じ文書を読み返したときと同じ形にするため。[PostView][com.yoshidometoru.soramoyou.data.model.PostView] を作るのは読み取りの部品だけ）。
 * @param clock 端末の時刻（設計書 QC）。1 回の保存で 1 度だけ読み、`createdAt` と `updatedAt` に使う。
 */
class DefaultPostDocumentSaver(
    private val gateway: FirestoreWriteGateway,
    private val countSynchronizer: PostsCountSynchronizer,
    private val reader: PostDocumentReader,
    private val createdPosts: CreatedPosts,
    private val analytics: AnalyticsFacade,
    private val clock: Clock = Clock.systemUTC(),
) : PostDocumentSaver {

    override suspend fun save(post: PreparedPost, images: List<UploadedImage>): AppResult<Unit> {
        // 1. 文書の作成（形を契約で確かめてから書く。同じ postId への set は冪等なので、やり直しても投稿は重複しない）
        val document = DocumentBuilders.postCreate(newPostOf(post, images, Instant.now(clock)))
        val created = gateway.create(WriteCapability.POST_CREATE, DocRef.post(post.postId), ShapeContracts.POST_CREATE, document)
        if (created is AppResult.Err) {
            analytics.recordForwardedWriteFailure(created.error, CONTEXT)
            return created
        }

        // 2. 投稿数の数え直し。失敗しても投稿の成功は覆さない（次の投稿・削除のときにやり直される）
        countSynchronizer.recount(post.uid)

        // 3・4. 計測と一覧への反映
        analytics.logEvent(EventName.POST_COMPLETED, postCompletedParams(post, images.size))
        reflect(post, document)
        return AppResult.Ok(Unit)
    }

    /** 書いた文書 [document] を読み取りの部品に通して、作った投稿を知らせる。読めなければ知らせない（一覧は次の読み直しで出る）。 */
    private fun reflect(post: PreparedPost, document: FsDocument) {
        val outcome = reader.read(RawDocument(post.postId.value, document.toSdkData()))
        if (outcome is ReadOutcome.Ok) createdPosts.notify(outcome.post)
    }

    private fun newPostOf(post: PreparedPost, images: List<UploadedImage>, now: Instant) = NewPost(
        postId = post.postId,
        userId = post.uid,
        images = images,
        visibility = post.visibility,
        caption = post.caption,
        hashtags = post.hashtags,
        capturedAt = post.capturedAt,
        timeOfDay = post.timeOfDay,
        createdAt = now,
    )

    private companion object {
        /** 記録の発生箇所（`クラス名.メソッド名`）。 */
        const val CONTEXT = "PostDocumentSaver.save"
    }
}

/**
 * `post_completed` のパラメータ（設計書「分析イベント一覧」:985。iOS：PostViewModel.swift:614-653）。キーは iOS と同じで、
 * Android に無い機能のパラメータは、iOS でその機能を使わなかったときと同じ値にする（要件 15.3）。
 *
 * - `post_kind`＝`single`・`is_reedit`＝false（Android には合成の投稿と再編集が無い）
 * - `image_count`＝投稿した枚数 [imageCount]・`visibility`＝公開範囲の `raw`
 * - `has_mood`＝false・`mood`＝`none`・`has_location`＝false・`saved_original_images`＝false・`colors_from_sky`＝false・
 *   `photo_source`＝`library`（アプリ内カメラが無い）・`edit_scope_sky_only`＝false
 * - `has_caption`＝前後の空白を取り除いて空でないか（[PreparedPost.caption] は取り除いた後で、空なら null）
 * - `has_captured_at`＝保存した撮影日時の有無・`captured_at_source`＝その出所（`exif`・`asset`。撮影日時が無ければ `none`）
 * - `sky_coverage` はキーごと送らない（iOS も空のマスクを作れなかったときは送らない）
 *
 * 位置・キャプションの本文・ハッシュタグは送らない（PII を入れない）。
 */
internal fun postCompletedParams(post: PreparedPost, imageCount: Int): Map<String, ParamValue> = linkedMapOf(
    "post_kind" to ParamValue.S("single"),
    "is_reedit" to ParamValue.B(false),
    "image_count" to ParamValue.L(imageCount.toLong()),
    "visibility" to ParamValue.S(post.visibility.raw),
    "has_mood" to ParamValue.B(false),
    "mood" to ParamValue.S("none"),
    "has_caption" to ParamValue.B(post.caption != null),
    "has_location" to ParamValue.B(false),
    "saved_original_images" to ParamValue.B(false),
    "has_captured_at" to ParamValue.B(post.capturedAt != null),
    // 保存した撮影日時が無ければ、出所によらず none（iOS の capturedAtSourceForEvent：PostViewModel.swift:406-418）
    "captured_at_source" to ParamValue.S(if (post.capturedAt == null) CapturedAtSource.NONE.raw else post.capturedAtSource.raw),
    "colors_from_sky" to ParamValue.B(false),
    "photo_source" to ParamValue.S("library"),
    "edit_scope_sky_only" to ParamValue.B(false),
)
