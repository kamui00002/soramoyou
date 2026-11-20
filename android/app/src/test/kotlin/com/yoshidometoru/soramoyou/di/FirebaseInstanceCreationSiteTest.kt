// ⭐️ Firestore・Storage のインスタンスを作る場所が AppContainer だけであることの検査（タスク 5.1・要件 2.2）
package com.yoshidometoru.soramoyou.di

import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * FirebaseFirestore・FirebaseStorage のインスタンスを得るコードは、依存を組み立てる [AppContainer] にだけ置く
 * （設計書「M1の書き込みゼロ保証」2）。ほかの場所で得られると、メモリだけのキャッシュの設定やログアウトでの作り直し
 * （[ResettableInstance]）を通らないインスタンスが生まれる。
 *
 * ソースの文字列を走査する検査なので、別名の import などの書き方は検出できない（書き込み API の検査
 * （WriteApiConfinementTest）は、コンパイル済みのクラスを走査してこの限界を避けている）。コメントの中の文字列も検出するので、説明には完全な呼び出しの形を書かない。
 *
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class FirebaseInstanceCreationSiteTest {

    private val sourceRoot = File("src/main/kotlin")

    /** 陽性対照のための一時的なソースの置き場。テストごとに消す。 */
    private val fixtureRoot: File = createTempDirectory("instance-creation-site").toFile()

    @AfterTest
    fun deleteFixtures() {
        fixtureRoot.deleteRecursively()
    }

    private fun fixture(relativePath: String, source: String) {
        File(fixtureRoot, relativePath).apply {
            checkNotNull(parentFile).mkdirs()
            writeText(source)
        }
    }

    @Test
    fun `FirestoreとStorageのインスタンスを得るコードはAppContainerにしかない`() {
        assertTrue(sourceRoot.isDirectory, "ソースが見つからない: ${sourceRoot.absolutePath}")

        val hits = FirebaseInstanceCreationScanner.scan(sourceRoot, FirebaseInstanceCreationScanner.ALLOWED_PATH)

        assertEquals(emptyList(), hits, "AppContainer の外で Firestore・Storage のインスタンスを得ている")
    }

    @Test
    fun `本物のAppContainerは、FirestoreとStorageのインスタンスを得ている（上の検査が空振りしていない）`() {
        // 走査の対象を取り違えていても上の検査は通ってしまうので、許可した 1 か所で実際に検出できることも確かめる
        val appContainer = File(sourceRoot, FirebaseInstanceCreationScanner.ALLOWED_PATH)
        assertTrue(appContainer.isFile, "AppContainer が見つからない: ${appContainer.absolutePath}")

        val hits = FirebaseInstanceCreationScanner.scan(sourceRoot, allowedPath = null)
            .filter { it.path == FirebaseInstanceCreationScanner.ALLOWED_PATH }

        assertTrue(hits.any { "Firestore" in it.text }, "AppContainer で Firestore のインスタンスを得ていない: $hits")
        assertTrue(hits.any { "Storage" in it.text }, "AppContainer で Storage のインスタンスを得ていない: $hits")
    }

    @Test
    fun `陽性対照：AppContainerの外でのFirestoreとStorageのgetInstanceを検出する`() {
        fixture(
            "com/example/feature/Bad.kt",
            """
            package com.example.feature
            val db = FirebaseFirestore.getInstance()
            val storage = FirebaseStorage
                .getInstance(app)
            """.trimIndent(),
        )

        val hits = FirebaseInstanceCreationScanner.scan(fixtureRoot, FirebaseInstanceCreationScanner.ALLOWED_PATH)

        assertEquals(listOf(2, 3), hits.map { it.line }, "検出した行: $hits")
        assertTrue(hits.all { it.path == "com/example/feature/Bad.kt" })
    }

    @Test
    fun `陽性対照：Firebaseの拡張プロパティと、その import を検出する`() {
        fixture(
            "com/example/feature/Ext.kt",
            """
            package com.example.feature
            import com.google.firebase.firestore.firestore
            import com.google.firebase.storage.storage
            val db = Firebase.firestore
            val storage = Firebase.storage(app)
            """.trimIndent(),
        )

        val hits = FirebaseInstanceCreationScanner.scan(fixtureRoot, FirebaseInstanceCreationScanner.ALLOWED_PATH)

        assertEquals(listOf(2, 3, 4, 5), hits.map { it.line }, "検出した行: $hits")
    }

    @Test
    fun `陽性対照：getInstance を直接 import する書き方を検出する`() {
        fixture(
            "com/example/feature/StaticImport.kt",
            """
            package com.example.feature
            import com.google.firebase.firestore.FirebaseFirestore.getInstance
            import com.google.firebase.storage.FirebaseStorage.getInstance as storageOf
            """.trimIndent(),
        )

        val hits = FirebaseInstanceCreationScanner.scan(fixtureRoot, FirebaseInstanceCreationScanner.ALLOWED_PATH)

        assertEquals(listOf(2, 3), hits.map { it.line }, "検出した行: $hits")
    }

    @Test
    fun `許可した場所の中のgetInstanceは検出しない`() {
        fixture(
            FirebaseInstanceCreationScanner.ALLOWED_PATH,
            "val db = FirebaseFirestore.getInstance()\nval storage = FirebaseStorage.getInstance()\n",
        )

        val hits = FirebaseInstanceCreationScanner.scan(fixtureRoot, FirebaseInstanceCreationScanner.ALLOWED_PATH)

        assertEquals(emptyList(), hits)
    }

    @Test
    fun `同じファイル名でも許可した場所でなければ検出する`() {
        // ファイル名ではなく、ソースの根からの相対パスで許可する
        fixture("com/example/AppContainer.kt", "val db = FirebaseFirestore.getInstance()\n")

        val hits = FirebaseInstanceCreationScanner.scan(fixtureRoot, FirebaseInstanceCreationScanner.ALLOWED_PATH)

        assertEquals(listOf("com/example/AppContainer.kt"), hits.map { it.path })
    }

    @Test
    fun `インスタンスを得ない参照は検出しない`() {
        // 型としての参照・インスタンスのメソッドの呼び出しは対象外（得たものを受け取って使う側は、どこにあってもよい）
        fixture(
            "com/example/data/Reader.kt",
            """
            package com.example.data
            import com.google.firebase.firestore.FirebaseFirestore
            import com.google.firebase.firestore.FirebaseFirestoreSettings
            class Reader(private val db: () -> FirebaseFirestore) {
                fun posts() = db().collection("posts")
                val firestoreSettings: FirebaseFirestoreSettings? = null
            }
            """.trimIndent(),
        )

        val hits = FirebaseInstanceCreationScanner.scan(fixtureRoot, FirebaseInstanceCreationScanner.ALLOWED_PATH)

        assertEquals(emptyList(), hits)
    }
}
