// ⭐️ コンパイル済みのクラスから、Firestore・Storage の書き込み API への参照を探す走査器（タスク 6.5 のテスト用）
package com.yoshidometoru.soramoyou.data.remote.write

import java.io.DataInputStream
import java.io.File
import java.io.InputStream
import java.util.zip.ZipFile

/**
 * [WriteApiConfinementTest] で使う走査器。クラスの置き場（ディレクトリか jar）の `.class` を全て読み、定数プール（クラスが使う
 * メソッド・型・文字列の名簿）から、
 * 書き込み API への参照を探す。
 *
 * ソースの文字列でなくクラスを見るのは、自前の書き込みの入口のメソッド名（`delete`・`update`）が SDK と同じで、文字列では
 * 区別できないため（ここでは持ち主のクラスで区別する）。別名の import や、インライン展開された呼び出しにも効く。
 * 反射による呼び出しは検出できない。
 *
 * この走査器とテストは、探す型の名前を文字列の定数として持つ。どちらも write パッケージに置く（許可された側）。
 */
internal object WriteApiReferenceScanner {

    /** 書き込み API を参照してよい唯一のパッケージ（クラスの内部名の前半。下のパッケージも含む）。 */
    const val ALLOWED_PACKAGE = "com/yoshidometoru/soramoyou/data/remote/write/"

    /** 見つけた 1 か所。[className] はクラスの内部名、[reference] は「持ち主のクラス.メソッド名」か「type 型の内部名」。 */
    data class Hit(val className: String, val reference: String)

    /** 書き込みのメソッド（持ち主のクラスの内部名 → メソッド名。設計書 :276）。オーバーロードは名前でまとめる。 */
    private val WRITE_METHODS: Map<String, Set<String>> = mapOf(
        "com/google/firebase/firestore/DocumentReference" to setOf("set", "update", "delete"),
        "com/google/firebase/firestore/CollectionReference" to setOf("add"),
        "com/google/firebase/firestore/FirebaseFirestore" to setOf("runTransaction", "batch", "runBatch"),
        "com/google/firebase/storage/StorageReference" to setOf("putBytes", "putFile", "putStream", "delete", "updateMetadata"),
    )

    /** 書き込み専用の型（設計書 :276）。入れ子の型（`StorageMetadata.Builder`・`Transaction.Function` など）への参照も数える。 */
    private val WRITE_TYPES: List<String> = listOf(
        "com/google/firebase/firestore/FieldValue",
        "com/google/firebase/firestore/SetOptions",
        "com/google/firebase/firestore/WriteBatch",
        "com/google/firebase/firestore/Transaction",
        "com/google/firebase/storage/StorageMetadata",
    )

    /**
     * 型の参照の形：定数プールの文字列のうち、型の名前そのもの（クラスの参照）か、記述子の中の `L名前;`、入れ子の `名前$…`。
     * `TransactionOptions` のように、名前の続きが別の文字なら当たらない。
     */
    private val TYPE_PATTERNS: Map<String, Regex> = WRITE_TYPES.associateWith { Regex("(^|L)" + Regex.escape(it) + "(;|\\$|$)") }

    /**
     * [root]（クラスの置き場。ディレクトリか jar）の中のクラスを全て走査し、[allowedPackage]（null なら許可なし）の外のクラスでの
     * 参照を返す。並びはクラス名・参照の順。
     */
    fun scan(root: File, allowedPackage: String?): List<Hit> =
        withClasses(root) { classes ->
            classes
                .filter { (className, _) -> allowedPackage == null || !className.startsWith(allowedPackage) }
                .flatMap { (className, open) ->
                    val pool = open().use { ClassConstantPool.read(it, source = "$root の $className") }
                    referencesIn(pool).map { Hit(className, it) }
                }
                .toList()
        }.sortedWith(compareBy({ it.className }, { it.reference }))

    /** [root] の中の全てのクラスの内部名（走査が実物を読んでいることを確かめるため）。 */
    fun classNames(root: File): List<String> = withClasses(root) { classes -> classes.map { it.first }.toList() }

