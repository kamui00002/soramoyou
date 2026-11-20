// ⭐️ 投稿の公開：入力の検証・画像のアップロードと後片付け・進捗（設計書の部品 PostPublisher。タスク 23.2・要件 7.3・7.6・7.8・7.9・7.14・7.18・7.21）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.UploadedImage
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.contract.rules.HashtagExtractor
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.contract.rules.TimeOfDayResolver
import com.yoshidometoru.soramoyou.data.image.CapturedAt
import com.yoshidometoru.soramoyou.data.image.CapturedAtSource
import com.yoshidometoru.soramoyou.data.image.ImagePipeline
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.data.remote.write.StorageGateway
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import java.time.Instant
import java.time.ZoneId
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * 投稿する 1 枚の写真と、その写真に掛ける編集の内容（Kiro android-edit-tools タスク 2.3・K0・design.md:609）。
 * K0 の時点で焼き込みが見るのは [edit] のフィルターだけ（[ImagePipeline.preparePost]）。
 */
data class PostPhoto(val photo: PickedPhoto, val edit: PhotoEdit)

/**
 * 投稿の入力（設計書 :854。形は Kiro android-edit-tools タスク 2.3・K0 で design.md:610-615 にした）。投稿画面の値をそのまま渡す。
 * 名前は今のまま（端末の下書きは LocalDraft と呼ぶ）。
 *
 * @property photos 選んだ写真と、写真ごとの編集の内容（選択順。1〜10 枚）
 * @property caption キャプションの入力欄の値そのもの（前後の空白は [PostPublisher] が取り除く）
 * @property visibility 公開範囲。既定は公開（要件 7.9）
 * @property firstPhotoCapturedAt 1 枚目の撮影日時。選んだ時に読んだ値。投稿の撮影日時と時間帯はこの値から決め、投稿の時には
 *   写真から読み直さない（写しのファイルからは撮影日時を引けないため。Kiro android-edit-tools タスク 7・A2・design.md:912）。
 *   読めていなければ null（撮影日時・時間帯とも無し）
 */
data class PostDraft(
    val photos: List<PostPhoto>,
    val caption: String,
    val visibility: Visibility = Visibility.PUBLIC,
    val firstPhotoCapturedAt: CapturedAt?,
)

/**
 * 投稿の進み具合（設計書 :855-861。要件 7.21）。[PostPublisher.state] で公開する。
 * 次の [PostPublisher.publish] が上書きするまで、最後の状態（成功・失敗）のまま残る。
 */
sealed interface PublishState {
    data object Idle : PublishState

    /** 画像を上げている。[done] 枚（本体とサムネイルの両方）を上げ終えた。全部で [total] 枚。 */
    data class Uploading(val done: Int, val total: Int) : PublishState

    /** 全ての画像を上げ終え、投稿の文書を保存している。 */
    data object Saving : PublishState

    data class Succeeded(val postId: PostId) : PublishState
    data class Failed(val error: AppError) : PublishState
}

/**
 * 検証と下ごしらえを終えた投稿。[PostDocumentSaver] に渡し、タスク 23.3 が投稿の文書に組み立てる。
 *
 * @property postId 投稿の開始時に 1 回だけ作った ID（大文字の UUID。設計書 :372）
 * @property uid 投稿者（ログイン中の uid）
 * @property visibility 公開範囲。画像のパスの公開範囲と同じ値（要件 7.3）
 * @property caption 前後の空白を取り除いたキャプション。空なら null（キーごと省略する。iOS：PostViewModel.swift:859, 892）
 * @property hashtags キャプションから抽出したハッシュタグ（出現順・重複込み。0〜30 個。要件 7.7・7.8）
 * @property capturedAt 先頭の写真の撮影日時。無ければ null（要件 7.14・7.16）
 * @property timeOfDay [capturedAt] を端末のタイムゾーンの「時」にして決めた時間帯。[capturedAt] が無ければ null（要件 7.15）
 * @property capturedAtSource 撮影日時の出所（`post_completed` に載せる。無ければ [CapturedAtSource.NONE]）
 *
 * 掛けたフィルターの項目は持たない（読む所が無く、写真ごとの編集になったため。Kiro android-edit-tools タスク 2.3・K0・design.md:616）。
 */
