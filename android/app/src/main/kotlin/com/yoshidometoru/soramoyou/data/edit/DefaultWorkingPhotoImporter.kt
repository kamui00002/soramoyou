// ⭐️ 選んだ写真をアプリの中へバイトのまま写す（Kiro android-edit-tools タスク 14.3・A4・design.md:930-933, 629-638・要件 8.6・9.7・12.2）
package com.yoshidometoru.soramoyou.data.edit

import android.content.ContentResolver
import android.net.Uri
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.image.CapturedAt
import com.yoshidometoru.soramoyou.data.image.PhotoMetadataReader
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import java.io.IOException
import java.io.InputStream
import kotlin.coroutines.cancellation.CancellationException

/**
 * [WorkingPhotoImporter] の実装（design.md:930-933）。
 *
 * - 写す前に、前の編集の途中（`session/`）を消す。先に文書を消してから残りを消す（前の印の文書を残さない。投稿の後始末の
 *   `clearSession` が、新しい写しを前の印で消さないため：design.md:989）。消せなかったときは 1 枚も写さない（前の文書が残りうるため）
 * - 読めると確かめた写真を、選んだ順に `users/{uid}/session/photo-{番号}` へバイトのまま写す（利用者の判断 U5。番号は並びの 0 始まり）
 * - 撮影日時は **1 枚目だけ**、元の URI から [PhotoMetadataReader.capturedAt] で読む（写せなかったときも読む。ほかの写真は null）。
 *   数秒かかることがあるので、端末の保存の鍵の外で読む
 * - 写せなかった写真は、元の URI のまま（`relativeFile` は null）で返す。失敗は、1 回の呼び出しにつき最初の 1 つだけを
 *   `AppError.Unknown(例外のクラス名)` にして `WorkingPhotoImporter.import` で記録する（場所・本文を入れない：14.5）
 *
 * @param openPhoto 元の写真を開く口（本番は ContentResolver。JVM のテストは手元のバイト列）
 */
class DefaultWorkingPhotoImporter internal constructor(
    private val files: EditFileStore,
    private val openPhoto: (uri: String) -> InputStream,
    private val metadata: PhotoMetadataReader,
    private val analytics: AnalyticsFacade,
) : WorkingPhotoImporter {

    /** 本番の形。写真は [resolver] から URI で開く（写真選択画面の URI は読み取りの権限つきで渡される） */
    constructor(files: EditFileStore, resolver: ContentResolver, metadata: PhotoMetadataReader, analytics: AnalyticsFacade) :
        this(files, { uri -> resolver.openInputStream(Uri.parse(uri)) ?: throw IOException() }, metadata, analytics)

    override suspend fun import(uid: Uid, photos: List<PickedPhoto>): List<WorkingPhoto> {
        val firstCapturedAt = photos.firstOrNull()?.let { readCapturedAt(it) }
        val capturedAtOf: (Int) -> CapturedAt? = { index -> if (index == 0) firstCapturedAt else null }

        val failures = mutableListOf<Exception>()
        val result: List<WorkingPhoto> = try {
            files.locked { copyAll(uid, photos, capturedAtOf, failures) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // 前の途中を消せなかった・フォルダを作れなかった：1 枚も写さず、全部を元の URI のまま返す
            failures += e
            photos.mapIndexed { index, photo -> WorkingPhoto(photo.uri, relativeFile = null, capturedAt = capturedAtOf(index)) }
        }
        failures.firstOrNull()?.let { analytics.logError(AppError.Unknown(it.javaClass.simpleName), CONTEXT_IMPORT) }
        return result
    }

    /** [EditFileStore.locked] の中で呼ぶ。1 枚ごとの失敗は [failures] に足して、その写真を元の URI のまま返す */
    private fun copyAll(
        uid: Uid,
        photos: List<PickedPhoto>,
        capturedAtOf: (Int) -> CapturedAt?,
        failures: MutableList<Exception>,
    ): List<WorkingPhoto> {
        files.deleteTree(files.sessionDocument(uid))
        files.deleteTree(files.sessionDir(uid))
        files.ensureDir(files.sessionDir(uid))
        return photos.mapIndexed { index, photo ->
            val relative = EditFileStore.sessionPhotoPath(index)
            try {
                val target = files.resolve(uid, relative)
                openPhoto(photo.uri).use { files.writeStream(target, it) }
                WorkingPhoto(uri = files.fileUri(target), relativeFile = relative, capturedAt = capturedAtOf(index))
            } catch (e: Exception) {
                failures += e
                WorkingPhoto(uri = photo.uri, relativeFile = null, capturedAt = capturedAtOf(index))
            }
        }
    }

    /** 元の写真の撮影日時。読めなければ null（写しは止めない）。取り消しはそのまま伝える */
    private suspend fun readCapturedAt(photo: PickedPhoto): CapturedAt? = try {
        metadata.capturedAt(photo)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }

    private companion object {
        const val CONTEXT_IMPORT = "WorkingPhotoImporter.import"
    }
}
