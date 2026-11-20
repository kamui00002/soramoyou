// ⭐️ 端末の中の置き場：編集の途中・下書き・装備のファイルの場所を決め、読み書きを 1 か所に集める（Kiro android-edit-tools タスク 14.1・A4・design.md:917-928, 1011-1025）
package com.yoshidometoru.soramoyou.data.edit

import android.content.Context
import com.yoshidometoru.soramoyou.contract.Uid
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.util.Properties
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/*
 * 置き場の形（design.md:1013-1025）。根は noBackupFilesDir/edit/：
 *
 *   loadout.properties                      装備（端末で共通。利用者のフォルダの外）
 *   users/{利用者のフォルダ}/
 *     session/work.properties, photo-0, …   編集の途中と、選んだ写真の写し（バイトのまま）
 *     drafts/{draftId}/draft.properties, photo-0, …, thumb.jpg
 *     drafts/{draftId}.tmp/, {draftId}.old/ 保存の途中だけある一時のフォルダ
 *
 * - アプリの中の領域で、ほかのアプリからは見えない。ほかのアプリへファイルを渡す仕組み（コンテンツの提供者）で外へ出さない（8.15）
 * - noBackupFilesDir はバックアップ・機種変更で引き継がれない（7.8・8.15）。本番の根は [EditFileStore.forApp] の 1 か所で決める
 * - サーバーの読み書きの入口は持たない（端末の中だけ：7.3・8.3）
 */

/** 文書が読めない（版が新しすぎる・必須の鍵が無いなど）。記録の名前（`AppError.Unknown` の値）に使う。場所・本文は持たない */
internal class BrokenEditDocumentException : IOException()

/** 文書が指す写真のファイルが無い */
internal class MissingEditPhotoException : IOException()

/** 上書きしようとした下書きのフォルダが無い */
internal class MissingEditDraftException : IOException()

/** 利用者のフォルダの外を指す・安全でない場所や名前 */
internal class UnsafeEditPathException : IOException()

/**
 * ファイルへ書く操作（書く・名前を変える・消す・フォルダを作る）。テストが「どの操作で失敗させるか」を差し替えるための口。
 * [EditFileStore] の外のクラスは、この口を直接呼ばず、[EditFileStore] の関数を通す（失敗を起こせる場所を 1 つにするため）。
 */
internal interface EditFileOps {
    /** [target] を作り直し（あれば中身を捨てる）、[source] を全部書いて、端末の記憶へ書き出す（fsync）。失敗すれば例外 */
    fun write(target: File, source: InputStream)

    /** [from] の名前を [to] に変える。ファイルなら [to] を置き換える（1 回の rename で、途中の形は残らない）。失敗すれば例外 */
    fun rename(from: File, to: File)

    /** [target] を中身ごと消す。もともと無ければ何もしない。消せずに残れば例外 */
    fun delete(target: File)

    /** [dir] とその親のフォルダを作る。既にあれば何もしない。作れなければ例外 */
    fun mkdirs(dir: File)

    /** 本物の操作 */
    object Real : EditFileOps {
        override fun write(target: File, source: InputStream) {
            FileOutputStream(target).use { out ->
                source.copyTo(out)
                out.flush()
                // 名前を変える前に中身を記憶へ書き出す（電源が落ちても、名前だけ新しくて中身が空、を作らない）
                out.fd.sync()
            }
        }

        override fun rename(from: File, to: File) {
            if (!from.renameTo(to)) throw IOException()
        }

        override fun delete(target: File) {
            target.deleteRecursively()
            if (target.exists()) throw IOException()
        }

        override fun mkdirs(dir: File) {
            if (dir.isDirectory) return
            dir.mkdirs()
            if (!dir.isDirectory) throw IOException()
        }
    }
}

/**
 * 端末の中のファイルの場所を決め、読み書きを 1 か所に集める（design.md:917-928）。
 *
 * - 利用者のフォルダは uid ごとに分かれる（12.4・8.11）。名前の決め方は [userFolderName]
 * - 文書の書き込みは、一時のファイル（`名前.part`）に書いてから名前を変える（途中で落ちても前の文書が残る）
 * - 読み書きは [locked] の中で行う：IO のスレッドで、端末の保存の操作を 1 本ずつ通す（写しと後始末と下書きの片付けが同じフォルダを同時に触らない）。
 *   [locked] の中では、ほかのストアの suspend 関数を呼ばない（同じ鍵を二重に取って止まるため）
 * - 失敗は例外で返す。例外を `AppError.Unknown(例外のクラス名)` にするのは呼ぶ側（場所・本文を入れない：14.5）
 *
 * 本番は [forApp] で作る。アプリの中で 1 つだけ作り、全てのストアに同じものを渡す（鍵を共有するため）。
 *
 * @param baseDir 根の親（本番は `noBackupFilesDir`。テストは一時のフォルダ）。根は `baseDir/edit/`
 * @param dispatcher 読み書きのスレッド（既定は IO）
 * @param ops 書く操作（テストが失敗を起こすときだけ差し替える）
 */