data class PreparedPost(
    val postId: PostId,
    val uid: Uid,
    val visibility: Visibility,
    val caption: String?,
    val hashtags: List<String>,
    val capturedAt: Instant?,
    val timeOfDay: TimeOfDay?,
    val capturedAtSource: CapturedAtSource,
)

/**
 * 投稿の文書を保存する継ぎ目（タスク 23.3 が中身を作る）。[PostPublisher] が全ての画像を上げ終えてから 1 回だけ呼ぶ。
 *
 * - `Ok`：投稿の文書を作った。その後の処理（投稿数の数え直し・`post_completed`・一覧への反映）が失敗しても投稿の成功は覆さないので、
 *   `Ok` のまま返す（要件 7.20）
 * - `Err`：文書を作れなかった。[PostPublisher] が上げた画像を全て消してから失敗を返す（要件 7.18）。
 *   **失敗の記録はこの継ぎ目が行い**、[PostPublisher] は記録し直さない
 *
 * [PostPublisher] は取り消されない文脈（NonCancellable）でこれを呼ぶ。途中で取り消すと、文書ができたかどうか分からないまま
 * 画像を消すことになり、画像の無い投稿を残しうるため。
 */
fun interface PostDocumentSaver {
    suspend fun save(post: PreparedPost, images: List<UploadedImage>): AppResult<Unit>
}

/** 投稿を公開する（設計書の部品 PostPublisher。:862）。 */
interface PostPublisher {

    /** 進み具合（要件 7.21）。画面はこれで進捗を表示し、送信ボタンを押せなくする。 */
    val state: StateFlow<PublishState>

    /**
     * [draft] を投稿する。成功したら投稿の ID を返す。
     *
     * 順序（設計書の投稿作成の流れ：:341-372）：
     * 1. 処理中なら、状態を変えずにすぐ `Validation(PUBLISH_IN_PROGRESS)` を返す（二重送信の防止。要件 7.21）
     * 2. 入力の検証：ログイン中・写真 1〜10 枚・前後の空白を取り除いたキャプションが UTF-16 で 2000 以下・ハッシュタグ 30 個以下
     * 3. 投稿の ID を 1 回だけ作り、先頭の写真から撮影日時と時間帯を決める
     * 4. 写真を選択順に 1 枚ずつ変換し、本体を `posts/{uid}/{公開範囲}/{画像ID}.jpg`、サムネイルを
     *    `thumbnails/{uid}/{公開範囲}/{画像ID}_thumb.jpg` へ上げる（[PublishState.Uploading]）
     * 5. 文書の保存（[PostDocumentSaver]。[PublishState.Saving]）
     *
     * 4 の途中か 5 で失敗したら、**この投稿のために上げようとした全てのパスを消してから**失敗を返す（要件 7.18）。
     * 消す対象には、失敗した 1 枚のパスも含める（iOS は URL まで取れた画像だけを消すので、上げ終わったのに URL の取得だけ
     * 失敗した画像が残る。2026-10-10 ユーザー判断で、Android はそれも消す）。無い（`NotFound`）のは消せたものとみなす。
     *
     * 4 の途中で取り消されたら、上げた画像を消してから [PublishState.Idle] に戻し、取り消しをそのまま伝える。
     * 5 は取り消さずに最後まで行う（[PostDocumentSaver] の注意を参照）。
     *
     * 失敗は [AppResult.Err] で返す（状態は [PublishState.Failed]）。例外は投げない（コルーチンの取り消しを除く）。
     */
    suspend fun publish(draft: PostDraft): AppResult<PostId>
}

