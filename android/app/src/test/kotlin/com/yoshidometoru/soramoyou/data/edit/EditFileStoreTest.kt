// ⭐️ 端末の中の置き場（EditFileStore）の単体テスト。JVM の一時のフォルダで確かめる（Kiro android-edit-tools タスク 14.1・A4・design.md:1137・要件 8.11・12.4）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import com.yoshidometoru.soramoyou.platform.ScreenName
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.URI
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * 利用者ごとに分かれる（別の uid から見えない）・英数字でない uid は 16 進の名前・書き込みの途中で落ちても前の文書が残る・
 * `..` などの場所を拒む、を確かめる。陽性対照は「uid のフォルダを共通にする」（[userFolderName] を通さずに 1 つのフォルダにする）。
 */
class EditFileStoreTest {

    private val base: File = createTempDirectory("edit-file-store").toFile()
    private val ops = FaultyFileOps()
    private val files = EditFileStore(base, ops = ops)

    private val alice = Uid("aliceUid0001")
    private val bob = Uid("bobUid0002")

    @AfterTest
    fun deleteBase() {
        base.deleteRecursively()
    }

    // ── 利用者ごとに分かれる ──

    @Test
    fun `利用者ごとにフォルダが分かれ、別の uid からは同じ相対の場所でも文書が見えない`() = runBlocking {
        val document = mapOf("version" to "1", "caption" to "アリスの途中")
        files.locked { files.writeDocument(files.resolve(alice, "session/work.properties"), document) }

        assertEquals(document, files.locked { files.readDocument(files.resolve(alice, "session/work.properties")) })
        assertNull(files.locked { files.readDocument(files.resolve(bob, "session/work.properties")) })
        assertNotEquals(files.userDir(alice), files.userDir(bob))
        assertFalse(File(files.userDir(bob), "session/work.properties").exists())
    }

    @Test
    fun `根は渡したフォルダの下の edit で、利用者のフォルダは users の下に uid の名前で作る`() = runBlocking {
        files.locked { files.writeDocument(files.sessionDocument(alice), mapOf("version" to "1")) }

        assertEquals(File(base, "edit"), files.root)
        assertTrue(File(base, "edit/users/aliceUid0001/session/work.properties").isFile)
        assertEquals(File(base, "edit/loadout.properties"), files.loadoutFile)
    }

    // ── 利用者のフォルダの名前 ──

    @Test
    fun `英数字の uid はそのままの名前にする`() {
        assertEquals("abcXYZ019", EditFileStore.userFolderName(Uid("abcXYZ019")))
        val longest = "a".repeat(128)
        assertEquals(longest, EditFileStore.userFolderName(Uid(longest)))
    }

    @Test
    fun `英数字でない uid は、UTF-8 の 16 進の頭に目印を付けた名前にする`() {
        assertEquals("_612f62", EditFileStore.userFolderName(Uid("a/b")))
        assertEquals("_2e2e", EditFileStore.userFolderName(Uid("..")))
        assertEquals("_e383a6e383bce382b6e383bc", EditFileStore.userFolderName(Uid("ユーザー")))
        // 129 文字は英数字でも 16 進にする
        assertEquals("_" + "61".repeat(129), EditFileStore.userFolderName(Uid("a".repeat(129))))
    }

    @Test
    fun `英数字でない uid のフォルダは 16 進の名前で作られ、16 進と同じ文字の英数字の uid とは分かれる`() = runBlocking {
        val slashed = Uid("a/b")
        val lookalike = Uid("612f62")
        files.locked { files.writeDocument(files.sessionDocument(slashed), mapOf("version" to "1")) }

        assertTrue(File(base, "edit/users/_612f62/session/work.properties").isFile)
        assertFalse(File(base, "edit/users/a").exists())
        assertNull(files.locked { files.readDocument(files.sessionDocument(lookalike)) })
    }

    @Test
    fun `空の uid は users のフォルダそのものを指すので拒む`() {
        assertFailsWith<IllegalArgumentException> { EditFileStore.userFolderName(Uid("")) }
        assertFailsWith<IllegalArgumentException> { files.userDir(Uid("")) }
    }