    /**
     * [root] の中のクラスを（内部名, 中身を開く関数）の列にして [action] に渡す。
     * 単体テストでは、main のクラスは jar で（AGP 9 の bundleDebugClassesToRuntimeJar）、test のクラスはディレクトリで渡ってくる。
     * jar は [action] の間だけ開いておく。
     */
    private fun <T> withClasses(root: File, action: (Sequence<Pair<String, () -> InputStream>>) -> T): T =
        if (root.isDirectory) {
            action(
                root.walkTopDown()
                    .filter { it.isFile && it.extension == "class" }
                    .map { file -> file.relativeTo(root).invariantSeparatorsPath.removeSuffix(".class") to { file.inputStream() } },
            )
        } else {
            ZipFile(root).use { jar ->
                action(
                    jar.entries().asSequence()
                        .filter { !it.isDirectory && it.name.endsWith(".class") }
                        .map { entry -> entry.name.removeSuffix(".class") to { jar.getInputStream(entry) } },
                )
            }
        }

    /** 1 つのクラスの定数プールから、書き込みのメソッドと書き込み専用の型への参照を返す。 */
    fun referencesIn(pool: ClassConstantPool): List<String> {
        val methods = pool.methodRefs
            .filter { (owner, name) -> name in WRITE_METHODS[owner].orEmpty() }
            .map { (owner, name) -> "$owner.$name" }
        val types = TYPE_PATTERNS
            .filter { (_, pattern) -> pool.strings.any { pattern.containsMatchIn(it) } }
            .map { (type, _) -> "type $type" }
        return (methods + types).distinct()
    }
}

/**
 * クラスファイルの定数プールのうち、走査に使う 2 つだけを読んだもの（JVM 仕様 4.4）。
 *
 * @property methodRefs メソッドの参照（持ち主のクラスの内部名, メソッド名）。インターフェースのメソッドも含む
 * @property strings Utf8 の定数の全て（クラス名・記述子・文字列リテラルなど）
 */
internal class ClassConstantPool(val methodRefs: List<Pair<String, String>>, val strings: List<String>) {

    companion object {
        private const val MAGIC = 0xCAFEBABE.toInt()

        /** クラスファイル [file] の定数プールを読む。 */
        fun read(file: File): ClassConstantPool = file.inputStream().use { read(it, source = file.path) }

        /**
         * クラスファイルの中身 [stream] の定数プールを読む（[source] は失敗の説明に出す、どこのクラスか）。
         * 知らない種類の定数があれば、読み飛ばさずに止める（読み違えたまま緑にしない）。
         */
        fun read(stream: InputStream, source: String): ClassConstantPool = DataInputStream(stream.buffered()).use { input ->
            check(input.readInt() == MAGIC) { "クラスファイルでない: $source" }
            input.skipFully(4) // minor_version・major_version
            val count = input.readUnsignedShort()
            val utf8 = arrayOfNulls<String>(count)
            val classNameIndex = IntArray(count)
            val nameAndTypeNameIndex = IntArray(count)
            // （クラスの番号, 名前と型の番号）。後ろの番号を指すこともあるので、全て読んでから名前に直す
            val methodRefIndexes = mutableListOf<Pair<Int, Int>>()
            var index = 1
            while (index < count) {
                when (val tag = input.readUnsignedByte()) {
                    1 -> utf8[index] = input.readUTF() // Utf8（修正 UTF-8。readUTF が読む形と同じ）
                    7 -> classNameIndex[index] = input.readUnsignedShort() // Class
                    10, 11 -> methodRefIndexes += input.readUnsignedShort() to input.readUnsignedShort() // Methodref・InterfaceMethodref
                    12 -> { // NameAndType
                        nameAndTypeNameIndex[index] = input.readUnsignedShort()
                        input.skipFully(2)
                    }
                    3, 4 -> input.skipFully(4) // Integer・Float
                    5, 6 -> { // Long・Double は 2 枠を使う
                        input.skipFully(8)
                        index++
                    }
                    8, 16, 19, 20 -> input.skipFully(2) // String・MethodType・Module・Package
                    9, 17, 18 -> input.skipFully(4) // Fieldref・Dynamic・InvokeDynamic
                    15 -> input.skipFully(3) // MethodHandle
                    else -> error("知らない定数の種類 $tag（$source の $index 番目）")
                }
                index++
            }
            ClassConstantPool(
                methodRefs = methodRefIndexes.map { (classIndex, nameAndTypeIndex) ->
                    checkNotNull(utf8[classNameIndex[classIndex]]) to checkNotNull(utf8[nameAndTypeNameIndex[nameAndTypeIndex]])
                },
                strings = utf8.filterNotNull(),
            )
        }

        private fun DataInputStream.skipFully(bytes: Int) = readFully(ByteArray(bytes))
    }
}
