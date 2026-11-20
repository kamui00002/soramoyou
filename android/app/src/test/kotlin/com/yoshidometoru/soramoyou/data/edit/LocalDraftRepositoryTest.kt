// ⭐️ 端末の下書き（DefaultLocalDraftRepository）の単体テスト。JVM の一時のフォルダで確かめる（Kiro android-edit-tools タスク 14.4・A4・design.md:942-950, 1137・要件 8.1・8.4〜8.8・8.11・8.16〜8.18）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.EditWorkDocument
import com.yoshidometoru.soramoyou.contract.edit.EditWorkPhoto
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.edit.ToolValues
import com.yoshidometoru.soramoyou.contract.model.FilterId
import java.io.File
import java.net.URI
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * 10 件で LimitReached・上書きは数えない・開いても残る・削除で写真も消える・壊れた文書は isBroken・新しい保存で文書と見本の書き込みが失敗しても
 * `session/` の写真が残り `.tmp` が残らない・上書きで写真を入れ替える途中に失敗しても古い下書きが元のまま開ける・別の uid から見えない、を確かめる。
 * 陽性対照は「件数の検査を外す」と「写真を写さずに移す」（`writeDraftFolder` の copyFile を renameFile にする）。
 */
class LocalDraftRepositoryTest {

    private val base: File = createTempDirectory("local-drafts").toFile()
    private val ops = FaultyFileOps()
    private val files = EditFileStore(base, ops = ops)
    private val errors = RecordingEditErrors()

    /** 新しい下書きの ID は DRAFT-01, DRAFT-02, … の順 */
    private var issued = 0
    private val repository = DefaultLocalDraftRepository(files, errors) { "DRAFT-" + (++issued).toString().padStart(2, '0') }
    private val sessions = DefaultEditSessionStore(files, errors)

    private val alice = Uid("aliceUid0001")
    private val bob = Uid("bobUid0002")

    private val warmEdit = PhotoEdit(filter = FilterId.WARM, tools = ToolValues.NONE.with(EditTool.EXPOSURE, 25))

    @AfterTest
    fun deleteBase() {
        base.deleteRecursively()
    }

    /** `session/` に写真を置き（本体を通さない）、その写真を指す文書を返す */
    private fun sessionWork(
        uid: Uid = alice,
        photoBytes: List<ByteArray> = listOf(byteArrayOf(1, 1, 1), byteArrayOf(2, 2)),
        caption: String = "夕焼け",
        savedAt: Long = 1_794_400_000_000L,
        draftId: String? = null,
    ): EditWorkDocument {
        val photos = photoBytes.mapIndexed { index, bytes ->
            val relative = "session/photo-$index"
            files.resolve(uid, relative).apply { parentFile!!.mkdirs() }.writeBytes(bytes)
            EditWorkPhoto(relative, capturedAtEpochMillis = null, capturedAtSourceRaw = "none", edit = if (index == 0) warmEdit else PhotoEdit.NONE)
        }
        return EditWorkDocument("SESSION-1", draftId, savedAt, caption, "public", enteredInfo = false, photos = photos)
    }

    private fun draftFolder(uid: Uid, id: String) = File(files.draftsDir(uid), id)

    private fun draftsEntries(uid: Uid = alice): List<String> = files.draftsDir(uid).list()?.sorted() ?: emptyList()

    private fun saved(result: DraftSaveResult): DraftId = assertIs<DraftSaveResult.Saved>(result).id

    private fun opened(result: DraftOpenResult): DraftOpenResult.Opened = assertIs<DraftOpenResult.Opened>(result)

    // ── 新しい保存 ──