/**
 * [PostPublisher] の実装。画像の書き込みは必ず [storage] を通す（可否は [WriteCapability.POST_CREATE]。後片付けの削除も同じ可否で行う。
 * 投稿の後片付けは投稿の作成の一部で、自分の投稿の削除〔POST_DELETE〕とは別の操作のため）。
 *
 * 記録（`error_occurred`）の取り決め：発生箇所は `PostPublisher.publish.<段階>`。
 * - `image`：写真の変換の失敗（変換は記録しないので、ここで記録する。ProfileEditor のアイコンと同じ）
 * - `upload`：アップロードの失敗（入口が断って記録済みの `WriteBlocked`・`ImageTooLarge` は記録し直さない）
 * - `rollback`：後片付けの削除の失敗（`NotFound` は消せたものとみなして記録しない）。上限の時間までに返事が無いものは `Network` として記録する
 * - 入力の不備（二重送信を含む）は、画面が先に止める入力の不備なので記録しない。未ログインは記録する（LikeRepository と同じ）
 * - 文書の保存の失敗は [PostDocumentSaver] が記録する
 *
 * @param currentUid いまログインしているユーザーの uid（いなければ null）。呼ぶたびに読む
 * @param deviceZone 時間帯を決めるタイムゾーン。投稿する端末のタイムゾーンを毎回読む（iOS の `Calendar.current`。[TimeOfDayResolver] の注意を参照）
 * @param newId 投稿の ID と画像の ID を作る。iOS と同じ大文字の UUID（PostViewModel.swift:728, 885）。単体テストでは決まった並びに差し替える
 * @param rollbackDeleteTimeout 後片付けで、パス 1 つの削除を待つ上限（レビュー R07）。Storage の SDK は返事の無い要求を打ち切らず、
 *   オフラインの削除は 1 つのパスごとに再試行の上限まで再試行する見込み（未実測）。上限は SDK の既定では約 10 分（SDK 22.0.2 の削除は
 *   ダウンロードの上限を読む＝クラスの現物）で、アプリは `AppContainer.storage` で 60 秒にしている（レビュー R06）。それでも、この打ち切りが
 *   無いとパスの数×約 60 秒「画像をアップロードしています」のまま、戻る・キャンセルも効かずに止まる。兄弟の [DefaultPostDeleter] の
 *   画像の削除と同じ 30 秒にする（2026-10-11 ユーザー判断の前例）。2026-11-04 に端末で 48MP の写真を 2 枚選び、投稿と同時に接続を
 *   切ったときは、失敗の表示まで約 88〜91 秒だった。60 秒を超えた約 30 秒が、この打ち切りか写真の準備かは測っていない。単体テストでは短くする
 */
