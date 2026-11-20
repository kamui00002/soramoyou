// ⭐️ Firestore へ書くドキュメントの組み立て（タスク 13.2・要件 2.10・3.1〜3.5）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.model.FeedbackCategory
import com.yoshidometoru.soramoyou.contract.model.ReportReason
import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import com.yoshidometoru.soramoyou.contract.model.Visibility
import java.time.Instant

// 組み立ては純関数で、Firebase の型を参照しない（設計書 :500-552）。Firebase の値（Timestamp など）への変換は
// `:app` のゲートウェイが受け持つ。戻り値は、対応する契約（[ShapeContracts]）に必ず合格する
// （DocumentBuildersTest が全ての出力を検証する）。
//
// 任意の項目に値が無いときは、null や空文字を書かず、キーごと省略する（要件 3.5・FsValue は null を表現できない）。

/**
 * 公開プロフィールを `users` から補完するときの、写す元の値（設計書 :548 の `UserProfileFields`）。
 * iOS の `PublicProfile(from: user)`（PublicProfile.swift:61-75）が写す項目のうち、`publicProfiles` の作成の契約が
 * 許すものだけを持つ（`customEditTools` などは Android MVP が書かないので持たない）。
 *
 * @property photoUrl 書き込むときのキー名は iOS の綴りの `photoURL`。
 */
data class UserProfileFields(
    val displayName: String?,
    val photoUrl: String?,
    val bio: String?,
    val followersCount: Long,
    val followingCount: Long,
    val postsCount: Long,
)

/**
 * 1 つの項目の変更（設計書 :538-541）。プロフィールの編集で、項目ごとに「変えない・この値にする・空にする」を表す。
 * 空にする（[Clear]）は、キーの削除（`FieldValue.delete()`）として書く（設計書 QD・要件 3.5）。
 */
sealed interface FieldChange<out T> {
    /** 変えない。キーを出力しない。 */
    data object Unchanged : FieldChange<Nothing>

    /** この値にする。 */
    data class Set<T>(val value: T) : FieldChange<T>

    /** 空にする。キーを削除する。 */
    data object Clear : FieldChange<Nothing>
}

/**
 * プロフィールの編集の内容（設計書 :543）。`users` と `publicProfiles` の両方の更新に同じものを使う。
 *
 * @property photoUrl 書き込むときのキー名は iOS の綴りの `photoURL`。
 */
data class ProfileChange(
    val displayName: FieldChange<String>,
    val bio: FieldChange<String>,
    val photoUrl: FieldChange<String>,
)

/**
 * アップロード済みの 1 枚の画像（設計書 :528-531）。投稿の `images` の 1 要素になる。
 *
 * @property url 本体のダウンロード URL。
 * @property thumbnailUrl サムネイルのダウンロード URL。書き込むときのキー名は iOS の綴りの `thumbnail`。
 * @property widthPx 本体 JPEG の幅（px）。書き込むときのキー名は `width`（整数）。
 * @property heightPx 本体 JPEG の高さ（px）。書き込むときのキー名は `height`（整数）。
 * @property order 0 から始まる表示順。
 * @property storagePath 本体の Storage のパス（`posts/{uid}/{公開範囲}/{画像ID}.jpg`）。
 * @property thumbnailStoragePath サムネイルの Storage のパス（`thumbnails/{uid}/{公開範囲}/{画像ID}_thumb.jpg`）。
 */
data class UploadedImage(
    val url: String,
    val thumbnailUrl: String,
    val widthPx: Int,
    val heightPx: Int,
    val order: Int,
    val storagePath: StoragePath,
    val thumbnailStoragePath: StoragePath,
)

/**
 * 新しい投稿の内容（設計書 :532-536）。
 *
 * @property caption 前後の空白を取り除いた後の値。空なら `null` にして渡す（取り除くのも `null` にするのも呼び出し側の責任）。
 * @property hashtags キャプションから抽出したハッシュタグ（[com.yoshidometoru.soramoyou.contract.rules.HashtagExtractor]）。0 件なら空の配列。
 * @property capturedAt 撮影日時。読めなければ `null`。
 * @property timeOfDay 撮影日時から決めた時間帯。[capturedAt] が `null` のときは `null` にする（要件 7.14。呼び出し側の責任）。
 * @property createdAt 端末の時刻（QC）。`updatedAt` にも同じ値を入れる。
 */
data class NewPost(
    val postId: PostId,
    val userId: Uid,
    val images: List<UploadedImage>,
    val visibility: Visibility,
    val caption: String?,
    val hashtags: List<String>,
    val capturedAt: Instant?,
    val timeOfDay: TimeOfDay?,
    val createdAt: Instant,
)