    @Test
    fun `新しい保存は写真を写して文書と見本を drafts の ID のフォルダに置き、session の写真は元のまま残る`() = runBlocking {
        val work = sessionWork()

        val id = saved(repository.save(alice, work, byteArrayOf(9, 9)))

        assertEquals(DraftId("DRAFT-01"), id)
        assertEquals(listOf("DRAFT-01"), draftsEntries())
        assertEquals(listOf("draft.properties", "photo-0", "photo-1", "thumb.jpg"), draftFolder(alice, "DRAFT-01").list()!!.sorted())
        assertContentEquals(byteArrayOf(1, 1, 1), File(draftFolder(alice, "DRAFT-01"), "photo-0").readBytes())
        assertContentEquals(byteArrayOf(2, 2), File(draftFolder(alice, "DRAFT-01"), "photo-1").readBytes())
        // 写した（移していない）ので、編集中の写真はそのまま残る（8.17）
        assertContentEquals(byteArrayOf(1, 1, 1), files.resolve(alice, "session/photo-0").readBytes())
        assertContentEquals(byteArrayOf(2, 2), files.resolve(alice, "session/photo-1").readBytes())
        assertEquals(emptyList(), errors.errors)
    }

    @Test
    fun `一覧は見本を file の URI で返し、見本なしで保存した下書きは null`() = runBlocking {
        saved(repository.save(alice, sessionWork(savedAt = 200), byteArrayOf(9, 8, 7)))
        saved(repository.save(alice, sessionWork(savedAt = 100), null))

        val summaries = repository.list(alice)

        assertEquals(
            listOf(
                LocalDraftSummary(DraftId("DRAFT-01"), 200, 2, files.fileUri(File(draftFolder(alice, "DRAFT-01"), "thumb.jpg")), isBroken = false),
                LocalDraftSummary(DraftId("DRAFT-02"), 100, 2, null, isBroken = false),
            ),
            summaries,
        )
        assertTrue(summaries[0].thumbnailUri!!.startsWith("file:///"))
        assertContentEquals(byteArrayOf(9, 8, 7), File(URI(summaries[0].thumbnailUri!!)).readBytes())
    }

    @Test
    fun `一覧は保存した日時の新しい順`() = runBlocking {
        saved(repository.save(alice, sessionWork(savedAt = 100), null))
        saved(repository.save(alice, sessionWork(savedAt = 300), null))
        saved(repository.save(alice, sessionWork(savedAt = 200), null))

        assertEquals(listOf("DRAFT-02", "DRAFT-03", "DRAFT-01"), repository.list(alice).map { it.id.value })
    }

    // ── 件数の上限 ──

    @Test
    fun `10 件あると新しい保存は LimitReached で、増えず、記録しない`() = runBlocking {
        repeat(LocalDraftRepository.MAX_DRAFTS) { saved(repository.save(alice, sessionWork(savedAt = it.toLong()), null)) }

        assertEquals(DraftSaveResult.LimitReached, repository.save(alice, sessionWork(), null))

        assertEquals(10, repository.list(alice).size)
        assertEquals(10, draftsEntries().size)
        assertEquals(emptyList(), errors.errors)
    }

    @Test
    fun `10 件あっても、開いた下書きの上書きは件数に数えない`() = runBlocking {
        repeat(LocalDraftRepository.MAX_DRAFTS) { saved(repository.save(alice, sessionWork(savedAt = it.toLong()), null)) }
        val open = opened(repository.open(alice, DraftId("DRAFT-03")))

        val result = repository.save(alice, open.document.copy(caption = "書き直した", savedAtEpochMillis = 999), byteArrayOf(5))

        assertEquals(DraftId("DRAFT-03"), saved(result))
        assertEquals(10, repository.list(alice).size)
        assertEquals("書き直した", opened(repository.open(alice, DraftId("DRAFT-03"))).document.caption)
    }

    @Test
    fun `壊れた下書きも件数に数える`() = runBlocking {
        repeat(LocalDraftRepository.MAX_DRAFTS - 1) { saved(repository.save(alice, sessionWork(savedAt = it.toLong()), null)) }
        draftFolder(alice, "BROKEN-1").apply { mkdirs() }.resolve("draft.properties").writeText("version=1\n")

        assertEquals(DraftSaveResult.LimitReached, repository.save(alice, sessionWork(), null))
    }

