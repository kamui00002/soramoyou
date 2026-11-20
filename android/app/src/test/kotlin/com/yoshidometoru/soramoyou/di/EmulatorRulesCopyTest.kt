// ⭐️☀️ 結合テスト用のエミュレータに読ませる rules の写し（make-emulator-rules.sh）の単体テスト（タスク 11.1・17.1・レビュー R14）
package com.yoshidometoru.soramoyou.di

import com.yoshidometoru.soramoyou.contract.rules.StorageDownloadUrl
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * `android/tools/make-emulator-rules.sh` が作る rules の写しを、台本を実際に流して確かめる。
 *
 * - 契約の本番の形（[StorageDownloadUrl.PRODUCTION_PATTERN]）が、リポジトリの firestore.rules の `isValidImageUrl` の形と
 *   文字どおり同じ（rules が変わったら、契約を合わせ直すまでここが赤になる）
 * - 本物の rules から作った写しは、storage.rules が原本とバイト単位で同じで、firestore.rules は `isValidImageUrl` の見出しの行と
 *   次の行の後ろに、エミュレータの形（[StorageDownloadUrl.EMULATOR_PATTERN]）の 1 行だけを足したもの
 *   （足す行は台本に文字で書いてあるので、契約の定数との同期もここで確かめる）
 * - 差し込む所が 0 か所・2 か所の rules では、台本が 0 以外で終わり、写しを 1 つも残さない（形を足さない写しでエミュレータを
 *   起こすと、結合テストの投稿が rules で断られて原因が分かりにくいため）
 *
 * 台本は `/bin/zsh -f` で、環境変数を空にして PATH を `/usr/bin:/bin` だけにして流す（利用者のシェルの設定に左右されないように）。
 * macOS の `/bin/zsh` と、台本が使う `/usr/bin` の `shasum`・`awk`・`grep`・`cut`・`cp` があることを前提にする（この Mac で流す単体テスト）。
 */
class EmulatorRulesCopyTest {

    /** :app のディレクトリ（単体テストの作業ディレクトリ）。 */
    private val appDir = File(requireNotNull(System.getProperty("user.dir")))
    private val repoRoot = File(appDir, "../..").canonicalFile
    private val firestoreRules = File(repoRoot, "firestore.rules")
    private val storageRules = File(repoRoot, "storage.rules")
    private val script = File(repoRoot, "android/tools/make-emulator-rules.sh")

    /** テストごとの一時ディレクトリ（原本の写し・台本の出力・台本の stdout と stderr）。 */
    private val workDir: File = Files.createTempDirectory("emulator-rules-copy").toFile()

    @AfterTest
    fun cleanUp() {
        workDir.deleteRecursively()
    }

    private class ScriptResult(val exit: Int, val stdout: String, val stderr: String)