    // ── 書き込みの途中で落ちても前の文書が残る ──

    @Test
    fun `書いている途中で失敗しても前の文書が残り、書きかけの一時のファイルを残さない`() = runBlocking {
        val target = files.sessionDocument(alice)
        val before = mapOf("version" to "1", "caption" to "前の文書")
        files.locked { files.writeDocument(target, before) }
        ops.failWhen = { kind, file -> kind == FaultyFileOps.Kind.WRITE && file.name.startsWith("work.properties") }

        assertFailsWith<IOException> {
            files.locked { files.writeDocument(target, mapOf("version" to "1", "caption" to "新しい文書")) }
        }

        assertEquals(before, files.locked { files.readDocument(target) })
        assertEquals(listOf("work.properties"), target.parentFile!!.list()!!.sorted())
        // 失敗は本当に書いている途中で起きた（偽物が半分だけ書いてから投げた）
        assertTrue(ops.calls.any { it.first == FaultyFileOps.Kind.WRITE && it.second.name == "work.properties.part" })
    }

    @Test
    fun `名前を変える所で失敗しても前の文書が残る`() = runBlocking {
        val target = files.sessionDocument(alice)
        val before = mapOf("version" to "1", "caption" to "前の文書")
        files.locked { files.writeDocument(target, before) }
        ops.failWhen = { kind, file -> kind == FaultyFileOps.Kind.RENAME && file.name == "work.properties" }

        assertFailsWith<IOException> {
            files.locked { files.writeDocument(target, mapOf("version" to "1", "caption" to "新しい文書")) }
        }

        assertEquals(before, files.locked { files.readDocument(target) })
        assertEquals(listOf("work.properties"), target.parentFile!!.list()!!.sorted())
    }

    @Test
    fun `落ちて一時のファイルが残っていても、文書は前のまま読め、次の書き込みは通る`() = runBlocking {
        val target = files.sessionDocument(alice)
        files.locked { files.writeDocument(target, mapOf("version" to "1", "caption" to "前の文書")) }
        // 書いている途中でプロセスが落ちた形：書きかけの一時のファイルだけがある
        File(target.parentFile, "work.properties.part").writeText("caption=書きか")

        assertEquals("前の文書", files.locked { files.readDocument(target) }!!["caption"])
        files.locked { files.writeDocument(target, mapOf("version" to "1", "caption" to "次の文書")) }
        assertEquals("次の文書", files.locked { files.readDocument(target) }!!["caption"])
    }

    @Test
    fun `文書は改行や日本語を含む値も、そのまま読み戻せる`() = runBlocking {
        val document = mapOf("caption" to "1行目\n2行目 #空 = : \\ 終わり", "version" to "1")
        files.locked { files.writeDocument(files.sessionDocument(alice), document) }

        assertEquals(document, files.locked { files.readDocument(files.sessionDocument(alice)) })
    }

    @Test
    fun `壊れた書き方の文書は、読む時に例外になる`() = runBlocking {
        val target = files.sessionDocument(alice)
        target.parentFile!!.mkdirs()
        target.writeText("caption=\\uZZZZ\n")

        assertFailsWith<IllegalArgumentException> { files.locked { files.readDocument(target) } }
        Unit
    }

    // ── 場所の検査 ──

    @Test
    fun `利用者のフォルダの外を指しうる場所は拒む`() {
        val unsafe = listOf(
            "../bobUid0002/session/work.properties",
            "session/../../bobUid0002/session/work.properties",
            "..",
            "/session/work.properties",
            "",
            "session//work.properties",
            "session/./work.properties",
            "session/",
            "session\\work.properties",
            "C:session",
            "session/work\u0000.properties",
        )
        for (path in unsafe) {
            assertFailsWith<UnsafeEditPathException>("拒むはず: $path") { files.resolve(alice, path) }
        }
    }

