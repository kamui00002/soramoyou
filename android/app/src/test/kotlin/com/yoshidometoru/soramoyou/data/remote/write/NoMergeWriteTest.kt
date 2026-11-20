// ⭐️ 書き込みの入口が、既存の値とマージする書き込みを使っていないことの検査（タスク 6.2・設計書 :663）
package com.yoshidometoru.soramoyou.data.remote.write

import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * merge の指定つきの set は、既存の値を書き戻す経路になるので提供しない（設計書 :663 の不変条件）。
 * SDK で merge を指定する唯一の手段は SetOptions なので、書き込みの入口の package のソースにその名前が現れないことを確かめる。
 * package の外での書き込み API の検出はタスク 6.5 のアーキテクチャテストが受け持つ（ここは package の中だけ）。
 *
 * 文字列の走査なので、コメントの中の名前も数える。説明にその名前を書かない。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）。
 */
class NoMergeWriteTest {

    private val writePackage = File("src/main/kotlin/com/yoshidometoru/soramoyou/data/remote/write")

    private val fixtureRoot: File = createTempDirectory("no-merge-write").toFile()

    @AfterTest
    fun deleteFixtures() {
        fixtureRoot.deleteRecursively()
    }

    /** [dir] の下の .kt ファイルで、merge の指定に使う名前が現れる行を「ファイル名:行番号」で返す。 */
    private fun mergeOptionHits(dir: File): List<String> =
        dir.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .sortedBy { it.path }
            .flatMap { file ->
                file.readLines().withIndex()
                    .filter { (_, line) -> MERGE_OPTION in line }
                    .map { (index, _) -> "${file.name}:${index + 1}" }
            }
            .toList()

    @Test
    fun `書き込みの入口のソースは、mergeを指定する手段を使っていない`() {
        // 走査の対象を取り違えると空振りで通るので、package の実物を読んでいることも確かめる
        assertTrue(File(writePackage, "FirebaseFirestoreWriteClient.kt").isFile, "書き込みの入口のソースが見つからない: ${writePackage.absolutePath}")

        assertEquals(emptyList(), mergeOptionHits(writePackage))
    }

    @Test
    fun `mergeを指定するソースがあれば検出する（陽性対照）`() {
        File(fixtureRoot, "Bad.kt").writeText("fun bad() {\n    doc.set(data, $MERGE_OPTION.merge())\n}\n")

        assertEquals(listOf("Bad.kt:2"), mergeOptionHits(fixtureRoot))
    }

    private companion object {
        /** Firestore の SDK で merge を指定する型の名前（ソースに直書きすると、このテスト自身は対象外でも紛らわしいので組み立てる）。 */
        val MERGE_OPTION = "Set" + "Options"
    }
}
