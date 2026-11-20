// ⭐️ 端末の下書きの保存・一覧・開く・削除（Kiro android-edit-tools タスク 14.4・A4・design.md:942-950, 653-669・要件 8.1・8.4〜8.8・8.11・8.16〜8.18）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.edit.EditDocumentCodec
import com.yoshidometoru.soramoyou.contract.edit.EditWorkDocument
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.UUID
import kotlin.coroutines.cancellation.CancellationException

/**
 * [LocalDraftRepository] の実装。下書きは `users/{uid}/drafts/{draftId}/`（draft.properties・photo-N・thumb.jpg）。
 * 端末の中だけで、サーバーの下書き（コレクションと保存先の `drafts/`）は読み書きしない（8.3）。
 *
 * - 新しい保存：件数が [LocalDraftRepository.MAX_DRAFTS] なら `LimitReached`（記録しない）。`{ID}.tmp/` に、文書が指す写真を**写し**（移さない）、
 *   文書と見本を書いてから、名前を `{ID}/` に変える。途中で失敗したら `.tmp` を消して `Failed`。`session/` には触れない（8.17）
 * - 上書き（文書に `draftId` がある）：件数に数えない。文書の写真が全部 `drafts/{ID}/` を指していれば（＝選び直していない）、文書と見本だけを
 *   書き換える。そうでなければ（選び直した）、`.tmp` に全部書いてから `{ID}`→`{ID}.old`、`.tmp`→`{ID}`、`.old` を消す、の順で入れ替える。
 *   `.tmp`→`{ID}` で失敗したら、`.old` を `{ID}` に戻し、`.tmp` を消す（古い下書きはそのまま開ける。古い写真と新しい写真が混ざらない）
 * - 一覧：保存した日時の新しい順。先に片付ける（`.tmp` は消す。`.old` は同じ ID のフォルダがあれば消し、無ければ名前を戻す）。
 *   読めないフォルダは `isBroken` の項目にする（削除だけできる：8.18）。件数の上限も、この一覧と同じ数え方（壊れたものも数える）
 * - 開く：文書を読み、前の `session/` を消してから、`session/work.properties` を「`draftId` つき・写真は下書きのフォルダを指す・印は空」の形で書く。
 *   下書きのフォルダは消さない。印を空にするのは、前の投稿の後始末（`clearSession`）が開いた途中を消さないため（ViewModel が新しい印を作る）
 * - 削除：フォルダごと消す（`.tmp`・`.old` も）。開いている下書き（`session/` の文書の `draftId` が同じ）なら `session/` も消す
 * - 失敗は `AppError.Unknown(例外のクラス名)` にして `LocalDraftRepository.save`・`.open`・`.list`・`.delete` で記録する（壊れた下書きを
 *   見つけたときを含む。場所・本文を入れない：14.5）
 * - 全ての操作は [EditFileStore.locked] の中で 1 本ずつ通す（一覧の片付けが、保存の途中の `.tmp` を消さないため）
 *
 * @param newId 新しい下書きの ID を作る（本番は大文字の UUID。テストは決まった値）
 */