    @Test
    fun `相対の場所は利用者のフォルダの中のファイルになる`() {
        val file = files.resolve(alice, "drafts/ABC-1/photo-0")

        assertEquals(File(files.userDir(alice), "drafts/ABC-1/photo-0"), file)
        assertTrue(file.absolutePath.startsWith(files.userDir(alice).absolutePath + File.separator))
    }

    @Test
    fun `写真が無ければ MissingEditPhotoException`() {
        assertFailsWith<MissingEditPhotoException> { files.requirePhoto(alice, "session/photo-0") }
    }

    @Test
    fun `下書きの ID は英数字とハイフンだけを受け付ける`() {
        assertTrue(EditFileStore.isSafeDraftId("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        for (bad in listOf("", "..", "a.tmp", "a/b", "a b", "a".repeat(65), "ア")) {
            assertFalse(EditFileStore.isSafeDraftId(bad), "受け付けないはず: $bad")
        }
    }

    @Test
    fun `ファイルの URI は file のスキームで、元のファイルを指す`() {
        val file = files.resolve(alice, "session/photo-0")
        val uri = files.fileUri(file)

        assertTrue(uri.startsWith("file:///"), uri)
        assertEquals(file.absoluteFile, File(URI(uri)))
    }
}

// ── 端末の保存のテストで共有する偽物（EditSessionStoreTest・LocalDraftRepositoryTest・LoadoutStoreTest も使う） ──

/**
 * 書く操作の偽物。本物の操作（[EditFileOps.Real]）に任せ、[failWhen] が true を返した操作だけ IOException を投げる。
 * 書く操作（WRITE）は、半分だけ書いてから投げる（書いている途中で落ちた形）。[calls] に、呼ばれた操作の種類と行き先を控える
 * （名前を変える操作の行き先は変えた後の名前）。
 */
internal class FaultyFileOps : EditFileOps {
    enum class Kind { WRITE, RENAME, DELETE, MKDIRS }

    val calls = mutableListOf<Pair<Kind, File>>()
    var failWhen: (kind: Kind, target: File) -> Boolean = { _, _ -> false }

    override fun write(target: File, source: InputStream) {
        calls += Kind.WRITE to target
        if (failWhen(Kind.WRITE, target)) {
            val bytes = source.readBytes()
            target.writeBytes(bytes.copyOf(bytes.size / 2))
            throw IOException("テストで起こした書き込みの失敗")
        }
        EditFileOps.Real.write(target, source)
    }

    override fun rename(from: File, to: File) {
        calls += Kind.RENAME to to
        if (failWhen(Kind.RENAME, to)) throw IOException("テストで起こした名前の変更の失敗")
        EditFileOps.Real.rename(from, to)
    }

    override fun delete(target: File) {
        calls += Kind.DELETE to target
        if (failWhen(Kind.DELETE, target)) throw IOException("テストで起こした削除の失敗")
        EditFileOps.Real.delete(target)
    }

    override fun mkdirs(dir: File) {
        calls += Kind.MKDIRS to dir
        if (failWhen(Kind.MKDIRS, dir)) throw IOException("テストで起こしたフォルダの作成の失敗")
        EditFileOps.Real.mkdirs(dir)
    }

    companion object {
        /** [kind] の操作で、行き先が [matches] に当たる最初の 1 回だけ失敗させる条件 */
        fun once(kind: Kind, matches: (File) -> Boolean): (Kind, File) -> Boolean {
            var fired = false
            return { k, target ->
                if (!fired && k == kind && matches(target)) {
                    fired = true
                    true
                } else {
                    false
                }
            }
        }
    }
}

/** 記録（logError）だけを控える分析の窓口の偽物 */
internal class RecordingEditErrors : AnalyticsFacade {
    val errors = mutableListOf<Pair<AppError, String>>()
    override fun logEvent(name: EventName, params: Map<String, ParamValue>) = Unit
    override fun logScreen(name: ScreenName) = Unit
    override fun logError(error: AppError, context: String) {
        errors += error to context
    }
    override fun setUserId(uid: Uid?) = Unit
}
