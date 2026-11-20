// ⭐️ 編集の途中を端末に保存し、プロセスが落とされた後に戻す（Kiro android-edit-tools タスク 14.3・A4・design.md:935-941, 640-651・要件 12.2〜12.5）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.edit.EditDocumentCodec
import com.yoshidometoru.soramoyou.contract.edit.EditWorkDocument
import com.yoshidometoru.soramoyou.contract.edit.EditWorkPhoto
import com.yoshidometoru.soramoyou.data.image.CapturedAt
import com.yoshidometoru.soramoyou.data.image.CapturedAtSource
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import java.time.Instant
import kotlin.coroutines.cancellation.CancellationException

/**
 * [EditSessionStore] の実装。編集の途中は `users/{uid}/session/work.properties`（利用者ごとに 1 つ。別の uid からは読めない：12.4）。
 *
 * - 途中の保存：文書を書き換える。文書が指す写真（`WorkingPhotoImporter` が置いた写しか、開いた下書きのもの）が全部あることを先に確かめ、
 *   無い写真を指す途中は書かずに失敗にする（戻せない途中を残さない。写しを作れなかった写真を含む編集は、途中の保存ができない：design.md:933）
 * - 途中を読む：文書が無ければ `None`。文書を読めない・指す写真が 1 枚でも無ければ `Unreadable`（12.3）
 * - 失敗は `AppError.Unknown(例外のクラス名)` にして `EditSessionStore.save`・`EditSessionStore.load` で記録する（場所・本文を入れない：14.5）
 * - `clear`・`clearSession` は例外を投げない（取り消しだけはそのまま伝える）。設計の記録の発生箇所に無いので、失敗は記録しない
 */
class DefaultEditSessionStore(
    private val files: EditFileStore,
    private val analytics: AnalyticsFacade,
) : EditSessionStore {

    override suspend fun save(uid: Uid, document: EditWorkDocument): AppResult<Unit> {
        val failure: Exception? = try {
            files.locked {
                document.photos.forEach { files.requirePhoto(uid, it.file) }
                files.writeDocument(files.sessionDocument(uid), encodeReadableWork(document))
            }
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            e
        }
        if (failure == null) return AppResult.Ok(Unit)
        val error = AppError.Unknown(failure.javaClass.simpleName)
        analytics.logError(error, CONTEXT_SAVE)
        return AppResult.Err(error)
    }

    override suspend fun load(uid: Uid): SessionLoad = try {
        files.locked<SessionLoad> {
            val map = files.readDocument(files.sessionDocument(uid)) ?: return@locked SessionLoad.None
            val document = EditDocumentCodec.decodeWork(map) ?: throw BrokenEditDocumentException()
            SessionLoad.Restored(document, workingPhotosOf(files, uid, document))
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        analytics.logError(AppError.Unknown(e.javaClass.simpleName), CONTEXT_LOAD)
        SessionLoad.Unreadable
    }

    override suspend fun clear(uid: Uid) {
        try {
            files.locked { files.deleteTree(files.sessionDir(uid)) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // 例外を投げない（契約）。残ったフォルダは、次に写真を選んだ時の写しが先に消す
        }
    }

    override suspend fun clearSession(uid: Uid, sessionId: String) {
        // 空の印では何も消さない（印の無い文書の "" と一致してしまうため：design.md:548）
        if (sessionId.isEmpty()) return
        try {
            files.locked {
                val map = files.readDocument(files.sessionDocument(uid)) ?: return@locked
                val document = EditDocumentCodec.decodeWork(map) ?: return@locked
                // 印が違えば、別の編集の途中（投稿の後に選び直した写真など）なので消さない（8.17・12.2）
                if (document.sessionId != sessionId) return@locked
                files.deleteTree(files.sessionDir(uid))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // 例外を投げない（契約）
        }
    }

    private companion object {
        const val CONTEXT_SAVE = "EditSessionStore.save"
        const val CONTEXT_LOAD = "EditSessionStore.load"
    }
}

/**
 * 文書を書く形にする。書いた後に読み戻せない文書（写真が 0 枚か 11 枚以上・写真の場所が相対でないなど）は書かずに
 * [BrokenEditDocumentException]（読めない途中や下書きを作らない）
 */
internal fun encodeReadableWork(document: EditWorkDocument): Map<String, String> {
    val encoded = EditDocumentCodec.encodeWork(document)
    if (EditDocumentCodec.decodeWork(encoded) == null) throw BrokenEditDocumentException()
    return encoded
}

/**
 * 文書の写真を、画面と画像の部品へ渡す形にする（途中を読む時と、下書きを開く時に使う）。
 * 指す写真が 1 枚でも無ければ [MissingEditPhotoException]、場所が安全でなければ [UnsafeEditPathException]。[EditFileStore.locked] の中で呼ぶ
 */
internal fun workingPhotosOf(files: EditFileStore, uid: Uid, document: EditWorkDocument): List<WorkingPhoto> =
    document.photos.map { photo ->
        WorkingPhoto(uri = files.fileUri(files.requirePhoto(uid, photo.file)), relativeFile = photo.file, capturedAt = photo.toCapturedAt())
    }

/**
 * 文書の撮影日時を [CapturedAt] に戻す。時刻があり、出所が `exif`・`asset` のときだけ。
 * 時刻が無い・出所が `none` か知らない値なら null（出所の分からない撮影日時を作らない）
 */
internal fun EditWorkPhoto.toCapturedAt(): CapturedAt? {
    val millis = capturedAtEpochMillis ?: return null
    val source = CapturedAtSource.entries.firstOrNull { it.raw == capturedAtSourceRaw } ?: return null
    if (source == CapturedAtSource.NONE) return null
    return CapturedAt(Instant.ofEpochMilli(millis), source)
}
