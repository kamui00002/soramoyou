// ⭐️ 編集の途中の保存（DefaultEditSessionStore）と写真の写し（DefaultWorkingPhotoImporter）の単体テスト（Kiro android-edit-tools タスク 14.3・A4・design.md:930-941, 1137・要件 12.2〜12.5）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.edit.EditGeometry
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.EditWorkDocument
import com.yoshidometoru.soramoyou.contract.edit.EditWorkPhoto
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.edit.ToolValues
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.data.image.CapturedAt
import com.yoshidometoru.soramoyou.data.image.CapturedAtSource
import com.yoshidometoru.soramoyou.data.image.PhotoMetadataReader
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileNotFoundException
import java.net.URI
import java.time.Instant
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
 * 往復・写真が欠けたら Unreadable・文書が無ければ None・別の uid から読めない・`clearSession` は印が同じときだけ消し、印が違う・文書が無いときは
 * 何も消さない、を確かめる。陽性対照は「`clearSession` で印を見ない」（印を比べる行を消す）。
 * 写しの部品は、元の写真を開く口を手元のバイト列に差し替えて確かめる（本物の URI からの写しと向き・画素は端末の EditFilesDeviceTest）。
 */
class EditSessionStoreTest {

    private val base: File = createTempDirectory("edit-session-store").toFile()
    private val ops = FaultyFileOps()
    private val files = EditFileStore(base, ops = ops)
    private val errors = RecordingEditErrors()
    private val store = DefaultEditSessionStore(files, errors)

    private val alice = Uid("aliceUid0001")
    private val bob = Uid("bobUid0002")

    private val takenAt = 1_794_400_000_000L

    @AfterTest
    fun deleteBase() {
        base.deleteRecursively()
    }

    /** 写しの写真を、本体を通さずに置く */
    private fun putPhoto(uid: Uid, relative: String, bytes: ByteArray): File =
        files.resolve(uid, relative).also {
            it.parentFile!!.mkdirs()
            it.writeBytes(bytes)
        }

    private fun document(sessionId: String = "SESSION-1", photos: List<EditWorkPhoto> = twoPhotos()) = EditWorkDocument(
        sessionId = sessionId,
        draftId = null,
        savedAtEpochMillis = 1_794_500_000_000L,
        caption = "朝焼け #空",
        visibilityRaw = "followers",
        enteredInfo = true,
        photos = photos,
    )

    private fun twoPhotos() = listOf(
        EditWorkPhoto(
            file = "session/photo-0",
            capturedAtEpochMillis = takenAt,
            capturedAtSourceRaw = "exif",
            edit = PhotoEdit(
                filter = FilterId.WARM,
                tools = ToolValues.NONE.with(EditTool.EXPOSURE, 25).with(EditTool.FADE, -10),
                geometry = EditGeometry(quarterTurns = 1, crop = NormalizedRect(0.1, 0.2, 0.9, 0.8)),
            ),
        ),
        EditWorkPhoto(file = "session/photo-1", capturedAtEpochMillis = null, capturedAtSourceRaw = "none", edit = PhotoEdit.NONE),
    )

    private fun putTwoPhotos(uid: Uid) {
        putPhoto(uid, "session/photo-0", byteArrayOf(1, 2, 3))
        putPhoto(uid, "session/photo-1", byteArrayOf(4, 5, 6))
    }

    // ── 往復 ──

    @Test
    fun `保存した途中を読むと、同じ文書と、写しを指す写真が戻る`() = runBlocking {
        putTwoPhotos(alice)
        val saved = document()

        assertEquals(AppResult.Ok(Unit), store.save(alice, saved))
        val loaded = assertIs<SessionLoad.Restored>(store.load(alice))

        assertEquals(saved, loaded.document)
        assertEquals(
            listOf(
                WorkingPhoto(
                    uri = files.fileUri(files.resolve(alice, "session/photo-0")),
                    relativeFile = "session/photo-0",
                    capturedAt = CapturedAt(Instant.ofEpochMilli(takenAt), CapturedAtSource.EXIF),
                ),
                WorkingPhoto(uri = files.fileUri(files.resolve(alice, "session/photo-1")), relativeFile = "session/photo-1", capturedAt = null),
            ),
            loaded.photos,
        )
        assertContentEquals(byteArrayOf(1, 2, 3), File(URI(loaded.photos[0].uri)).readBytes())
        assertEquals(emptyList(), errors.errors)
    }