    // ── 上書き ──

    @Test
    fun `写真を選び直さずに上書きすると、文書と見本だけを書き換え、写真には触れない`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(caption = "前"), byteArrayOf(1)))
        val open = opened(repository.open(alice, id))
        val photoBefore = File(draftFolder(alice, id.value), "photo-0")
        val modifiedBefore = photoBefore.lastModified()

        val result = repository.save(alice, open.document.copy(caption = "後", savedAtEpochMillis = 2), byteArrayOf(2))

        assertEquals(id, saved(result))
        assertEquals("後", opened(repository.open(alice, id)).document.caption)
        assertContentEquals(byteArrayOf(2), File(draftFolder(alice, id.value), "thumb.jpg").readBytes())
        assertContentEquals(byteArrayOf(1, 1, 1), photoBefore.readBytes())
        assertEquals(modifiedBefore, photoBefore.lastModified())
        // 写真は写し直していない（写しの書き込みは最初の保存の 2 枚だけ）
        assertEquals(2, ops.calls.count { it.first == FaultyFileOps.Kind.WRITE && it.second.name.startsWith("photo-") })
        assertEquals(listOf(id.value), draftsEntries())
    }

    @Test
    fun `見本なしで上書きすると、古い見本を残さない`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(), byteArrayOf(1)))
        val open = opened(repository.open(alice, id))

        saved(repository.save(alice, open.document, null))

        assertFalse(File(draftFolder(alice, id.value), "thumb.jpg").exists())
        assertNull(repository.list(alice).single().thumbnailUri)
    }

    @Test
    fun `写真を選び直して上書きすると写真ごと入れ替え、tmp と old を残さない`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(caption = "前"), null))
        // 開いた後に選び直した：写真は session の新しい写し（1 枚だけ）を指す
        val repicked = sessionWork(photoBytes = listOf(byteArrayOf(7, 7, 7, 7)), caption = "選び直した", draftId = id.value)

        assertEquals(id, saved(repository.save(alice, repicked, byteArrayOf(3))))

        assertEquals(listOf(id.value), draftsEntries())
        assertEquals(listOf("draft.properties", "photo-0", "thumb.jpg"), draftFolder(alice, id.value).list()!!.sorted())
        val reopened = opened(repository.open(alice, id))
        assertEquals("選び直した", reopened.document.caption)
        assertEquals(listOf("drafts/${id.value}/photo-0"), reopened.document.photos.map { it.file })
        assertContentEquals(byteArrayOf(7, 7, 7, 7), File(URI(reopened.photos.single().uri)).readBytes())
    }

    @Test
    fun `上書きで入れ替える途中（old にした後・tmp を ID にする前）に失敗しても、古い下書きが元のまま開ける`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(caption = "前"), byteArrayOf(1)))
        val repicked = sessionWork(photoBytes = listOf(byteArrayOf(7, 7, 7, 7)), caption = "選び直した", draftId = id.value)
        // `.tmp` → `{ID}` の名前の変更だけを 1 回失敗させる（`{ID}` → `.old` の後。戻しの `.old` → `{ID}` は通る）
        ops.failWhen = FaultyFileOps.once(FaultyFileOps.Kind.RENAME) { it.name == id.value }

        val result = repository.save(alice, repicked, byteArrayOf(3))

        assertEquals(DraftSaveResult.Failed(AppError.Unknown("IOException")), result)
        assertTrue(ops.calls.any { it.first == FaultyFileOps.Kind.RENAME && it.second.name == id.value + ".old" })
        assertEquals(listOf(id.value), draftsEntries())
        val reopened = opened(repository.open(alice, id))
        assertEquals("前", reopened.document.caption)
        assertEquals(2, reopened.photos.size)
        assertContentEquals(byteArrayOf(1, 1, 1), File(URI(reopened.photos[0].uri)).readBytes())
        assertContentEquals(byteArrayOf(1), File(draftFolder(alice, id.value), "thumb.jpg").readBytes())
        assertTrue(errors.errors.contains(AppError.Unknown("IOException") to "LocalDraftRepository.save"))
    }

    @Test
    fun `入れ替えの戻しにも失敗して old だけが残っても、次に開くと古い下書きに戻る`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(caption = "前"), null))
        val repicked = sessionWork(photoBytes = listOf(byteArrayOf(7)), caption = "選び直した", draftId = id.value)
        ops.failWhen = { kind, target -> kind == FaultyFileOps.Kind.RENAME && target.name == id.value }

        assertIs<DraftSaveResult.Failed>(repository.save(alice, repicked, null))
        assertEquals(listOf(id.value + ".old"), draftsEntries())

        ops.failWhen = { _, _ -> false }
        val reopened = opened(repository.open(alice, id))
        assertEquals("前", reopened.document.caption)
        assertEquals(listOf(id.value), draftsEntries())
    }

    @Test
    fun `上書きの写しの途中で失敗しても、古い下書きが元のまま開け、tmp を残さない`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(caption = "前"), null))
        val repicked = sessionWork(photoBytes = listOf(byteArrayOf(7), byteArrayOf(8)), caption = "選び直した", draftId = id.value)
        ops.failWhen = { kind, target -> kind == FaultyFileOps.Kind.WRITE && target.name == "photo-1" }

        assertIs<DraftSaveResult.Failed>(repository.save(alice, repicked, null))

        assertEquals(listOf(id.value), draftsEntries())
        assertEquals("前", opened(repository.open(alice, id)).document.caption)
    }

    @Test
    fun `上書きする下書きのフォルダが無ければ Failed で、新しく作らない`() = runBlocking {
        val work = sessionWork(draftId = "DRAFT-77")

        assertEquals(DraftSaveResult.Failed(AppError.Unknown("MissingEditDraftException")), repository.save(alice, work, null))
        assertEquals(emptyList(), draftsEntries())
    }

    // ── 新しい保存の失敗 ──

    @Test
    fun `新しい保存で文書の書き込みが失敗しても、session の写真が残り、tmp が残らない`() = runBlocking {
        val work = sessionWork()
        ops.failWhen = { kind, target -> kind == FaultyFileOps.Kind.WRITE && target.name.startsWith("draft.properties") }

        val result = repository.save(alice, work, byteArrayOf(9))

        assertEquals(DraftSaveResult.Failed(AppError.Unknown("IOException")), result)
        assertEquals(emptyList(), draftsEntries())
        assertContentEquals(byteArrayOf(1, 1, 1), files.resolve(alice, "session/photo-0").readBytes())
        assertContentEquals(byteArrayOf(2, 2), files.resolve(alice, "session/photo-1").readBytes())
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("IOException") to "LocalDraftRepository.save"), errors.errors)
    }

    @Test
    fun `新しい保存で見本の書き込みが失敗しても、session の写真が残り、tmp が残らない`() = runBlocking {
        val work = sessionWork()
        ops.failWhen = { kind, target -> kind == FaultyFileOps.Kind.WRITE && target.name.startsWith("thumb.jpg") }

        assertIs<DraftSaveResult.Failed>(repository.save(alice, work, byteArrayOf(9)))

        assertEquals(emptyList(), draftsEntries())
        assertContentEquals(byteArrayOf(1, 1, 1), files.resolve(alice, "session/photo-0").readBytes())
        assertContentEquals(byteArrayOf(2, 2), files.resolve(alice, "session/photo-1").readBytes())
    }

    @Test
    fun `新しい保存で最後の名前の変更が失敗しても、tmp が残らない`() = runBlocking {
        ops.failWhen = { kind, target -> kind == FaultyFileOps.Kind.RENAME && target.name == "DRAFT-01" }

        assertIs<DraftSaveResult.Failed>(repository.save(alice, sessionWork(), null))

        assertEquals(emptyList(), draftsEntries())
        assertTrue(files.resolve(alice, "session/photo-0").isFile)
    }

    @Test
    fun `写真を写せない（無い写真を指す）新しい保存は Failed`() = runBlocking {
        val work = sessionWork()
        files.resolve(alice, "session/photo-1").delete()

        assertEquals(DraftSaveResult.Failed(AppError.Unknown("MissingEditPhotoException")), repository.save(alice, work, null))
        assertEquals(emptyList(), draftsEntries())
    }

    // ── 開く ──

    @Test
    fun `開くと session に draftId つき・写真は下書きのフォルダを指す文書を書き、下書きは残る`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(caption = "開く前"), null))

        val open = opened(repository.open(alice, id))

        assertEquals(id.value, open.document.draftId)
        assertEquals("開く前", open.document.caption)
        assertEquals(listOf("drafts/${id.value}/photo-0", "drafts/${id.value}/photo-1"), open.document.photos.map { it.file })
        assertEquals(warmEdit, open.document.photos[0].edit)
        assertEquals(listOf("drafts/${id.value}/photo-0", "drafts/${id.value}/photo-1"), open.photos.map { it.relativeFile })
        assertContentEquals(byteArrayOf(2, 2), File(URI(open.photos[1].uri)).readBytes())
        // 編集の途中として読み戻すと、同じ文書（前の session の写しは消えている）
        val session = assertIs<SessionLoad.Restored>(sessions.load(alice))
        assertEquals(open.document, session.document)
        assertEquals(listOf("work.properties"), files.sessionDir(alice).list()!!.sorted())
        // 下書きは消さない
        assertTrue(draftFolder(alice, id.value).isDirectory)
        assertEquals(listOf(id), repository.list(alice).map { it.id })
    }

    @Test
    fun `開いた途中の印は空で、前の投稿の後始末の clearSession では消えない`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(), null))

        val open = opened(repository.open(alice, id))
        sessions.clearSession(alice, "SESSION-1")

        assertEquals("", open.document.sessionId)
        assertTrue(files.sessionDocument(alice).isFile)
    }

    @Test
    fun `無い下書きを開くと Broken`() = runBlocking {
        assertEquals(DraftOpenResult.Broken, repository.open(alice, DraftId("DRAFT-99")))
        assertEquals(DraftOpenResult.Broken, repository.open(alice, DraftId("../x")))
        Unit
    }

    // ── 壊れた下書き ──

    @Test
    fun `壊れた文書の下書きは一覧で isBroken になり、開くと Broken、削除はできる`() = runBlocking {
        saved(repository.save(alice, sessionWork(savedAt = 5), null))
        draftFolder(alice, "BROKEN-1").apply { mkdirs() }.resolve("draft.properties").writeText("version=1\ncaption=鍵が足りない\n")

        val summaries = repository.list(alice)

        val broken = summaries.single { it.id == DraftId("BROKEN-1") }
        assertTrue(broken.isBroken)
        assertNull(broken.thumbnailUri)
        assertFalse(summaries.single { it.id == DraftId("DRAFT-01") }.isBroken)
        assertTrue(errors.errors.contains(AppError.Unknown("BrokenEditDocumentException") to "LocalDraftRepository.list"))

        assertEquals(DraftOpenResult.Broken, repository.open(alice, DraftId("BROKEN-1")))
        assertTrue(errors.errors.contains(AppError.Unknown("BrokenEditDocumentException") to "LocalDraftRepository.open"))

        assertEquals(AppResult.Ok(Unit), repository.delete(alice, DraftId("BROKEN-1")))
        assertEquals(listOf(DraftId("DRAFT-01")), repository.list(alice).map { it.id })
    }

    @Test
    fun `写真が欠けた下書きも isBroken`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(), null))
        File(draftFolder(alice, id.value), "photo-1").delete()

        assertTrue(repository.list(alice).single().isBroken)
        assertEquals(DraftOpenResult.Broken, repository.open(alice, id))
    }

    @Test
    fun `下書きのフォルダの外の写真を指す文書の下書きは isBroken`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(), null))
        val doc = File(draftFolder(alice, id.value), "draft.properties")
        doc.writeText(doc.readText().replace("drafts/${id.value}/photo-0", "session/photo-0"))

        assertTrue(repository.list(alice).single().isBroken)
    }

    // ── 片付け ──

    @Test
    fun `一覧は残った tmp を消し、old は同じ ID があれば消し、無ければ名前を戻す`() = runBlocking {
        saved(repository.save(alice, sessionWork(caption = "残る"), null))
        saved(repository.save(alice, sessionWork(caption = "入れ替えの途中で落ちた"), null))
        // DRAFT-01 は入れ替え済みで古いフォルダだけが残った形、DRAFT-02 は .old にした直後に落ちた形、もう 1 つは保存の途中で落ちた形
        draftFolder(alice, "DRAFT-01.old").apply { mkdirs() }.resolve("draft.properties").writeText("version=1\n")
        draftFolder(alice, "DRAFT-02").renameTo(draftFolder(alice, "DRAFT-02.old"))
        draftFolder(alice, "DRAFT-09.tmp").apply { mkdirs() }.resolve("photo-0").writeBytes(byteArrayOf(1))

        val ids = repository.list(alice).map { it.id.value }.sorted()

        assertEquals(listOf("DRAFT-01", "DRAFT-02"), ids)
        assertEquals(listOf("DRAFT-01", "DRAFT-02"), draftsEntries())
        assertEquals("入れ替えの途中で落ちた", opened(repository.open(alice, DraftId("DRAFT-02"))).document.caption)
    }

    // ── 削除 ──

    @Test
    fun `削除すると写真ごと消え、開いている下書きなら session も消す`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(), null))
        opened(repository.open(alice, id))

        assertEquals(AppResult.Ok(Unit), repository.delete(alice, id))

        assertFalse(draftFolder(alice, id.value).exists())
        assertFalse(files.sessionDir(alice).exists())
        assertEquals(emptyList(), repository.list(alice))
    }

    @Test
    fun `開いていない下書きを削除しても、編集の途中は残す`() = runBlocking {
        val first = saved(repository.save(alice, sessionWork(), null))
        val second = saved(repository.save(alice, sessionWork(), null))
        opened(repository.open(alice, second))

        repository.delete(alice, first)

        assertFalse(draftFolder(alice, first.value).exists())
        assertEquals(second.value, assertIs<SessionLoad.Restored>(sessions.load(alice)).document.draftId)
    }

    @Test
    fun `削除に失敗したら Err を返して LocalDraftRepository delete で記録する`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(), null))
        ops.failWhen = { kind, target -> kind == FaultyFileOps.Kind.DELETE && target.name == id.value }

        assertEquals(AppResult.Err(AppError.Unknown("IOException")), repository.delete(alice, id))
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("IOException") to "LocalDraftRepository.delete"), errors.errors)
    }

    // ── 利用者ごとに分かれる ──

    @Test
    fun `別の uid からは、下書きが一覧にも開くにも見えず、消せもしない`() = runBlocking {
        val id = saved(repository.save(alice, sessionWork(), null))

        assertEquals(emptyList(), repository.list(bob))
        assertEquals(DraftOpenResult.Broken, repository.open(bob, id))
        assertEquals(AppResult.Ok(Unit), repository.delete(bob, id))

        assertTrue(draftFolder(alice, id.value).isDirectory)
        assertEquals(listOf(id), repository.list(alice).map { it.id })
    }
}
