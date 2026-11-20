// ⭐️ ログアウト・退会での端末のデータの後始末（DefaultUserEditDataPurger）の単体テスト（Kiro android-edit-tools タスク 17・A5・design.md:952-966・要件 7.9・8.12〜8.14・12.5）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.Uid
import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * 理由ごとの表（3 つの理由で編集の途中と下書きがどうなるか）・装備はどの理由でも残る・別の uid のフォルダに触れない・
 * 失敗しても例外を投げずに記録する、を確かめる。本物の [EditFileStore] を JVM の一時のフォルダで使う。
 * 陽性対照は「`SIGN_OUT` で下書きも消す」（理由の表の分かれ目を変える）。
 */
class UserEditDataPurgerTest {

    private val base: File = createTempDirectory("user-edit-data-purger").toFile()
    private val ops = FaultyFileOps()
    private val files = EditFileStore(base, ops = ops)
    private val errors = RecordingEditErrors()
    private val purger = DefaultUserEditDataPurger(files, errors)

    private val alice = Uid("aliceUid0001")
    private val bob = Uid("bobUid0002")

    @AfterTest
    fun deleteBase() {
        base.deleteRecursively()
    }

    /** 編集の途中（文書と写しの写真）と、下書きを 2 件、装備を置く */
    private fun seed(uid: Uid) {
        put(File(files.sessionDir(uid), EditFileStore.WORK_FILE))
        put(File(files.sessionDir(uid), "photo-0"))
        put(File(files.draftsDir(uid), "DRAFT-1/${EditFileStore.DRAFT_FILE}"))
        put(File(files.draftsDir(uid), "DRAFT-1/photo-0"))
        put(File(files.draftsDir(uid), "DRAFT-2/${EditFileStore.DRAFT_FILE}"))
    }

    private fun put(file: File) {
        file.parentFile!!.mkdirs()
        file.writeBytes(byteArrayOf(1, 2, 3))
    }

    private fun seedLoadout() = put(files.loadoutFile)

    // ── 理由ごとの表 ──

    @Test
    fun `ログアウト（匿名でない）は編集の途中を消し、下書きを残す`() = runBlocking {
        seed(alice)

        purger.purge(alice, SessionEndReason.SIGN_OUT)

        assertFalse(files.sessionDir(alice).exists(), "編集の途中が残っている")
        assertTrue(File(files.draftsDir(alice), "DRAFT-1/${EditFileStore.DRAFT_FILE}").isFile, "下書き 1 が消えている")
        assertTrue(File(files.draftsDir(alice), "DRAFT-1/photo-0").isFile, "下書き 1 の写真が消えている")
        assertTrue(File(files.draftsDir(alice), "DRAFT-2/${EditFileStore.DRAFT_FILE}").isFile, "下書き 2 が消えている")
        assertEquals(emptyList(), errors.errors)
    }

    @Test
    fun `匿名のログアウトは編集の途中と下書きを消す`() = runBlocking {
        seed(alice)

        purger.purge(alice, SessionEndReason.SIGN_OUT_ANONYMOUS)

        assertFalse(files.sessionDir(alice).exists(), "編集の途中が残っている")
        assertFalse(files.draftsDir(alice).exists(), "下書きが残っている")
        assertEquals(emptyList(), errors.errors)
    }

    @Test
    fun `退会は編集の途中と下書きを消す`() = runBlocking {
        seed(alice)

        purger.purge(alice, SessionEndReason.ACCOUNT_DELETED)

        assertFalse(files.sessionDir(alice).exists(), "編集の途中が残っている")
        assertFalse(files.draftsDir(alice).exists(), "下書きが残っている")
        assertEquals(emptyList(), errors.errors)
    }

    @Test
    fun `装備は、どの理由でも触れない`() = runBlocking {
        SessionEndReason.entries.forEach { reason ->
            seed(alice)
            seedLoadout()

            purger.purge(alice, reason)

            assertTrue(files.loadoutFile.isFile, "$reason: 装備が消えている")
            assertEquals(listOf<Byte>(1, 2, 3), files.loadoutFile.readBytes().toList(), "$reason: 装備の中身が変わっている")
        }
    }

    // ── 空になった利用者のフォルダ（タスク 20.6 の④。20.3 で、退会の後に空の users/<uid>/ が残るのを端末で見た） ──

    @Test
    fun `退会と匿名のログアウトは、空になった利用者のフォルダも消し、別の利用者のフォルダは残す`() = runBlocking {
        listOf(SessionEndReason.ACCOUNT_DELETED, SessionEndReason.SIGN_OUT_ANONYMOUS).forEach { reason ->
            seed(alice)
            seed(bob)
            assertTrue(files.userDir(alice).isDirectory, "$reason: テストの前提（利用者のフォルダが在る）が崩れた")

            purger.purge(alice, reason)

            assertFalse(files.userDir(alice).exists(), "$reason: 空になった利用者のフォルダが残っている")
            assertTrue(files.userDir(bob).isDirectory, "$reason: 別の利用者のフォルダが消えている")
            assertEquals(emptyList(), errors.errors)
            files.userDir(bob).deleteRecursively()
        }
    }

