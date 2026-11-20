// ⭐️ Firestore・Storage の書き込み API を write パッケージの外で使っていないことの検査（タスク 6.5・要件 2.2・2.10）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.BuildConfig
import com.yoshidometoru.soramoyou.data.remote.read.WriteApiViolationFixture
import com.yoshidometoru.soramoyou.data.remote.read.WriteTypeOnlyFixture
import com.yoshidometoru.soramoyou.feature.WriteApiLookalikeFixture
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 書き込み API を呼べるのは data.remote.write パッケージだけ、を強制するアーキテクチャテスト（設計書「M1の書き込みゼロ保証」2・5）。
 * コンパイル済みのクラスを [WriteApiReferenceScanner] で走査する（ソースの文字列でない理由は走査器の説明）。
 *
 * 走査するのは、単体テストの実行時のクラスパスにある main のクラスの置き場（Kotlin のクラスと、BuildConfig を含む Java のクラス）。
 * 置き場はクラスの codeSource から得て、ビルドの出力先のパスを直書きしない（今の AGP では、main は 1 つの jar にまとまって渡ってくる）。
 * フィクスチャは test のソースに置き（実行はしない）、test のクラスの置き場を走査して確かめる。
 */
class WriteApiConfinementTest {

    /** main のクラスの置き場（同じ場所なら 1 つ）。 */
    private val mainRoots: List<File> = listOf(rootOf(WriteGate::class.java), rootOf(BuildConfig::class.java)).distinct()

    /** test のクラスの置き場（フィクスチャがある）。 */
    private val testRoot: File = rootOf(WriteApiConfinementTest::class.java)

    /** test のクラスの置き場を走査し、[fixture] とその入れ子のクラス（ラムダ・継続など）の参照だけを返す。 */
    private fun fixtureHits(fixture: Class<*>, allowedPackage: String?): List<WriteApiReferenceScanner.Hit> =
        WriteApiReferenceScanner.scan(testRoot, allowedPackage).filter { it.className.startsWith(internalName(fixture)) }

    @Test
    fun `writeパッケージの外のmainのクラスは、書き込みAPIと書き込み専用の型を参照していない`() {
        // 走査の対象を取り違えると空振りで通るので、main の実物を読んでいることを先に確かめる
        // （main のクラスは jar で渡ってくる。ディレクトリだけを読む走査器では、何も読まずに緑になっていた）
        assertTrue(testRoot !in mainRoots, "main と test のクラスの置き場が同じ: $testRoot")
        val mainClasses = mainRoots.flatMap { WriteApiReferenceScanner.classNames(it) }
        assertTrue(
            listOf("com/yoshidometoru/soramoyou/di/AppContainer", "com/yoshidometoru/soramoyou/BuildConfig").all { it in mainClasses },
            "AppContainer・BuildConfig のクラスを読めていない（${mainClasses.size} 件）: $mainRoots",
        )

        val hits = mainRoots.flatMap { WriteApiReferenceScanner.scan(it, WriteApiReferenceScanner.ALLOWED_PACKAGE) }

        assertEquals(emptyList(), hits, "write パッケージの外で書き込み API を参照している")
    }

    @Test
    fun `本物のwriteパッケージのSDKの実装は、書き込みAPIを参照している（上の検査が空振りしていない）`() {
        val hits = mainRoots.flatMap { WriteApiReferenceScanner.scan(it, allowedPackage = null) }
        // suspend 関数の継続やラムダは別のクラスになることがあるので、クラス名の前方一致で集める
        // （許可の範囲 ALLOWED_PACKAGE には頼らない。許可の範囲を誤っても、ここは本物のアダプタを見続ける）
        fun referencesOf(classPrefix: String): Set<String> =
            hits.filter { it.className.startsWith(classPrefix) }.map { it.reference }.toSet()

        val firestore = referencesOf(internalName(FirebaseFirestoreWriteClient::class.java))
        val storage = referencesOf(internalName(FirebaseStorageWriteClient::class.java))
        // トップレベルの関数のクラス（SdkValuesKt）は、クラスリテラルで書けないので名前で
        val sdkValues = referencesOf("com/yoshidometoru/soramoyou/data/remote/write/SdkValues")

        assertTrue(
            firestore.containsAll(
                listOf(
                    "com/google/firebase/firestore/DocumentReference.set",
                    "com/google/firebase/firestore/DocumentReference.update",
                    "com/google/firebase/firestore/DocumentReference.delete",
                    "com/google/firebase/firestore/FirebaseFirestore.batch",
                    "com/google/firebase/firestore/FirebaseFirestore.runTransaction",
                    "type com/google/firebase/firestore/WriteBatch",
                    "type com/google/firebase/firestore/Transaction",
                ),
            ),
            "FirebaseFirestoreWriteClient で見つけた参照: $firestore",
        )
        assertTrue(
            storage.containsAll(
                listOf(
                    "com/google/firebase/storage/StorageReference.putBytes",
                    "com/google/firebase/storage/StorageReference.delete",
                    "type com/google/firebase/storage/StorageMetadata",
                ),
            ),
            "FirebaseStorageWriteClient で見つけた参照: $storage",
        )
        assertTrue("type com/google/firebase/firestore/FieldValue" in sdkValues, "SdkValues で見つけた参照: $sdkValues")
    }