/**
 * 送るフィードバックの内容（設計書 :954 の `FeedbackInput`。`:contract` の組み立てが受け取るので、ここに置く）。
 *
 * メールアドレスと表示名は持たない（要件 13.4）。型に無いので、組み立てから出ることが無い。
 *
 * @property message 前後の空白を取り除いた後の、空白だけでない本文。取り除くのも空白だけを断るのも入力の段階の責任
 *   （[com.yoshidometoru.soramoyou.contract.rules.TextLimits] の `trimWhitespace`・`isBlank`・`isFeedbackWithinLimit`）。
 *   組み立ては直さずそのまま出し、契約が止める（NewPost.caption と同じ方針）。
 * @property category 種別。選ばなければ `null` にして渡す（キーを書かない）。
 * @property appVersion 「バージョン名 (バージョンコード)」の形のアプリのバージョン。`null` か空文字なら、キーを書かない。
 * @property deviceInfo 「Android {OSの版} / {機種名}」の形の端末情報。`null` か空文字なら、キーを書かない。
 */
data class FeedbackInput(
    val userId: Uid,
    val message: String,
    val category: FeedbackCategory?,
    val appVersion: String?,
    val deviceInfo: String?,
)

/**
 * ブロック中のユーザーの一覧への 1 件の変更（設計書 :555 の `BlockChange`）。1 回の書き込みで変えるのは 1 人だけ（要件 11.4・11.5）。
 */
sealed interface BlockChange {
    /** [uid] をブロックする。`blockedUserIds` への追加（`arrayUnion`）になる。 */
    data class Block(val uid: Uid) : BlockChange

    /** [uid] のブロックを解除する。`blockedUserIds` からの削除（`arrayRemove`）になる。 */
    data class Unblock(val uid: Uid) : BlockChange
}

object DocumentBuilders {

    /**
     * `users/{uid}` の作成（契約 [ShapeContracts.USER_CREATE]）。
     *
     * @param email あるときだけ `email` を書く。`null`（匿名アカウントなど）では**キー自体を出力しない**（要件 3.3）。
     *   空文字は「無い」とは見なさず、そのまま出す（変換しない）。契約の長さの検査（1..254）が止める。
     *   メールアドレスの形式の検査は入力の段階（EmailValidator）の責務で、ここでは行わない。
     * @param now 端末の時刻（QC）。`createdAt` と `updatedAt` に同じ値を入れる（User.swift:109-110）。
     */
    fun userCreate(uid: Uid, email: String?, now: Instant): FsDocument = buildMap {
        put("id", FsValue.Str(uid.value))
        put("createdAt", FsValue.Time(now))
        put("updatedAt", FsValue.Time(now))
        if (email != null) put("email", FsValue.Str(email))
        // 新規のカウンタは整数の 0（要件 3.1。FsValue は小数を持たないので Int64 になる）
        put("followersCount", FsValue.Int64(0L))
        put("followingCount", FsValue.Int64(0L))
        put("postsCount", FsValue.Int64(0L))
        // 通知設定の既定値（要件 3.2）
        put("notifyReactions", FsValue.Bool(true))
        put("notifyNewPostsFromFollowing", FsValue.Bool(true))
        put("notifyNewPostsFromEveryone", FsValue.Bool(false))
    }

    /**
     * `publicProfiles/{uid}` の作成（契約 [ShapeContracts.PUBLIC_PROFILE_CREATE]）。
     *
     * @param source `null` なら新規（任意項目なし・カウンタは 0）。補完のときは `users` の表示名・アイコン・自己紹介・
     *   カウンタを写す（要件 3.7）。値が `null` または空文字の任意項目は、キーごと省略する（要件 3.5）。
     *   `users` から読んだ値には空文字が混ざりうるので、補完を止めずに省略する。
     * @param now 端末の時刻（QC）。`createdAt` と `updatedAt` に同じ値を入れる。
     *   ⚠️ iOS の補完（`PublicProfile(from: user)`）は `users` の `createdAt`・`updatedAt` を写すが、設計書の署名は
     *   `now` だけなので、Android は補完でも `now` を入れる。
     */
    fun publicProfileCreate(uid: Uid, source: UserProfileFields?, now: Instant): FsDocument = buildMap {
        put("id", FsValue.Str(uid.value))
        put("createdAt", FsValue.Time(now))
        put("updatedAt", FsValue.Time(now))
        source?.displayName?.takeIf { it.isNotEmpty() }?.let { put("displayName", FsValue.Str(it)) }
        source?.photoUrl?.takeIf { it.isNotEmpty() }?.let { put("photoURL", FsValue.Str(it)) }
        source?.bio?.takeIf { it.isNotEmpty() }?.let { put("bio", FsValue.Str(it)) }
        put("followersCount", FsValue.Int64(source?.followersCount ?: 0L))
        put("followingCount", FsValue.Int64(source?.followingCount ?: 0L))
        put("postsCount", FsValue.Int64(source?.postsCount ?: 0L))
    }