class DefaultLocalDraftRepository internal constructor(
    private val files: EditFileStore,
    private val analytics: AnalyticsFacade,
    private val newId: () -> String,
) : LocalDraftRepository {

    constructor(files: EditFileStore, analytics: AnalyticsFacade) :
        this(files, analytics, { UUID.randomUUID().toString().uppercase(Locale.ROOT) })

    override suspend fun list(uid: Uid): List<LocalDraftSummary> {
        val problems = mutableListOf<Exception>()
        val summaries: List<LocalDraftSummary> = try {
            files.locked { summariesOf(uid, problems) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            problems += e
            emptyList()
        }
        problems.forEach { log(it, CONTEXT_LIST) }
        return summaries
    }

    override suspend fun save(uid: Uid, document: EditWorkDocument, thumbnailJpeg: ByteArray?): DraftSaveResult {
        val problems = mutableListOf<Exception>()
        val result: DraftSaveResult = try {
            files.locked {
                val draftId = document.draftId
                if (draftId == null) saveNew(uid, document, thumbnailJpeg, problems) else overwrite(uid, draftId, document, thumbnailJpeg, problems)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val error = AppError.Unknown(e.javaClass.simpleName)
            analytics.logError(error, CONTEXT_SAVE)
            DraftSaveResult.Failed(error)
        }
        // 片付けの失敗（保存そのものは済んだ・済まなかったに関わらず）
        problems.forEach { log(it, CONTEXT_SAVE) }
        return result
    }

    override suspend fun open(uid: Uid, id: DraftId): DraftOpenResult {
        val problems = mutableListOf<Exception>()
        val result: DraftOpenResult = try {
            files.locked { openDraft(uid, id.value, problems) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            problems += e
            DraftOpenResult.Broken
        }
        problems.forEach { log(it, CONTEXT_OPEN) }
        return result
    }

    override suspend fun delete(uid: Uid, id: DraftId): AppResult<Unit> {
        val failure: Exception? = try {
            files.locked { deleteDraft(uid, id.value) }
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            e
        }
        if (failure == null) return AppResult.Ok(Unit)
        val error = AppError.Unknown(failure.javaClass.simpleName)
        analytics.logError(error, CONTEXT_DELETE)
        return AppResult.Err(error)
    }

    // ── 中身（どれも EditFileStore.locked の中で呼ぶ） ──

    private fun summariesOf(uid: Uid, problems: MutableList<Exception>): List<LocalDraftSummary> {
        val drafts = files.draftsDir(uid)
        if (!drafts.isDirectory) return emptyList()
        tidy(drafts, problems)
        return draftFolders(drafts)
            .map { summaryOf(uid, it, problems) }
            .sortedWith(compareByDescending<LocalDraftSummary> { it.savedAtEpochMillis }.thenBy { it.id.value })
    }

    private fun summaryOf(uid: Uid, folder: File, problems: MutableList<Exception>): LocalDraftSummary {
        val id = DraftId(folder.name)
        return try {
            val document = readDraft(uid, folder)
            val thumbnail = File(folder, EditFileStore.THUMB_FILE)
            LocalDraftSummary(
                id = id,
                savedAtEpochMillis = document.savedAtEpochMillis,
                photoCount = document.photos.size,
                thumbnailUri = if (thumbnail.isFile) files.fileUri(thumbnail) else null,
                isBroken = false,
            )
        } catch (e: Exception) {
            problems += e
            // 読めない下書き：並びはフォルダの更新の日時で決める。見本と枚数は出さない（削除だけできる：8.18）
            LocalDraftSummary(id = id, savedAtEpochMillis = folder.lastModified(), photoCount = 0, thumbnailUri = null, isBroken = true)
        }
    }

    private fun saveNew(uid: Uid, document: EditWorkDocument, thumbnailJpeg: ByteArray?, problems: MutableList<Exception>): DraftSaveResult {
        val drafts = files.draftsDir(uid)
        val count = if (drafts.isDirectory) {
            tidy(drafts, problems)
            draftFolders(drafts).size
        } else {
            0
        }
        if (count >= LocalDraftRepository.MAX_DRAFTS) return DraftSaveResult.LimitReached
        val id = newId()
        if (!EditFileStore.isSafeDraftId(id)) throw UnsafeEditPathException()
        val folder = File(drafts, id)
        if (folder.exists()) throw IOException()
        val tmp = File(drafts, id + EditFileStore.TMP_SUFFIX)
        try {
            writeDraftFolder(uid, tmp, id, document, thumbnailJpeg)
            files.renameFile(tmp, folder)
        } catch (e: Exception) {
            deleteQuietly(tmp)
            throw e
        }
        return DraftSaveResult.Saved(DraftId(id))
    }

    private fun overwrite(
        uid: Uid,
        id: String,
        document: EditWorkDocument,
        thumbnailJpeg: ByteArray?,
        problems: MutableList<Exception>,
    ): DraftSaveResult {
        if (!EditFileStore.isSafeDraftId(id)) throw UnsafeEditPathException()
        val drafts = files.draftsDir(uid)
        recover(drafts, id)
        val folder = File(drafts, id)
        if (!folder.isDirectory) throw MissingEditDraftException()
        val prefix = "${EditFileStore.DRAFTS_DIR}/$id/"
        if (document.photos.all { it.file.startsWith(prefix) }) {
            // 選び直していない：写真には触れず、文書と見本だけを書き換える（どちらも一時のファイルに書いてから名前を変える）
            document.photos.forEach { files.requirePhoto(uid, it.file) }
            files.writeDocument(File(folder, EditFileStore.DRAFT_FILE), encodeReadableWork(document.copy(draftId = id)))
            val thumbnail = File(folder, EditFileStore.THUMB_FILE)
            // 見本を作れなかったときは、古い編集の見本を残さない
            if (thumbnailJpeg != null) files.writeBytes(thumbnail, thumbnailJpeg) else files.deleteTree(thumbnail)
            return DraftSaveResult.Saved(DraftId(id))
        }
        // 選び直した：新しいフォルダに全部書いてから、古いフォルダと入れ替える
        val tmp = File(drafts, id + EditFileStore.TMP_SUFFIX)
        val old = File(drafts, id + EditFileStore.OLD_SUFFIX)
        try {
            writeDraftFolder(uid, tmp, id, document, thumbnailJpeg)
            files.renameFile(folder, old)
        } catch (e: Exception) {
            deleteQuietly(tmp)
            throw e
        }
        try {
            files.renameFile(tmp, folder)
        } catch (e: Exception) {
            // 古いフォルダを元の名前に戻す。戻せなくても、一覧と開く時に .old から戻す（recover）
            try {
                files.renameFile(old, folder)
            } catch (restore: Exception) {
                problems += restore
            }
            deleteQuietly(tmp)
            throw e
        }
        try {
            files.deleteTree(old)
        } catch (e: Exception) {
            // 新しい下書きは置けた。残った .old は次の一覧で消す
            problems += e
        }
        return DraftSaveResult.Saved(DraftId(id))
    }

    /** [folder] を作り直し、文書が指す写真を写して（移さない）、写真の場所を下書きのフォルダに直した文書と見本を書く */
    private fun writeDraftFolder(uid: Uid, folder: File, id: String, document: EditWorkDocument, thumbnailJpeg: ByteArray?) {
        files.deleteTree(folder)
        files.ensureDir(folder)
        val photos = document.photos.mapIndexed { index, photo ->
            val source = files.requirePhoto(uid, photo.file)
            files.copyFile(source, File(folder, EditFileStore.PHOTO_PREFIX + index))
            photo.copy(file = EditFileStore.draftPhotoPath(id, index))
        }
        val saved = document.copy(draftId = id, photos = photos)
        files.writeDocument(File(folder, EditFileStore.DRAFT_FILE), encodeReadableWork(saved))
        if (thumbnailJpeg != null) files.writeBytes(File(folder, EditFileStore.THUMB_FILE), thumbnailJpeg)
    }

    private fun openDraft(uid: Uid, id: String, problems: MutableList<Exception>): DraftOpenResult {
        if (!EditFileStore.isSafeDraftId(id)) throw UnsafeEditPathException()
        val drafts = files.draftsDir(uid)
        recover(drafts, id)
        val draft = readDraft(uid, File(drafts, id))
        val session = draft.copy(sessionId = "", draftId = id)
        val photos = workingPhotosOf(files, uid, session)
        try {
            files.deleteTree(files.sessionDir(uid))
            files.writeDocument(files.sessionDocument(uid), encodeReadableWork(session))
        } catch (e: Exception) {
            // 編集の途中を書けなくても、下書きは開ける（途中は ViewModel の次の保存で書き直す）
            problems += e
        }
        return DraftOpenResult.Opened(session, photos)
    }

    private fun deleteDraft(uid: Uid, id: String) {
        if (!EditFileStore.isSafeDraftId(id)) throw UnsafeEditPathException()
        val drafts = files.draftsDir(uid)
        files.deleteTree(File(drafts, id))
        files.deleteTree(File(drafts, id + EditFileStore.TMP_SUFFIX))
        files.deleteTree(File(drafts, id + EditFileStore.OLD_SUFFIX))
        // 開いている下書きなら、その編集の途中も消す（読めない途中は、どの下書きのものか分からないので残す）
        val session = try {
            files.readDocument(files.sessionDocument(uid))?.let { EditDocumentCodec.decodeWork(it) }
        } catch (e: Exception) {
            null
        }
        if (session?.draftId == id) files.deleteTree(files.sessionDir(uid))
    }

    /**
     * 下書きのフォルダの文書を読む。文書が無い・読めない・写真が下書きのフォルダの外を指す・写真が無いときは例外
     * （[BrokenEditDocumentException]・[UnsafeEditPathException]・[MissingEditPhotoException] など）
     */
    private fun readDraft(uid: Uid, folder: File): EditWorkDocument {
        val map = files.readDocument(File(folder, EditFileStore.DRAFT_FILE)) ?: throw BrokenEditDocumentException()
        val document = EditDocumentCodec.decodeWork(map) ?: throw BrokenEditDocumentException()
        val prefix = "${EditFileStore.DRAFTS_DIR}/${folder.name}/"
        document.photos.forEach { photo ->
            if (!photo.file.startsWith(prefix)) throw UnsafeEditPathException()
            files.requirePhoto(uid, photo.file)
        }
        return document
    }

    /** 下書きのフォルダ（名前が下書きの ID の形のもの。`.tmp`・`.old` は含まない） */
    private fun draftFolders(drafts: File): List<File> {
        val entries = drafts.listFiles() ?: throw IOException()
        return entries.filter { it.isDirectory && EditFileStore.isSafeDraftId(it.name) }
    }

    /** 残った一時のフォルダを片付ける。`.tmp` は消し、`.old` は同じ ID のフォルダがあれば消し、無ければ名前を戻す。失敗は [problems] に足して続ける */
    private fun tidy(drafts: File, problems: MutableList<Exception>) {
        val entries = drafts.listFiles() ?: throw IOException()
        for (entry in entries) {
            try {
                val name = entry.name
                when {
                    name.endsWith(EditFileStore.TMP_SUFFIX) && EditFileStore.isSafeDraftId(name.removeSuffix(EditFileStore.TMP_SUFFIX)) ->
                        files.deleteTree(entry)
                    name.endsWith(EditFileStore.OLD_SUFFIX) && EditFileStore.isSafeDraftId(name.removeSuffix(EditFileStore.OLD_SUFFIX)) ->
                        recover(drafts, name.removeSuffix(EditFileStore.OLD_SUFFIX))
                }
            } catch (e: Exception) {
                problems += e
            }
        }
    }

    /** 1 つの ID の入れ替えの途中を片付ける：`{id}.old` があれば、`{id}` があれば `.old` を消し、無ければ `.old` を `{id}` に戻す */
    private fun recover(drafts: File, id: String) {
        val old = File(drafts, id + EditFileStore.OLD_SUFFIX)
        if (!old.exists()) return
        val folder = File(drafts, id)
        if (folder.exists()) files.deleteTree(old) else files.renameFile(old, folder)
    }

    /** 一時のフォルダを消す。消せなくても、次の一覧の片付けで消すので続ける */
    private fun deleteQuietly(target: File) {
        try {
            files.deleteTree(target)
        } catch (e: Exception) {
            // 次の一覧で片付ける
        }
    }

    private fun log(e: Exception, context: String) = analytics.logError(AppError.Unknown(e.javaClass.simpleName), context)

    private companion object {
        const val CONTEXT_SAVE = "LocalDraftRepository.save"
        const val CONTEXT_OPEN = "LocalDraftRepository.open"
        const val CONTEXT_LIST = "LocalDraftRepository.list"
        const val CONTEXT_DELETE = "LocalDraftRepository.delete"
    }
}
