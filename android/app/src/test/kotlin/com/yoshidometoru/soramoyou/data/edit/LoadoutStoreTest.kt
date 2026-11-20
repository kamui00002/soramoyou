// ⭐️ 装備の保存（DefaultLoadoutStore）の単体テスト。JVM の一時のフォルダで確かめる（Kiro android-edit-tools タスク 14.2・A4・design.md:1137・要件 7.2・7.3・7.9・7.10）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.Loadout
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.runBlocking

/**
 * 保存して読み直すと同じ・壊れていれば既定（記録する）・知らない名前を捨てる・利用者のフォルダの外に置く・保存の失敗は Err で記録する、を確かめる。
 * 陽性対照は「読めないときに DEFAULT にする処理を外す」（`loadOnce` の catch の `Loadout.DEFAULT` を `throw e` にする）。
 * そのとき「壊れて読めない」系のテストは、最初の読み込みの失敗が [DefaultLoadoutStore.awaitLoaded] からそのまま届いて赤になる。
 */
class LoadoutStoreTest {

    private val base: File = createTempDirectory("loadout-store").toFile()
    private val ops = FaultyFileOps()
    private val files = EditFileStore(base, ops = ops)
    private val errors = RecordingEditErrors()

    private val custom = Loadout(listOf(EditTool.CONTRAST, EditTool.EXPOSURE, EditTool.CROP_AND_ROTATE))

    @AfterTest
    fun deleteBase() {
        base.deleteRecursively()
    }

    private fun CoroutineScope.newStore() = DefaultLoadoutStore(files, errors, this)

    /** 装備の文書を、本体を通さずに直接書く（壊れた文書を置くため） */
    private fun writeRaw(text: String) {
        files.loadoutFile.parentFile!!.mkdirs()
        files.loadoutFile.writeText(text, Charsets.UTF_8)
    }

    // ── 保存と読み直し ──

    @Test
    fun `保存した装備は、作り直したストアが読み直しても同じ`() = runBlocking {
        val first = newStore()
        first.awaitLoaded()

        assertEquals(AppResult.Ok(Unit), first.save(custom))
        assertEquals(custom, first.loadout.value)

        val second = newStore()
        second.awaitLoaded()
        assertEquals(custom, second.loadout.value)
        assertEquals(emptyList(), errors.errors)
    }

    @Test
    fun `読み終わるまでは既定の装備を配り、読み終わると保存した装備になる`() = runBlocking {
        newStore().apply { awaitLoaded() }.save(custom)

        val store = newStore()
        // まだ読み込みは走っていない（このコルーチンが止まるまで始まらない）
        assertEquals(Loadout.DEFAULT, store.loadout.value)
        store.awaitLoaded()
        assertEquals(custom, store.loadout.value)
    }

    @Test
    fun `まだ一度も保存していなければ既定の装備で、記録しない`() = runBlocking {
        val store = newStore()
        store.awaitLoaded()

        assertEquals(Loadout.DEFAULT, store.loadout.value)
        assertEquals(emptyList(), errors.errors)
    }

    // ── 壊れていれば既定 ──

    @Test
    fun `書き方が壊れて読めない装備は既定の装備になり、LoadoutStore load で記録する`() = runBlocking {
        writeRaw("version=1\ntools=\\uZZZZ\n")

        val store = newStore()
        store.awaitLoaded()

        assertEquals(Loadout.DEFAULT, store.loadout.value)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("IllegalArgumentException") to "LoadoutStore.load"), errors.errors)
    }

    @Test
    fun `版が新しすぎて読めない装備は既定の装備になり、LoadoutStore load で記録する`() = runBlocking {
        writeRaw("version=99\ntools=contrast\n")

        val store = newStore()
        store.awaitLoaded()

        assertEquals(Loadout.DEFAULT, store.loadout.value)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("BrokenEditDocumentException") to "LoadoutStore.load"), errors.errors)
    }

    @Test
    fun `装備のファイルを開けなければ既定の装備になり、記録する`() = runBlocking {
        // ファイルの場所にフォルダがある（開くと例外）
        File(files.loadoutFile, "x").mkdirs()

        val store = newStore()
        store.awaitLoaded()

        assertEquals(Loadout.DEFAULT, store.loadout.value)
        assertEquals(1, errors.errors.size)
        assertEquals("LoadoutStore.load", errors.errors.single().second)
    }

    @Test
    fun `知らない名前と重複を捨て、読める分だけを保存した順で使う`() = runBlocking {
        writeRaw("version=1\ntools=exposure,sharpness,contrast,exposure\n")

        val store = newStore()
        store.awaitLoaded()

        assertEquals(Loadout(listOf(EditTool.EXPOSURE, EditTool.CONTRAST)), store.loadout.value)
        assertEquals(emptyList(), errors.errors)
    }

    @Test
    fun `既定の装備をそのまま保存した文書は、読めなかったと記録しない`() = runBlocking {
        newStore().apply { awaitLoaded() }.save(Loadout.DEFAULT)

        val store = newStore()
        store.awaitLoaded()

        assertEquals(Loadout.DEFAULT, store.loadout.value)
        assertEquals(emptyList(), errors.errors)
    }

    // ── 置き場 ──

    @Test
    fun `装備は利用者のフォルダの外の edit の loadout properties に置き、利用者のフォルダを作らない`() = runBlocking {
        newStore().apply { awaitLoaded() }.save(custom)

        assertTrue(File(base, "edit/loadout.properties").isFile)
        assertFalse(File(base, "edit/users").exists())
        assertEquals(
            mapOf("version" to "1", "tools" to "contrast,exposure,cropAndRotate"),
            files.locked { files.readDocument(files.loadoutFile) },
        )
    }

    // ── 保存の失敗 ──

    @Test
    fun `保存に失敗したら Err を返して LoadoutStore save で記録し、配る装備も保存した文書も変えない`() = runBlocking {
        val store = newStore()
        store.awaitLoaded()
        store.save(custom)
        ops.failWhen = { kind, file -> kind == FaultyFileOps.Kind.RENAME && file.name == "loadout.properties" }

        val result = store.save(Loadout(listOf(EditTool.FADE)))

        assertEquals(AppResult.Err(AppError.Unknown("IOException")), result)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("IOException") to "LoadoutStore.save"), errors.errors)
        assertEquals(custom, store.loadout.value)
        ops.failWhen = { _, _ -> false }
        val reread = newStore()
        reread.awaitLoaded()
        assertEquals(custom, reread.loadout.value)
    }
}