class DefaultPostPublisher(
    private val storage: StorageGateway,
    private val pipeline: ImagePipeline,
    private val saver: PostDocumentSaver,
    private val analytics: AnalyticsFacade,
    private val currentUid: () -> Uid?,
    private val hashtags: HashtagExtractor = HashtagExtractor,
    private val deviceZone: () -> ZoneId = ZoneId::systemDefault,
    private val newId: () -> String = { UUID.randomUUID().toString().uppercase() },
    private val rollbackDeleteTimeout: Duration = ROLLBACK_DELETE_TIMEOUT,
) : PostPublisher {

    /** 処理中か（二重送信の防止）。画面のスレッド以外から呼ばれても 1 つだけが通るように、比較と交換を 1 度に行う。 */
    private val running = AtomicBoolean(false)

    private val mutableState = MutableStateFlow<PublishState>(PublishState.Idle)
    override val state: StateFlow<PublishState> = mutableState.asStateFlow()

    override suspend fun publish(draft: PostDraft): AppResult<PostId> {
        if (!running.compareAndSet(false, true)) return AppResult.Err(AppError.Validation(ValidationReason.PUBLISH_IN_PROGRESS))
        try {
            return publishLocked(draft)
        } finally {
            running.set(false)
        }
    }

    private suspend fun publishLocked(draft: PostDraft): AppResult<PostId> {
        // 2. 検証（まだ何も上げていないので、失敗しても消すものは無い）
        val input = when (val validated = validate(draft)) {
            is AppResult.Ok -> validated.value
            is AppResult.Err -> return fail(validated)
        }

        // 3・4. 下ごしらえとアップロード。上げようとしたパスは、上げる前に控える（失敗した 1 枚も後片付けの対象にするため）
        val attempted = mutableListOf<StoragePath>()
        val (post, images) = try {
            // ここから進捗を出す（写真の変換に数秒かかることがあり、その間も送信ボタンを押せなくするため）
            mutableState.value = PublishState.Uploading(done = 0, total = draft.photos.size)
            val post = prepare(draft, input)
            when (val uploaded = uploadAll(post, draft, attempted)) {
                is AppResult.Ok -> post to uploaded.value
                is AppResult.Err -> {
                    rollback(attempted)
                    return fail(uploaded)
                }
            }
        } catch (e: CancellationException) {
            rollback(attempted)
            mutableState.value = PublishState.Idle
            throw e
        }

        // 5. 文書の保存。取り消さない：途中で取り消すと、文書ができたか分からないまま画像を消すことになる。
        //    状態もこの中で決める（取り消された後の再開で、状態や後片付けが入れ違わないように）
        mutableState.value = PublishState.Saving
        return withContext(NonCancellable) {
            when (val saved = saver.save(post, images)) {
                is AppResult.Ok -> {
                    mutableState.value = PublishState.Succeeded(post.postId)
                    AppResult.Ok(post.postId)
                }
                is AppResult.Err -> {
                    rollback(attempted)
                    fail(saved)
                }
            }
        }
    }

    /** 検証を通った入力。 */
    private class ValidInput(val uid: Uid, val caption: String, val hashtags: List<String>)

    /** 入力を検証する：ログイン中・写真の枚数・前後の空白を取り除いたキャプションの長さ・ハッシュタグの個数。 */
    private fun validate(draft: PostDraft): AppResult<ValidInput> {
        val uid = currentUid() ?: return refuseNotSignedIn()
        if (draft.photos.size < TextLimits.IMAGES_MIN) return invalid(ValidationReason.NO_IMAGES)
        if (draft.photos.size > TextLimits.IMAGES_MAX) return invalid(ValidationReason.TOO_MANY_IMAGES)
        val caption = TextLimits.trimWhitespace(draft.caption)
        if (!TextLimits.isCaptionWithinLimit(caption)) return invalid(ValidationReason.CAPTION_TOO_LONG)
        val tags = hashtags.extract(caption)
        if (!TextLimits.isHashtagCountWithinLimit(tags)) return invalid(ValidationReason.TOO_MANY_HASHTAGS)
        return AppResult.Ok(ValidInput(uid, caption, tags))
    }

    /** 投稿の ID を 1 回だけ作り、入力の撮影日時（[PostDraft.firstPhotoCapturedAt]）から撮影日時と時間帯を決める（無ければ両方とも無し。要件 7.16）。 */
    private fun prepare(draft: PostDraft, input: ValidInput): PreparedPost {
        val postId = PostId(newId())
        // 撮影日時は入力の値を使い、投稿の時には読みに行かない（A2：design.md:912）。時間帯の決め方は今のまま
        val captured = draft.firstPhotoCapturedAt
        return PreparedPost(
            postId = postId,
            uid = input.uid,
            visibility = draft.visibility,
            caption = input.caption.ifEmpty { null },
            hashtags = input.hashtags,
            capturedAt = captured?.instant,
            timeOfDay = captured?.let { TimeOfDayResolver.fromLocalHour(it.instant.atZone(deviceZone()).hour) },
            capturedAtSource = captured?.source ?: CapturedAtSource.NONE,
        )
    }

    /**
     * 写真を選択順に 1 枚ずつ変換して上げる（同時に持つ画像を 1 枚分にする）。上げようとしたパスを [attempted] に足していく。
     * 1 枚（本体とサムネイル）を上げ終えるたびに進捗を進める。最初の失敗で止まり、その失敗を返す（後片付けは呼び出し側）。
     */
    private suspend fun uploadAll(post: PreparedPost, draft: PostDraft, attempted: MutableList<StoragePath>): AppResult<List<UploadedImage>> {
        val total = draft.photos.size
        val images = ArrayList<UploadedImage>(total)
        for ((order, postPhoto) in draft.photos.withIndex()) {
            val photo = postPhoto.photo
            val prepared = when (val result = pipeline.preparePost(photo, postPhoto.edit)) {
                is AppResult.Ok -> result.value
                is AppResult.Err -> {
                    analytics.logError(result.error, "$CONTEXT.image")
                    return result
                }
            }
            val imageId = newId()
            val bodyPath = StoragePath.postImage(post.uid, post.visibility, imageId)
            val thumbnailPath = StoragePath.postThumbnail(post.uid, post.visibility, imageId)

            attempted += bodyPath
            val url = when (val result = upload(bodyPath, prepared.body, photo.index)) {
                is AppResult.Ok -> result.value
                is AppResult.Err -> return result
            }
            attempted += thumbnailPath
            val thumbnailUrl = when (val result = upload(thumbnailPath, prepared.thumbnail, photo.index)) {
                is AppResult.Ok -> result.value
                is AppResult.Err -> return result
            }

            // width・height は上げた本体 JPEG の画素の寸法、order は 0 から始まる選択順（設計書 :868）
            images += UploadedImage(
                url = url,
                thumbnailUrl = thumbnailUrl,
                widthPx = prepared.bodyWidth,
                heightPx = prepared.bodyHeight,
                order = order,
                storagePath = bodyPath,
                thumbnailStoragePath = thumbnailPath,
            )
            mutableState.value = PublishState.Uploading(done = order + 1, total = total)
        }
        return AppResult.Ok(images)
    }

    /** [bytes] を [path] へ上げてダウンロード URL を返す。失敗は記録の取り決めに従って記録してから返す。 */
    private suspend fun upload(path: StoragePath, bytes: ByteArray, index: Int): AppResult<String> {
        val result = storage.uploadJpeg(WriteCapability.POST_CREATE, path, bytes, index)
        if (result is AppResult.Err) analytics.recordForwardedStorageFailure(result.error, "$CONTEXT.upload")
        return result
    }

    /**
     * [paths] を全て消す（要件 7.18）。1 つ失敗しても残りを消し続ける。取り消されても最後まで行う（消し残しを作らない）。
     * 無い（`NotFound`）のは消せたものとみなす：上げる前に失敗した 1 枚のパスもここに来るため。
     *
     * 1 つずつ [rollbackDeleteTimeout] まで待ち、返事が無ければ打ち切って `Network` の失敗として記録し、次のパスへ進む（レビュー R07。
     * 兄弟の [DefaultPostDeleter] の画像の削除と同じ形）。NonCancellable の中なので、上限が無いと外からは止められず、
     * 状態が [PublishState.Uploading] のまま（失敗にするのは後片付けの後）画面に閉じ込められるため。
     * 打ち切ったパスは消し残しになりうる（Storage に届いていれば後で終わることもある。PostDeleter と同じベストエフォート）。
     * 後片付けの間の表示の状態は足さない（Uploading のまま。メインの決定）。
     */
    private suspend fun rollback(paths: List<StoragePath>) = withContext(NonCancellable) {
        for (path in paths) {
            val result = withTimeoutOrNull(rollbackDeleteTimeout) { storage.delete(WriteCapability.POST_CREATE, path) }
                ?: AppResult.Err(AppError.Network)
            if (result is AppResult.Err && result.error != AppError.NotFound) {
                analytics.recordForwardedStorageFailure(result.error, "$CONTEXT.rollback")
            }
        }
    }

    /** 状態を失敗にして、その失敗を返す。 */
    private fun fail(result: AppResult.Err): AppResult.Err {
        mutableState.value = PublishState.Failed(result.error)
        return result
    }

    private fun invalid(reason: ValidationReason): AppResult.Err = AppResult.Err(AppError.Validation(reason))

    private fun refuseNotSignedIn(): AppResult.Err {
        analytics.logError(AppError.PermissionDenied, CONTEXT)
        return AppResult.Err(AppError.PermissionDenied)
    }

    private companion object {
        /** 記録の発生箇所の前半（`クラス名.メソッド名`）。後ろに `.段階` を付ける。 */
        const val CONTEXT = "PostPublisher.publish"

        /**
         * 後片付けで、パス 1 つの削除を待つ上限。兄弟の PostDeleter の `IMAGE_DELETE_TIMEOUT`（30 秒）の値を写した
         * （PostDeleter.kt は変えず、共通の定数にもしない：レビュー R07 の決定）。
         */
        val ROLLBACK_DELETE_TIMEOUT: Duration = 30.seconds
    }
}
