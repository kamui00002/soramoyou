// ⭐️ 画面に出す投稿の読み取りのモデル（タスク 7.2・要件 4.7・4.8・4.10・4.11）
package com.yoshidometoru.soramoyou.data.model

import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.model.SkyType
import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import com.yoshidometoru.soramoyou.contract.model.Visibility
import java.time.Instant

/**
 * 画面に出す 1 件の投稿（設計書「読み取りのモデル」の PostView。:1095）。作るのは PostDocumentReader だけである。
 *
 * 表示に必須なのは [userId] と、URL のある画像が 1 件以上あること（[images] は空にならない）だけで、
 * それ以外はドキュメントに無いか型が違えば null になる（要件 4.11）。iOS の `Post` が持つ気分・フレーム・コラージュ・
 * 編集レシピ・位置情報などは、Android が表示しないので持たない。
 *
 * ⚠️ [visibility] が null のとき（未知の値・欠落）、iOS は「公開」に倒して読む（Post.swift:328-331）。
 * ここでは倒さずに null のまま渡し、「読めなかった」と「公開だった」を呼び出し側が区別できるようにする（Visibility.kt の注記）。
 *
 * @property postId ドキュメント ID（ドキュメント内の `postId` より優先する）。
 * @property images 画像を `order` の昇順に並べたもの。`order` が読めない画像は末尾に、元の並びのまま置く。
 * @property likesCount いいね数。欠けているか整数でなければ 0（iOS：Post.swift:293）。0 未満の値は表示のときに 0 にする（9.1）。
 * @property createdAt 作成日時。欠けていれば null（iOS は読んだ時刻で埋めるが、それは真似ない）。
 */
data class PostView(
    val postId: PostId,
    val userId: Uid,
    val images: List<PostImageView>,
    val caption: String?,
    val hashtags: List<String>?,
    val visibility: Visibility?,
    val likesCount: Long,
    val createdAt: Instant?,
    val capturedAt: Instant?,
    val timeOfDay: TimeOfDay?,
    val skyType: SkyType?,
) {
    /** 一覧で見せる 1 枚（`order` が最小の画像。要件 4.8）。[images] は `order` の昇順で、空にならない。 */
    val coverImage: PostImageView get() = images.first()

    /** 画像が複数枚あるか（一覧で複数枚のバッジを付けるため。要件 4.8）。 */
    val hasMultipleImages: Boolean get() = images.size > 1
}

/**
 * 投稿の 1 枚の画像（iOS の `ImageInfo` のうち、表示に使う項目だけ）。
 *
 * iOS は `width`・`height`・`order` のどれかが整数でない画像を黙って落とす（ImageInfo.swift:81-84）。
 * Android は `url` が文字列なら表示できるので、それ以外は null を許して残す（設計書 PostDocumentReader 節）。
 *
 * @property thumbnail サムネイルの URL。無ければ null。
 */
data class PostImageView(
    val url: String,
    val thumbnail: String?,
    val width: Long?,
    val height: Long?,
    val order: Long?,
) {
    /** 一覧で読み込む URL。サムネイルを優先し、無ければ本体（要件 4.7）。 */
    val listUrl: String get() = thumbnail ?: url
}
