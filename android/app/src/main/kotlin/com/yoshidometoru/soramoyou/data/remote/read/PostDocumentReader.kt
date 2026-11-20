// ⭐️ 投稿ドキュメントを 1 件ずつ表示用に変換する。読めない 1 件だけを飛ばして記録する（タスク 7.2・要件 4.7・4.8・4.10・4.11）
package com.yoshidometoru.soramoyou.data.remote.read

import com.google.firebase.Timestamp
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.model.SkyType
import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.model.PostImageView
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.PostDecodeSource
import com.yoshidometoru.soramoyou.platform.logPostDecodeFailed
import java.time.Instant

/** 1 件の投稿ドキュメントを変換した結果（設計書 :716）。 */
sealed interface ReadOutcome {
    /** 表示できる投稿。 */
    data class Ok(val post: PostView) : ReadOutcome

    /**
     * 表示できないので飛ばす投稿。
     *
     * @property path ドキュメントのパス（例：`posts/abc123`）。
     * @property reason 飛ばした理由（[DefaultPostDocumentReader] の REASON_ の値）。
     */
    data class Skipped(val path: String, val reason: String) : ReadOutcome
}

/**
 * 投稿ドキュメントを表示用の [PostView] に変換する（設計書の PostDocumentReader。:713-721）。
 * [read] は変換だけを行い、記録はしない。取得元（フィード・プロフィールなど）を知っているのは呼び出し側なので、
 * ページ単位の変換と記録は [readAll] で行う（設計書のフィード読み込みフロー :289「失敗は除外してパスを記録」はリポジトリの側）。
 */
interface PostDocumentReader {
    fun read(raw: RawDocument): ReadOutcome
}

/**
 * [documents] を順に変換し、表示できる投稿だけを元の順で返す（iOS の `PostDocumentDecoder.decodePosts`。PR #150）。
 * 飛ばした 1 件ごとに、分析イベント `post_decode_failed`（[source]・パス・理由）を送る。**Crashlytics には送らない**
 * （[AnalyticsFacade.logError] を使わない。壊れた 1 件で全ユーザーの表示のたびに積み上がるため：設計書 QE）。
 *
 * ページングの起点と「続きなし」の判定は、ここで返す件数でなく変換前の [documents] で行うこと（設計書 :721）。
 */
fun PostDocumentReader.readAll(
    documents: List<RawDocument>,
    source: PostDecodeSource,
    analytics: AnalyticsFacade,
): List<PostView> = documents.mapNotNull { raw ->
    when (val outcome = read(raw)) {
        is ReadOutcome.Ok -> outcome.post
        is ReadOutcome.Skipped -> {
            // 壊れた 1 件は記録して飛ばし、ページの他の投稿は生かす（要件 4.10）
            analytics.logPostDecodeFailed(source, outcome.path, outcome.reason)
            null
        }
    }
}

/**
 * [PostDocumentReader] の実装。依存を持たない純粋な変換である。
 *
 * @param imageUrls 画面で読み込んでよい画像の URL の形（ビルドの変種ごとに 1 つ。AppContainer が渡す）。
 */
class DefaultPostDocumentReader(private val imageUrls: RemoteImageUrlPolicy) : PostDocumentReader {
    override fun read(raw: RawDocument): ReadOutcome {
        val data = raw.data
        // 必須の 1 点目：投稿者の uid（文字列）
        val userId = data["userId"] as? String ?: return skipped(raw, REASON_MISSING_REQUIRED_FIELDS)
        // 必須の 2 点目：URL が文字列の画像が 1 件以上。URL の無い画像だけを落とし、投稿は落とさない
        val rawImages = data["images"] as? List<*> ?: return skipped(raw, REASON_INVALID_IMAGES)
        val images = rawImages.mapNotNull(::imageOf)
        if (images.isEmpty()) return skipped(raw, REASON_NO_IMAGE_WITH_URL)

        return ReadOutcome.Ok(
            PostView(
                // ドキュメント内の postId より、ドキュメント ID を優先する（iOS は両者を同じ値で書く：PostViewModel.swift:885）
                postId = PostId(raw.id),
                userId = Uid(userId),
                // order の昇順。読めない order は末尾へ（sortedWith は安定なので、元の並びが保たれる）
                images = images.sortedWith(compareBy(nullsLast()) { it.order }),
                caption = data["caption"] as? String,
                hashtags = stringsOf(data["hashtags"]),
                visibility = Visibility.fromRaw(data["visibility"] as? String),
                likesCount = data["likesCount"] as? Long ?: 0L,
                createdAt = instantOf(data["createdAt"]),
                capturedAt = instantOf(data["capturedAt"]),
                timeOfDay = TimeOfDay.fromRaw(data["timeOfDay"] as? String),
                skyType = SkyType.fromRaw(data["skyType"] as? String),
            ),
        )
    }

    /**
     * 1 件の画像。`url` がこのビルドの Storage のダウンロード URL の形でなければ null（その画像だけを落とす）。整数は SDK が Long で返すので、Long だけを読む。
     * `url`・`thumbnail` は、画面で読み込んでよいものだけを通す（[remoteImageUrlOf]）。
     */
    private fun imageOf(value: Any?): PostImageView? {
        val map = value as? Map<*, *> ?: return null
        val url = remoteImageUrlOf(map["url"], imageUrls) ?: return null
        return PostImageView(
            url = url,
            thumbnail = remoteImageUrlOf(map["thumbnail"], imageUrls),
            width = map["width"] as? Long,
            height = map["height"] as? Long,
            order = map["order"] as? Long,
        )
    }

    private fun skipped(raw: RawDocument, reason: String): ReadOutcome =
        // RawDocument はパスを持たないので、コレクション名と ID から作る（綴りは書き込み先と同じ DocRef.post に任せる）
        ReadOutcome.Skipped(DocRef.post(PostId(raw.id)).path, reason)

    companion object {
        /** `userId` が無いか文字列でない（iOS の `PostModelError.missingRequiredFields` と同じ名前。Post.swift:213-218）。 */
        const val REASON_MISSING_REQUIRED_FIELDS = "missingRequiredFields"

        /** `images` が無いか配列でない（iOS の `PostModelError.invalidImages` と同じ名前。Post.swift:224-228）。 */
        const val REASON_INVALID_IMAGES = "invalidImages"

        /**
         * `images` は配列だが、`url` がこのビルドの Storage のダウンロード URL の形の画像が 1 件も無い（文字列でない・形に合わない）。iOS はこの投稿を飛ばさず画像 0 枚で読むので、iOS には無い名前にした
         * （同じ名前にすると、PostHog で iOS と比べたときに意味がずれる）。
         */
        const val REASON_NO_IMAGE_WITH_URL = "noImageWithUrl"
    }
}

/** 文字列の配列。文字列でない要素が 1 つでもあれば、全体を null にする（iOS の `as? [String]` と同じ：Post.swift:283）。 */
private fun stringsOf(value: Any?): List<String>? {
    val list = value as? List<*> ?: return null
    return if (list.all { it is String }) list.map { it as String } else null
}

/** SDK の Timestamp を、ナノ秒まで保って Instant にする。Timestamp でなければ null。 */
private fun instantOf(value: Any?): Instant? =
    (value as? Timestamp)?.let { Instant.ofEpochSecond(it.seconds, it.nanoseconds.toLong()) }