    @Test
    fun `ログアウト（匿名でない）は、下書きが残る利用者のフォルダを消さず、下書きが無ければ空のフォルダを消す`() = runBlocking {
        seed(alice)
        purger.purge(alice, SessionEndReason.SIGN_OUT)
        assertTrue(files.draftsDir(alice).isDirectory, "下書きが残る利用者のフォルダを消した")
        assertEquals(emptyList(), errors.errors)

        // 下書きを 1 件も持たない人（編集の途中だけ）は、ログアウトでフォルダが空になるので消す
        put(File(files.sessionDir(bob), EditFileStore.WORK_FILE))
        purger.purge(bob, SessionEndReason.SIGN_OUT)
        assertFalse(files.userDir(bob).exists(), "空になった利用者のフォルダが残っている")
        assertEquals(emptyList(), errors.errors)
    }

    @Test
    fun `編集の途中が消せずに残ったときは、利用者のフォルダを消さず、記録は消せなかった1件だけ`() = runBlocking {
        seed(alice)
        ops.failWhen = { kind, target -> kind == FaultyFileOps.Kind.DELETE && target == files.sessionDir(alice) }

        purger.purge(alice, SessionEndReason.ACCOUNT_DELETED)

        assertTrue(File(files.sessionDir(alice), EditFileStore.WORK_FILE).isFile, "空でない利用者のフォルダを消した")
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("IOException") to "UserEditDataPurger.purge"), errors.errors)
    }

    // ── 別の uid ──

    @Test
    fun `別の利用者のフォルダには、どの理由でも触れない`() = runBlocking {
        SessionEndReason.entries.forEach { reason ->
            seed(alice)
            seed(bob)

            purger.purge(alice, reason)

            assertTrue(File(files.sessionDir(bob), EditFileStore.WORK_FILE).isFile, "$reason: 別の利用者の編集の途中が消えている")
            assertTrue(File(files.draftsDir(bob), "DRAFT-1/${EditFileStore.DRAFT_FILE}").isFile, "$reason: 別の利用者の下書きが消えている")
            assertTrue(File(files.draftsDir(bob), "DRAFT-2/${EditFileStore.DRAFT_FILE}").isFile, "$reason: 別の利用者の下書き 2 が消えている")
            // 次の理由のために、別の利用者のフォルダを置き直す前に片付ける
            files.userDir(bob).deleteRecursively()
        }
    }

    @Test
    fun `何も置いていない利用者でも失敗せず、記録も残らない`() = runBlocking {
        SessionEndReason.entries.forEach { reason -> purger.purge(alice, reason) }

        assertEquals(emptyList(), errors.errors)
    }

    // ── 失敗 ──

    @Test
    fun `消せなくても例外を投げず、発生箇所つきで記録する（場所や本文は入れない）`() = runBlocking {
        seed(alice)
        ops.failWhen = { kind, _ -> kind == FaultyFileOps.Kind.DELETE }

        // 例外が外へ出れば、この呼び出しでテストが落ちる
        purger.purge(alice, SessionEndReason.ACCOUNT_DELETED)

        assertTrue(errors.errors.isNotEmpty(), "失敗が記録されていない")
        errors.errors.forEach { (error, context) ->
            assertEquals(AppError.Unknown("IOException"), error)
            assertEquals("UserEditDataPurger.purge", context)
        }
    }

    @Test
    fun `編集の途中が消せなくても、下書きは消す（退会で下書きだけでも消える）`() = runBlocking {
        seed(alice)
        ops.failWhen = { kind, target -> kind == FaultyFileOps.Kind.DELETE && target == files.sessionDir(alice) }

        purger.purge(alice, SessionEndReason.ACCOUNT_DELETED)

        assertTrue(files.sessionDir(alice).exists(), "失敗させたはずの編集の途中が消えている（テストの前提が崩れた）")
        assertFalse(files.draftsDir(alice).exists(), "下書きが残っている")
        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("IOException") to "UserEditDataPurger.purge"), errors.errors)
    }

    @Test
    fun `利用者のフォルダの名前が決められなくても（空のuid）、例外を投げずに記録する`() = runBlocking {
        purger.purge(Uid(""), SessionEndReason.SIGN_OUT)

        assertEquals(listOf<Pair<AppError, String>>(AppError.Unknown("IllegalArgumentException") to "UserEditDataPurger.purge"), errors.errors)
    }

    @Test
    fun `消した後の鍵は開いていて、続けて別の操作ができる（鍵を握ったままにしない）`() = runBlocking {
        seed(alice)

        purger.purge(alice, SessionEndReason.SIGN_OUT)
        // 2 回目の purge が止まらずに終わることで、鍵が解かれていることを見る（止まれば runBlocking が返らない）
        purger.purge(alice, SessionEndReason.ACCOUNT_DELETED)

        assertFalse(files.userDir(alice).resolve(EditFileStore.DRAFTS_DIR).exists())
    }
}