class EditFileStore internal constructor(
    baseDir: File,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    internal val ops: EditFileOps = EditFileOps.Real,
) {
    /** 根（`baseDir/edit/`） */
    internal val root: File = File(baseDir, ROOT_DIR)

    /** 装備の文書（利用者のフォルダの外・端末で共通：7.9） */
    internal val loadoutFile: File get() = File(root, LOADOUT_FILE)

    private val mutex = Mutex()

    /** [block] を、端末の保存の鍵を取ったうえで IO のスレッドで行う */
    internal suspend fun <T> locked(block: () -> T): T = mutex.withLock { withContext(dispatcher) { block() } }

    // ── 場所 ──

    /** 利用者のフォルダ（`users/{名前}`）。名前は [userFolderName] */
    internal fun userDir(uid: Uid): File = File(File(root, USERS_DIR), userFolderName(uid))

    internal fun sessionDir(uid: Uid): File = File(userDir(uid), SESSION_DIR)

    internal fun sessionDocument(uid: Uid): File = File(sessionDir(uid), WORK_FILE)

    internal fun draftsDir(uid: Uid): File = File(userDir(uid), DRAFTS_DIR)

    /**
     * 利用者のフォルダからの相対の場所 [relative] を、そのファイルにする。
     * 空・絶対の場所・`..` や `.` や空の区切り・`\`・`:`・NUL を含む場所は、利用者のフォルダの外を指しうるので [UnsafeEditPathException]
     */
    internal fun resolve(uid: Uid, relative: String): File {
        if (!isSafeRelativePath(relative)) throw UnsafeEditPathException()
        return File(userDir(uid), relative)
    }

    /** [relative] が指す写真のファイル。場所が安全でなければ [UnsafeEditPathException]、ファイルが無ければ [MissingEditPhotoException] */
    internal fun requirePhoto(uid: Uid, relative: String): File {
        val file = resolve(uid, relative)
        if (!file.isFile) throw MissingEditPhotoException()
        return file
    }

    // ── 読む ──

    /** 文書を読む。ファイルが無ければ null。あるのに読めなければ例外（壊れた `\u` の書き方は IllegalArgumentException） */
    internal fun readDocument(file: File): Map<String, String>? {
        if (!file.exists()) return null
        val properties = Properties()
        InputStreamReader(FileInputStream(file), Charsets.UTF_8).use { properties.load(it) }
        return properties.stringPropertyNames().associateWith { properties.getProperty(it) }
    }

    // ── 書く（どれも [ops] を通す） ──

    /** 文書を、一時のファイルに書いてから名前を変えて置く（途中で落ちても前の文書が残る） */
    internal fun writeDocument(file: File, values: Map<String, String>) {
        val properties = Properties()
        values.forEach { (key, value) -> properties.setProperty(key, value) }
        val bytes = ByteArrayOutputStream().also { out ->
            OutputStreamWriter(out, Charsets.UTF_8).use { properties.store(it, null) }
        }.toByteArray()
        writeBytes(file, bytes)
    }

    /** [bytes] を、一時のファイルに書いてから名前を変えて置く（見本の JPEG などにも使う） */
    internal fun writeBytes(file: File, bytes: ByteArray) {
        val dir = file.parentFile ?: throw UnsafeEditPathException()
        ops.mkdirs(dir)
        val part = File(dir, file.name + PART_SUFFIX)
        try {
            ops.write(part, ByteArrayInputStream(bytes))
            ops.rename(part, file)
        } catch (e: Exception) {
            // 書きかけの一時のファイルを残さない（前の文書は名前を変える前なのでそのまま）
            part.delete()
            throw e
        }
    }

    /** [source] を [target] へ全部書く。途中で失敗したら書きかけの [target] を消して例外を投げ直す */
    internal fun writeStream(target: File, source: InputStream) {
        try {
            ops.write(target, source)
        } catch (e: Exception) {
            target.delete()
            throw e
        }
    }

    /** [source] のファイルを [target] へ写す（[source] は残す） */
    internal fun copyFile(source: File, target: File) {
        FileInputStream(source).use { writeStream(target, it) }
    }

    /** 名前を変える（移す） */
    internal fun renameFile(from: File, to: File) = ops.rename(from, to)

    /** 中身ごと消す。無ければ何もしない。残れば例外 */
    internal fun deleteTree(target: File) = ops.delete(target)

    /**
     * [dir] が在って中身が 1 つも無いフォルダのときだけ消す。中身が残っている・無い・フォルダでない・中身を読めないときは何もしない
     * （消してよいのは空のフォルダだけ。残った中身を巻き込まない）。消せずに残れば例外
     */
    internal fun deleteDirIfEmpty(dir: File) {
        if (dir.isDirectory && dir.list()?.isEmpty() == true) ops.delete(dir)
    }

    /** フォルダを作る */
    internal fun ensureDir(dir: File) = ops.mkdirs(dir)

    /** [file] の `file:` の URI（`file:///…` の形。区切り以外は百分率の符号にする）。画面の Coil と ContentResolver がこの形で読む */
    internal fun fileUri(file: File): String = "file://" + file.absoluteFile.toURI().rawPath

    companion object {
        /**
         * 本番の置き場。根は `context.noBackupFilesDir/edit/`（バックアップ・機種変更で引き継がない：7.8・8.15）。
         * 本番の根を決めるのはこの 1 行だけ（端末のテスト EditFilesDeviceTest が、写しがこの下にあることを見る）
         */
        fun forApp(context: Context): EditFileStore = EditFileStore(context.noBackupFilesDir)

        internal const val ROOT_DIR = "edit"
        internal const val USERS_DIR = "users"
        internal const val SESSION_DIR = "session"
        internal const val DRAFTS_DIR = "drafts"
        internal const val WORK_FILE = "work.properties"
        internal const val DRAFT_FILE = "draft.properties"
        internal const val THUMB_FILE = "thumb.jpg"
        internal const val LOADOUT_FILE = "loadout.properties"
        internal const val PHOTO_PREFIX = "photo-"

        /** 下書きの保存の途中だけある一時のフォルダ（`{draftId}.tmp`）と、上書きの入れ替えの途中だけある古いフォルダ（`{draftId}.old`） */
        internal const val TMP_SUFFIX = ".tmp"
        internal const val OLD_SUFFIX = ".old"

        /** 文書・見本を書くときの一時のファイル（`名前.part`） */
        internal const val PART_SUFFIX = ".part"

        /** uid をそのまま名前にする長さの上限 */
        private const val MAX_PLAIN_UID_LENGTH = 128

        /** 16 進にした名前の頭に付ける目印。英数字でないので、英数字の uid がそのまま使う名前と重ならない */
        private const val HEX_MARK = "_"

        /** 下書きの ID の長さの上限（大文字の UUID は 36 文字） */
        private const val MAX_DRAFT_ID_LENGTH = 64

        /**
         * 利用者のフォルダの名前。uid が英数字（1〜128 文字）ならそのまま。そうでなければ、UTF-8 の 16 進（小文字）の頭に `_` を付ける
         * （場所の区切りや `..` を名前に混ぜない。`_` の目印で、英数字の uid が別の uid の 16 進と同じ名前にならない）。
         * 空の uid は IllegalArgumentException
         */
        internal fun userFolderName(uid: Uid): String {
            val value = uid.value
            require(value.isNotEmpty())
            if (value.length <= MAX_PLAIN_UID_LENGTH && value.all { it.isAsciiLetterOrDigit() }) return value
            return HEX_MARK + value.toByteArray(Charsets.UTF_8).joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
        }

        /** 下書きの ID として、場所の 1 区切りに使えるか（英数字と `-` だけ・1〜64 文字。`.` を含まないので `.tmp`・`.old` と見分けられる） */
        internal fun isSafeDraftId(value: String): Boolean =
            value.length in 1..MAX_DRAFT_ID_LENGTH && value.all { it.isAsciiLetterOrDigit() || it == '-' }

        /** 写しの写真の相対の場所（`session/photo-N`） */
        internal fun sessionPhotoPath(index: Int): String = "$SESSION_DIR/$PHOTO_PREFIX$index"

        /** 下書きの写真の相対の場所（`drafts/{id}/photo-N`） */
        internal fun draftPhotoPath(draftId: String, index: Int): String = "$DRAFTS_DIR/$draftId/$PHOTO_PREFIX$index"

        /** 相対の場所として安全か（[resolve] の検査） */
        internal fun isSafeRelativePath(path: String): Boolean {
            if (path.isEmpty()) return false
            if (path.contains('\\') || path.contains(':') || path.contains('\u0000')) return false
            return path.split('/').none { it.isEmpty() || it == "." || it == ".." }
        }

        private fun Char.isAsciiLetterOrDigit(): Boolean = this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9'
    }
}