    @Test
    fun `開いた下書きの写真を指す途中も保存して読み戻せる`() = runBlocking {
        putPhoto(alice, "drafts/DRAFT-1/photo-0", byteArrayOf(7))
        val saved = document(photos = listOf(twoPhotos()[0].copy(file = "drafts/DRAFT-1/photo-0"))).copy(draftId = "DRAFT-1")

        assertEquals(AppResult.Ok(Unit), store.save(alice, saved))
        val loaded = assertIs<SessionLoad.Restored>(store.load(alice))

        assertEquals(saved, loaded.document)
        assertEquals("drafts/DRAFT-1/photo-0", loaded.photos.single().relativeFile)
    }

    // ── 読めない・無い ──

    @Test
    fun `文書が無ければ None で、記録しない`() = runBlocking {
        assertEquals(SessionLoad.None, store.load(alice))
        assertEquals(emptyList(), errors.errors)
    }

    @Test
    fun `指す写真が 1 枚でも欠けたら Unreadable で、EditSessionStore load で記録する`() = runBlocking {
        putTwoPhotos(alice)
        store.save(alice, document())
        files.resolve(alice, "session/photo-1").delete()

        assertEquals(SessionLoad.Unreadable, store.load(alice))
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("MissingEditPhotoException") to "EditSessionStore.load"), errors.errors)
    }

    @Test
    fun `文書を読めなければ Unreadable で、記録する`() = runBlocking {
        files.sessionDocument(alice).apply { parentFile!!.mkdirs() }.writeText("version=1\ncaption=必須の鍵が足りない\n")

        assertEquals(SessionLoad.Unreadable, store.load(alice))
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("BrokenEditDocumentException") to "EditSessionStore.load"), errors.errors)
    }

    @Test
    fun `別の uid からは、保存した途中を読めない`() = runBlocking {
        putTwoPhotos(alice)
        store.save(alice, document())

        assertEquals(SessionLoad.None, store.load(bob))
        assertIs<SessionLoad.Restored>(store.load(alice))
        Unit
    }

    // ── 保存の失敗 ──

    @Test
    fun `書き込みに失敗したら Err を返して EditSessionStore save で記録し、前の途中は残る`() = runBlocking {
        putTwoPhotos(alice)
        store.save(alice, document(sessionId = "OLD"))
        ops.failWhen = { kind, file -> kind == FaultyFileOps.Kind.WRITE && file.name.startsWith("work.properties") }

        val result = store.save(alice, document(sessionId = "NEW"))

        assertEquals(AppResult.Err(AppError.Unknown("IOException")), result)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("IOException") to "EditSessionStore.save"), errors.errors)
        ops.failWhen = { _, _ -> false }
        assertEquals("OLD", assertIs<SessionLoad.Restored>(store.load(alice)).document.sessionId)
    }

    @Test
    fun `無い写真を指す途中は書かず、Err を返して記録する`() = runBlocking {
        putPhoto(alice, "session/photo-0", byteArrayOf(1))

        val result = store.save(alice, document())

        assertEquals(AppResult.Err(AppError.Unknown("MissingEditPhotoException")), result)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("MissingEditPhotoException") to "EditSessionStore.save"), errors.errors)
        assertFalse(files.sessionDocument(alice).exists())
    }

    @Test
    fun `利用者のフォルダの外を指す途中は書かず、Err を返す`() = runBlocking {
        putTwoPhotos(bob)
        val outside = document(photos = listOf(twoPhotos()[0].copy(file = "../bobUid0002/session/photo-0")))

        assertEquals(AppResult.Err(AppError.Unknown("UnsafeEditPathException")), store.save(alice, outside))
        assertFalse(files.sessionDocument(alice).exists())
    }

    // ── 消す ──

    @Test
    fun `clear は session を丸ごと消し、無くても例外を投げない`() = runBlocking {
        putTwoPhotos(alice)
        store.save(alice, document())

        store.clear(alice)
        assertFalse(files.sessionDir(alice).exists())
        store.clear(alice)
        assertEquals(SessionLoad.None, store.load(alice))
    }

    @Test
    fun `clearSession は印が同じときだけ session を丸ごと消す`() = runBlocking {
        putTwoPhotos(alice)
        store.save(alice, document(sessionId = "SESSION-1"))

        store.clearSession(alice, "SESSION-1")

        assertFalse(files.sessionDir(alice).exists())
    }

    @Test
    fun `clearSession は印が違えば何も消さない`() = runBlocking {
        putTwoPhotos(alice)
        store.save(alice, document(sessionId = "SESSION-NEW"))

        store.clearSession(alice, "SESSION-OLD")

        assertEquals("SESSION-NEW", assertIs<SessionLoad.Restored>(store.load(alice)).document.sessionId)
        assertTrue(files.resolve(alice, "session/photo-0").isFile)
        assertTrue(files.resolve(alice, "session/photo-1").isFile)
    }

    @Test
    fun `clearSession は文書が無ければ、残っている写しも消さない`() = runBlocking {
        putTwoPhotos(alice)

        store.clearSession(alice, "SESSION-1")

        assertTrue(files.resolve(alice, "session/photo-0").isFile)
        assertTrue(files.resolve(alice, "session/photo-1").isFile)
    }

    @Test
    fun `clearSession は空の印では、印の無い文書でも消さない`() = runBlocking {
        putTwoPhotos(alice)
        store.save(alice, document(sessionId = ""))

        store.clearSession(alice, "")

        assertTrue(files.sessionDocument(alice).isFile)
    }

    @Test
    fun `clearSession は別の uid の途中を消さない`() = runBlocking {
        putTwoPhotos(alice)
        store.save(alice, document(sessionId = "SESSION-1"))

        store.clearSession(bob, "SESSION-1")

        assertTrue(files.sessionDocument(alice).isFile)
    }

    @Test
    fun `clear と clearSession は、消せなくても例外を投げない`() = runBlocking {
        putTwoPhotos(alice)
        store.save(alice, document(sessionId = "SESSION-1"))
        ops.failWhen = { kind, _ -> kind == FaultyFileOps.Kind.DELETE }

        store.clear(alice)
        store.clearSession(alice, "SESSION-1")

        assertTrue(files.sessionDocument(alice).isFile)
    }

    // ── 写し（DefaultWorkingPhotoImporter） ──

    /** 元の写真の偽物（URI→バイト列）。無い URI は開くと FileNotFoundException */
    private val sources = mutableMapOf<String, ByteArray>()

    /** 撮影日時の読み取りの偽物。呼ばれた写真を控え、どの写真にも同じ撮影日時を返す */
    private val metadataCalls = mutableListOf<PickedPhoto>()
    private val metadataAnswer = CapturedAt(Instant.ofEpochMilli(takenAt), CapturedAtSource.ASSET)
    private val metadata = object : PhotoMetadataReader {
        override suspend fun capturedAt(photo: PickedPhoto): CapturedAt {
            metadataCalls += photo
            return metadataAnswer
        }
    }

    private val importer = DefaultWorkingPhotoImporter(
        files,
        { uri -> ByteArrayInputStream(sources[uri] ?: throw FileNotFoundException()) },
        metadata,
        errors,
    )

    private val picked = listOf(PickedPhoto("content://picker/photo/1", 0), PickedPhoto("content://picker/photo/2", 1))

    @Test
    fun `写しは選んだ順に session の photo-N へバイトのまま置き、撮影日時は 1 枚目だけ元の URI から読む`() = runBlocking {
        sources[picked[0].uri] = byteArrayOf(10, 20, 30)
        sources[picked[1].uri] = byteArrayOf(40, 50)

        val photos = importer.import(alice, picked)

        assertEquals(
            listOf(
                WorkingPhoto(files.fileUri(files.resolve(alice, "session/photo-0")), "session/photo-0", metadataAnswer),
                WorkingPhoto(files.fileUri(files.resolve(alice, "session/photo-1")), "session/photo-1", null),
            ),
            photos,
        )
        assertContentEquals(byteArrayOf(10, 20, 30), File(URI(photos[0].uri)).readBytes())
        assertContentEquals(byteArrayOf(40, 50), File(URI(photos[1].uri)).readBytes())
        assertEquals(listOf(picked[0]), metadataCalls)
        assertEquals(emptyList(), errors.errors)
    }

    @Test
    fun `写す前に前の編集の途中を消す`() = runBlocking {
        putTwoPhotos(alice)
        putPhoto(alice, "session/photo-5", byteArrayOf(9))
        store.save(alice, document(sessionId = "OLD"))
        sources[picked[0].uri] = byteArrayOf(10)

        importer.import(alice, picked.take(1))

        assertEquals(listOf("photo-0"), files.sessionDir(alice).list()!!.sorted())
        assertContentEquals(byteArrayOf(10), files.resolve(alice, "session/photo-0").readBytes())
        // 前の印の文書が残らないので、前の投稿の後始末は新しい写しを消さない
        store.clearSession(alice, "OLD")
        assertTrue(files.resolve(alice, "session/photo-0").isFile)
    }

    @Test
    fun `写せなかった写真は元の URI のまま返し、WorkingPhotoImporter import で記録する`() = runBlocking {
        sources[picked[0].uri] = byteArrayOf(10)

        val photos = importer.import(alice, picked)

        assertEquals("session/photo-0", photos[0].relativeFile)
        assertEquals(WorkingPhoto(picked[1].uri, relativeFile = null, capturedAt = null), photos[1])
        assertFalse(files.resolve(alice, "session/photo-1").exists())
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("FileNotFoundException") to "WorkingPhotoImporter.import"), errors.errors)
    }

    @Test
    fun `書いている途中で失敗した写しは、書きかけを残さず元の URI のまま返す`() = runBlocking {
        sources[picked[0].uri] = byteArrayOf(10, 20, 30, 40)
        ops.failWhen = { kind, file -> kind == FaultyFileOps.Kind.WRITE && file.name == "photo-0" }

        val photos = importer.import(alice, picked.take(1))

        assertEquals(listOf(WorkingPhoto(picked[0].uri, relativeFile = null, capturedAt = metadataAnswer)), photos)
        assertFalse(files.resolve(alice, "session/photo-0").exists())
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("IOException") to "WorkingPhotoImporter.import"), errors.errors)
    }

    @Test
    fun `前の途中を消せなければ 1 枚も写さず、全部を元の URI のまま返して記録する`() = runBlocking {
        putTwoPhotos(alice)
        store.save(alice, document(sessionId = "OLD"))
        sources[picked[0].uri] = byteArrayOf(10)
        sources[picked[1].uri] = byteArrayOf(20)
        ops.failWhen = { kind, file -> kind == FaultyFileOps.Kind.DELETE && file.name == "work.properties" }

        val photos = importer.import(alice, picked)

        assertEquals(
            listOf(WorkingPhoto(picked[0].uri, null, metadataAnswer), WorkingPhoto(picked[1].uri, null, null)),
            photos,
        )
        assertContentEquals(byteArrayOf(1, 2, 3), files.resolve(alice, "session/photo-0").readBytes())
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("IOException") to "WorkingPhotoImporter.import"), errors.errors)
    }

    @Test
    fun `写しは利用者ごとに分かれ、別の uid の途中を消さない`() = runBlocking {
        putTwoPhotos(bob)
        store.save(bob, document(sessionId = "BOB"))
        sources[picked[0].uri] = byteArrayOf(10)

        importer.import(alice, picked.take(1))

        assertEquals("BOB", assertIs<SessionLoad.Restored>(store.load(bob)).document.sessionId)
        assertNull(files.locked { files.readDocument(files.sessionDocument(alice)) })
    }
}