    /**
     * プロフィールの更新（契約 [ShapeContracts.USER_PROFILE_UPDATE]・[ShapeContracts.PUBLIC_PROFILE_UPDATE]。同じ出力を両方に使う）。
     * 変えた項目と `updatedAt` だけを出す部分更新（要件 3.6・10.6）。
     *
     * - [FieldChange.Unchanged]：キーを出さない
     * - [FieldChange.Set]：その文字列を書く。空文字は「空にする」とは見なさず、そのまま出す（変換しない）。契約の
     *   「1 文字以上」が止める（空にするのは [FieldChange.Clear] の役目。取り違えを黙って直さない。userCreate の email と同じ方針）
     * - [FieldChange.Clear]：キーの削除（`FieldValue.delete()`。設計書 QD）
     *
     * @param now 端末の時刻（QC。iOS の updatePublicProfileFields も端末の時刻）。
     */
    fun profileUpdate(change: ProfileChange, now: Instant): FsDocument = buildMap {
        put("updatedAt", FsValue.Time(now))
        putChange("displayName", change.displayName)
        putChange("bio", change.bio)
        putChange("photoURL", change.photoUrl)
    }

    /**
     * `likes/{uid}_{postId}` の作成（契約 [ShapeContracts.LIKE_CREATE]）。3 項目だけを出す（要件 9.3）。
     * ドキュメント ID（`{uid}_{postId}`）は書き込み先の側（`:app` の DocRef.like）が作る。
     *
     * @param now 端末の時刻（QC。Like.swift:38）。
     */
    fun likeCreate(userId: Uid, postId: PostId, now: Instant): FsDocument = mapOf(
        "userId" to FsValue.Str(userId.value),
        "postId" to FsValue.Str(postId.value),
        "createdAt" to FsValue.Time(now),
    )

    /**
     * 投稿のいいね数の増減（契約 [ShapeContracts.POST_LIKE_COUNTER]）。`likesCount` の加算だけを出し、`updatedAt` は書かない（要件 9.5）。
     * [delta] が ±1 以外でも直さずにそのまま出す。契約の「±1 のみ」が止める（取り違えを黙って直さない。profileUpdate と同じ方針）。
     */
    fun likeCounter(delta: Int): FsDocument = mapOf("likesCount" to FsValue.Increment(delta.toLong()))

    /**
     * 投稿のコメント数の増減（契約 [ShapeContracts.POST_COMMENT_COUNTER]。退会でコメントを消すとき：タスク 31.3）。
     * `commentsCount` の加算だけを出し、`updatedAt` は書かない（isCountOnlyUpdate が拒否するため）。
     * [delta] が -1 以外でも直さずにそのまま出す。契約の「-1 のみ」が止める（取り違えを黙って直さない。[likeCounter] と同じ方針）。
     */
    fun commentCounter(delta: Int): FsDocument = mapOf("commentsCount" to FsValue.Increment(delta.toLong()))

    /**
     * `posts/{postId}` の作成（契約 [ShapeContracts.POST_CREATE]、画像は [ShapeContracts.POST_IMAGE]）。
     *
     * - 常に書く：`postId`・`userId`・`images`・`visibility`・`likesCount`＝0・`commentsCount`＝0・`createdAt`・`updatedAt`（`createdAt` と同値）
     * - 値があるときだけ書く：`caption`（`null` なら省略）・`hashtags`（空なら省略）・`capturedAt`・`timeOfDay`（`null` なら省略）
     *
     * 空文字のキャプション・31 個以上のハッシュタグ・範囲外の幅などは、直さずにそのまま出す。契約が止める
     * （取り違えを黙って直さない。userCreate の email・likeCounter と同じ方針）。
     * 画像は [NewPost.images] の並びのまま書く（`order` も渡された値のまま）。
     */
    fun postCreate(input: NewPost): FsDocument = buildMap {
        put("postId", FsValue.Str(input.postId.value))
        put("userId", FsValue.Str(input.userId.value))
        put("images", FsValue.MapList(input.images.map(::postImage)))
        put("visibility", FsValue.Str(input.visibility.raw))
        // 作成時のカウンタは整数の 0。無いと isCountOnlyUpdate が評価できず、誰もいいねできない
        put("likesCount", FsValue.Int64(0L))
        put("commentsCount", FsValue.Int64(0L))
        put("createdAt", FsValue.Time(input.createdAt))
        put("updatedAt", FsValue.Time(input.createdAt))
        input.caption?.let { put("caption", FsValue.Str(it)) }
        if (input.hashtags.isNotEmpty()) put("hashtags", FsValue.StrList(input.hashtags))
        input.capturedAt?.let { put("capturedAt", FsValue.Time(it)) }
        input.timeOfDay?.let { put("timeOfDay", FsValue.Str(it.raw)) }
    }