    /** 台本に [src]（rules のあるディレクトリ）と [out]（写しを置くディレクトリ）を渡して流す。30 秒で終わらなければ止めて失敗にする。 */
    private fun runScript(src: File, out: File): ScriptResult {
        assertTrue(script.isFile, "写しの台本が無い: ${script.path}")
        val stdoutFile = File(workDir, "stdout.txt")
        val stderrFile = File(workDir, "stderr.txt")
        val builder = ProcessBuilder("/bin/zsh", "-f", script.path, src.path, out.path)
            .redirectOutput(stdoutFile)
            .redirectError(stderrFile)
        builder.environment().clear()
        builder.environment()["PATH"] = "/usr/bin:/bin"
        val process = builder.start()
        if (!process.waitFor(30, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            fail("写しの台本が 30 秒で終わらない")
        }
        return ScriptResult(process.exitValue(), stdoutFile.readText(), stderrFile.readText())
    }

    /** 原本の 2 つの rules を [dir] に写す（[firestore] を渡したら、firestore.rules はその中身にする）。 */
    private fun sourceDir(dir: File, firestore: String = firestoreRules.readText()): File {
        dir.mkdirs()
        File(dir, "firestore.rules").writeText(firestore)
        storageRules.copyTo(File(dir, "storage.rules"))
        return dir
    }

    /** 写しを置くディレクトリ（空で作る）。 */
    private fun outDir(): File = File(workDir, "out").also { it.mkdirs() }

    @Test
    fun `契約の本番の形はrulesのisValidImageUrlの形と文字どおり同じ`() {
        val lines = firestoreRules.readLines()
        assertEquals(1, lines.count { it == HEAD_LINE }, "isValidImageUrl の見出しの行がちょうど 1 つでない")
        val head = lines.indexOf(HEAD_LINE)
        assertEquals(NEXT_LINE, lines.getOrNull(head + 1), "isValidImageUrl の見出しの次の行が変わった")
        // 形の全体は (…)? で包まれている（空を通すため）。外側の包みだけを除いた中身を比べる
        val match = assertNotNull(
            Regex("""^ {13}\|\| value\.matches\('\((.*)\)\?'\);$""").find(lines.getOrNull(head + 2).orEmpty()),
            "isValidImageUrl の形の行が読めない",
        )
        assertEquals(StorageDownloadUrl.PRODUCTION_PATTERN, match.groupValues[1])
    }

    @Test
    fun `本物のrulesの写しはstorage_rulesが原本のままでfirestore_rulesにエミュレータの形を1行だけ足したもの`() {
        val out = outDir()
        val result = runScript(repoRoot, out)
        assertEquals(0, result.exit, "台本が失敗した: ${result.stderr}")
        assertEquals("", result.stderr)
        assertContentEquals(storageRules.readBytes(), File(out, "storage.rules").readBytes(), "storage.rules の写しが原本と違う")

        val original = firestoreRules.readText()
        val pair = "$HEAD_LINE\n$NEXT_LINE\n"
        assertEquals(1, Regex(Regex.escape(pair)).findAll(original).count(), "差し込む所がちょうど 1 か所でない")
        val expected = original.replace(pair, "$pair$ADD_LINE\n")
        assertEquals(expected, File(out, "firestore.rules").readText())
    }

    @Test
    fun `差し込む所が無いrulesでは台本が止まり写しを残さない`() {
        val renamed = firestoreRules.readText().replace(HEAD_LINE, "    function isValidImageUrl(v) {")
        assertNotEquals(firestoreRules.readText(), renamed, "前提: 見出しの行を書き換えられていない")
        assertStopsWithoutCopies(sourceDir(File(workDir, "src"), renamed))
    }

    @Test
    fun `差し込む所が2つあるrulesでは台本が止まり写しを残さない`() {
        val twice = firestoreRules.readText() + "$HEAD_LINE\n$NEXT_LINE\n"
        assertStopsWithoutCopies(sourceDir(File(workDir, "src"), twice))
    }

    private fun assertStopsWithoutCopies(src: File) {
        val out = outDir()
        val result = runScript(src, out)
        assertNotEquals(0, result.exit, "差し込む所がちょうど 1 か所でないのに台本が成功した")
        assertTrue("ちょうど 1 か所でない" in result.stderr, "止まった理由が stderr に無い: ${result.stderr}")
        assertFalse(File(out, "firestore.rules").exists(), "firestore.rules の写しが残った")
        assertFalse(File(out, "storage.rules").exists(), "storage.rules の写しが残った")
    }

    private companion object {
        /** 差し込む所：isValidImageUrl の見出しの行と、その次の行（台本と同じ）。 */
        const val HEAD_LINE = "    function isValidImageUrl(value) {"
        const val NEXT_LINE = "      return value == null"

        /** 足す 1 行。字下げは rules の `|| value.matches(` の行と同じ半角 13 個。 */
        val ADD_LINE = " ".repeat(13) + "|| value.matches('${StorageDownloadUrl.EMULATOR_PATTERN}')"
    }
}