    @Test
    fun `陽性対照：readパッケージのフィクスチャの、全ての書き込みAPIと書き込み専用の型を検出する`() {
        val found = fixtureHits(WriteApiViolationFixture::class.java, WriteApiReferenceScanner.ALLOWED_PACKAGE).map { it.reference }.toSet()

        // 設計書 :276 の一覧（2026-10-04 に add・runBatch・updateMetadata を足した）。走査器の一覧から消すと、ここで分かる
        assertEquals(
            setOf(
                "com/google/firebase/firestore/DocumentReference.set",
                "com/google/firebase/firestore/DocumentReference.update",
                "com/google/firebase/firestore/DocumentReference.delete",
                "com/google/firebase/firestore/CollectionReference.add",
                "com/google/firebase/firestore/FirebaseFirestore.runTransaction",
                "com/google/firebase/firestore/FirebaseFirestore.batch",
                "com/google/firebase/firestore/FirebaseFirestore.runBatch",
                "com/google/firebase/storage/StorageReference.putBytes",
                "com/google/firebase/storage/StorageReference.putFile",
                "com/google/firebase/storage/StorageReference.putStream",
                "com/google/firebase/storage/StorageReference.delete",
                "com/google/firebase/storage/StorageReference.updateMetadata",
                "type com/google/firebase/firestore/FieldValue",
                "type com/google/firebase/firestore/SetOptions",
                "type com/google/firebase/firestore/WriteBatch",
                "type com/google/firebase/firestore/Transaction",
                "type com/google/firebase/storage/StorageMetadata",
            ),
            found,
        )
    }

    @Test
    fun `陽性対照：引数の型に書くだけの書き込み専用の型も検出する（メソッドの記述子の中の参照）`() {
        assertEquals(
            listOf(WriteApiReferenceScanner.Hit(internalName(WriteTypeOnlyFixture::class.java), "type com/google/firebase/firestore/Transaction")),
            fixtureHits(WriteTypeOnlyFixture::class.java, WriteApiReferenceScanner.ALLOWED_PACKAGE),
        )
    }

    @Test
    fun `writeパッケージの中のクラスは、書き込みAPIを参照していても検出しない`() {
        // フィクスチャが実際に参照していることを、許可なしの走査で先に確かめる
        assertEquals(
            listOf("com/google/firebase/firestore/DocumentReference.set"),
            fixtureHits(WriteApiAllowedFixture::class.java, allowedPackage = null).map { it.reference },
        )

        assertEquals(emptyList(), fixtureHits(WriteApiAllowedFixture::class.java, WriteApiReferenceScanner.ALLOWED_PACKAGE))
    }

    @Test
    fun `持ち主がSDKでなければ、書き込みと同じ名前のメソッドでも検出しない（入口・List・File・AtomicReference）`() {
        val fixture = File(testRoot, internalName(WriteApiLookalikeFixture::class.java) + ".class")
        // 同じ名前のメソッドへの参照が、定数プールに実際に入っていることを先に確かめる（入口の delete は、引数の value class のため
        // JVM の上では `delete-…` という名前になる）
        val methodRefs = ClassConstantPool.read(fixture).methodRefs
        assertTrue(
            methodRefs.containsAll(
                listOf("java/util/List" to "add", "java/io/File" to "delete", "java/util/concurrent/atomic/AtomicReference" to "set"),
            ),
            "フィクスチャのメソッドの参照: $methodRefs",
        )
        assertTrue(
            methodRefs.any { (owner, name) -> owner == internalName(StorageGateway::class.java) && name.startsWith("delete") },
            "フィクスチャが入口の delete を呼んでいない: $methodRefs",
        )

        assertEquals(emptyList(), fixtureHits(WriteApiLookalikeFixture::class.java, allowedPackage = null))
    }

    private companion object {
        /** [type] のクラスファイルがある、クラスの置き場（ディレクトリか jar）。 */
        fun rootOf(type: Class<*>): File =
            File(checkNotNull(type.protectionDomain?.codeSource) { "${type.name} の置き場が分からない" }.location.toURI())

        /** クラスの内部名（`com/…/Name`）。 */
        fun internalName(type: Class<*>): String = type.name.replace('.', '/')
    }
}