    /**
     * 投稿数の更新（契約 [ShapeContracts.USER_POSTS_COUNT]・[ShapeContracts.PUBLIC_PROFILE_POSTS_COUNT]。同じ出力を両方に使う）。
     * `postsCount` だけを値で出す（iOS の recountPostsCount と同じ。数え直した値で上書きする）。負の値も直さずに出し、契約が止める。
     */
    fun postsCount(count: Long): FsDocument = mapOf("postsCount" to FsValue.Int64(count))

    /**
     * `reports/{自動ID}` の作成（契約 [ShapeContracts.REPORT_CREATE]）。5 項目だけを出す（要件 11.2）。
     * 作成日時は端末の時刻でなくサーバー時刻（[FsValue.ServerTime]）なので、`now` を受け取らない（iOS：FirestoreService.swift:1150）。
     * 理由は [ReportReason.raw] で書く。空の ID などは直さずにそのまま出し、契約が止める（取り違えを黙って直さない）。
     *
     * @param reporterId 通報する人（自分）の uid。
     * @param reportedUserId 通報される投稿の投稿者の uid。
     */
    fun reportCreate(postId: PostId, reporterId: Uid, reportedUserId: Uid, reason: ReportReason): FsDocument = mapOf(
        "postId" to FsValue.Str(postId.value),
        "reporterId" to FsValue.Str(reporterId.value),
        "reportedUserId" to FsValue.Str(reportedUserId.value),
        "reason" to FsValue.Str(reason.raw),
        "createdAt" to FsValue.ServerTime,
    )

    /**
     * `feedback/{UUID}` の作成（契約 [ShapeContracts.FEEDBACK_CREATE]）。
     *
     * - 常に書く：`userId`・`message`・`createdAt`（サーバー時刻）
     * - 値があるときだけ書く：`category`（`null` なら省略）・`appVersion`・`deviceInfo`（`null` か空文字なら省略。要件 13.2）
     *
     * 本文は前後の空白を取り除かず、そのまま出す。空白だけの本文・1000 を超える本文も直さず、契約が止める
     * （取り除くのは入力の段階の責任：[FeedbackInput.message]）。
     * ドキュメント ID（大文字の UUID）は書き込み先の側が作る。
     */
    fun feedbackCreate(input: FeedbackInput): FsDocument = buildMap {
        put("userId", FsValue.Str(input.userId.value))
        put("message", FsValue.Str(input.message))
        put("createdAt", FsValue.ServerTime)
        input.category?.let { put("category", FsValue.Str(it.raw)) }
        input.appVersion?.takeIf { it.isNotEmpty() }?.let { put("appVersion", FsValue.Str(it)) }
        input.deviceInfo?.takeIf { it.isNotEmpty() }?.let { put("deviceInfo", FsValue.Str(it)) }
    }

    /**
     * `users/{uid}` のブロック中のユーザーの追加・削除（契約 [ShapeContracts.USER_BLOCKED_IDS]）。
     * `blockedUserIds` への `arrayUnion`／`arrayRemove` を 1 要素だけ出し、`updatedAt` は書かない（iOS：FirestoreService.swift:1174-1194）。
     * 空の uid などは直さずにそのまま出す。
     */
    fun blockedUserIds(change: BlockChange): FsDocument = when (change) {
        is BlockChange.Block -> mapOf("blockedUserIds" to FsValue.ArrayUnion(listOf(change.uid.value)))
        is BlockChange.Unblock -> mapOf("blockedUserIds" to FsValue.ArrayRemove(listOf(change.uid.value)))
    }

    /** 投稿の `images` の 1 要素。幅・高さ・表示順は整数で書く（iOS は `as? Int` で読む：ImageInfo.swift:80-86）。 */
    private fun postImage(image: UploadedImage): Map<String, FsValue> = mapOf(
        "url" to FsValue.Str(image.url),
        "width" to FsValue.Int64(image.widthPx.toLong()),
        "height" to FsValue.Int64(image.heightPx.toLong()),
        "order" to FsValue.Int64(image.order.toLong()),
        "thumbnail" to FsValue.Str(image.thumbnailUrl),
        "storagePath" to FsValue.Str(image.storagePath.value),
        "thumbnailStoragePath" to FsValue.Str(image.thumbnailStoragePath.value),
    )

    /** [change] に応じて、[key] に値を書く・削除を書く・何も書かない。 */
    private fun MutableMap<String, FsValue>.putChange(key: String, change: FieldChange<String>) {
        when (change) {
            FieldChange.Unchanged -> Unit
            is FieldChange.Set -> put(key, FsValue.Str(change.value))
            FieldChange.Clear -> put(key, FsValue.DeleteField)
        }
    }
}
