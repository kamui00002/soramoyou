// ⭐️ 退会の手順の単体テストで共有する偽物：サーバーの代わりの小さな記憶域と、それを読み書きする継ぎ目（タスク 31.2・トランザクションは 31.3）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.contract.document.FsValue
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.CountSpec
import com.yoshidometoru.soramoyou.data.remote.read.DrainTarget
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.OwnedCollection
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.RawPage
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteFailure
import com.yoshidometoru.soramoyou.data.remote.write.StorageWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.StorageWriteFailure
import com.yoshidometoru.soramoyou.data.remote.write.TxClient
import com.yoshidometoru.soramoyou.platform.SessionManager
import com.yoshidometoru.soramoyou.platform.SessionScopedState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * 退会のテスト用の、サーバーの代わりの記憶域。Firestore の文書（パス → 中身）と Storage のオブジェクト（パス）を持ち、
 * 読み取り口（[reader]）・Firestore の継ぎ目（[firestore]）・Storage の継ぎ目（[storage]）の偽物が同じものを読み書きする。
 * 書き込みの入口は本物（可否 → 実行 → 記録）を、この継ぎ目の上に組む（[DefaultPostDeleterTest] と同じ考え方）。
 *
 * どの偽物も、呼ばれたことを [events] に「そのときの退会の段階（[stageNow]）」と一緒に残す。
 * Firestore・Storage・認証をまたいだ順序と、「段階が仕事より先に立っている」ことを、1 つの記録で確かめるため
 * （StateFlow を集めて確かめると、値の間引きで取りこぼしうる）。
 */
internal class DeletionBackend {

    /** 呼ばれたこと [what] と、そのときの退会の段階 [stage]。 */
    data class Event(val stage: DeletionStage?, val what: String)

    /** 記録に添える「いまの段階」。手順の本体を作った後で、その `stage.value` を読むように差し替える。 */
    var stageNow: () -> DeletionStage? = { null }

    val events = mutableListOf<Event>()

    fun record(what: String) {
        events += Event(stageNow(), what)
    }

    /** Firestore の文書。キーはパス（例 `follows/A_B`・`users/U/favorites/P`）。並びは入れた順（取得もこの順で返す）。 */
    val documents = LinkedHashMap<String, Map<String, Any?>>()

    /** Storage のオブジェクトのパス。 */
    val objects = LinkedHashSet<String>()

    /** true のあいだ、削除を記録するだけで記憶域から消さない（削除が黙って効かない状態の再現。200 ページの打ち切りのテスト）。 */
    var frozen = false

    /** 取得の形と取得元（呼ばれた順）。 */
    val queries = mutableListOf<Pair<QuerySpec, ReadSource>>()

    /** Firestore の一括削除の 1 回ごとのパス（書き込みの入口が 500 件ずつに分けたかを見る）。 */
    val batches = mutableListOf<List<String>>()

    /** 取得の失敗を差し込む（null なら成功）。 */
    var queryFailure: (QuerySpec) -> AppError? = { null }

    /**
     * Firestore の書き込みの失敗を差し込む（操作名 `delete`・`deleteAll`・`commit`〔トランザクションの書き込み。タスク 31.3〕と、
     * 対象のパスで決める。null なら成功）。
     */
    var writeFailure: (String, List<String>) -> AppError? = { _, _ -> null }

    /**
     * トランザクションの中の読み取り（`tx.get`）の失敗を差し込む（対象のパスで決める。null なら成功。タスク 31.3）。
     * rules が投稿の読み取りを拒むこと（他人の非公開の投稿・消えた投稿）の再現に使う。
     */
    var txReadFailure: (String) -> AppError? = { null }

    /** Storage の削除の失敗を差し込む（null なら成功）。 */
    var storageFailure: (String) -> AppError? = { null }

    /** Storage の削除を、記録した後でこの値が完了するまで返さない（返事の無い要求の再現）。null なら待たない。 */
    var storageHang: (String) -> CompletableDeferred<Unit>? = { null }

    /** Storage の一覧の失敗を差し込む（一覧するフォルダで決める。null なら成功。タスク 31.6）。 */
    var listFailure: (String) -> AppError? = { null }

    /** Storage の一覧を、記録した後でこの値が完了するまで返さない（返事の無い要求の再現。タスク 31.6）。null なら待たない。 */
    var listHang: (String) -> CompletableDeferred<Unit>? = { null }

    /** [collection]（`follows` や `users/U/favorites`）の文書を、入れた順に（ID と中身の組で）返す。 */
    private fun inCollection(collection: String): List<RawDocument> =
        documents.entries
            .filter { it.key.substringBeforeLast('/') == collection }
            .map { RawDocument(it.key.substringAfterLast('/'), it.value) }

    /** 退会の手順が使う形だけを、サーバーと同じ条件で答える読み取り口の偽物。 */
    val reader: FirestoreReader = object : FirestoreReader {
        override suspend fun get(ref: DocRef, source: ReadSource): AppResult<RawDocument?> = error("退会の手順は単一の取得を使わない")

        override suspend fun query(spec: QuerySpec, source: ReadSource): AppResult<RawPage> {
            record("read ${describe(spec)}")
            queries += spec to source
            queryFailure(spec)?.let { return AppResult.Err(it) }
            val matched = when (spec) {
                is QuerySpec.DrainByField -> {
                    val (collection, field) = when (spec.target) {
                        DrainTarget.FOLLOWS_AS_FOLLOWER -> "follows" to "followerId"
                        DrainTarget.FOLLOWS_AS_FOLLOWEE -> "follows" to "followeeId"
                        DrainTarget.LIKES -> "likes" to "userId"
                        DrainTarget.COMMENTS -> "comments" to "userId"
                    }
                    inCollection(collection).filter { it.data[field] == spec.uid.value }.take(QuerySpec.DrainByField.PAGE_SIZE)
                }
                is QuerySpec.AllOwned -> when (spec.collection) {
                    OwnedCollection.POSTS -> inCollection("posts").filter { it.data["userId"] == spec.uid.value }
                    OwnedCollection.DRAFTS -> inCollection("drafts").filter { it.data["userId"] == spec.uid.value }
                    OwnedCollection.FAVORITES -> inCollection("users/${spec.uid.value}/favorites")
                }
                else -> error("退会の手順は使わない形: $spec")
            }
            return AppResult.Ok(RawPage(matched, cursor = null))
        }

        override suspend fun count(spec: CountSpec): AppResult<Long> = error("退会の手順は集計しない")

        override fun observe(ref: DocRef): Flow<AppResult<RawDocument?>> = error("退会の手順は監視しない")
    }

    /**
     * Firestore の継ぎ目の偽物。消したら記憶域からも消す（[frozen] のあいだは消さない）。
     * 退会の手順は文書を作らないが、退会の途中に他の画面の書き込み（補完など）を呼ぶテストのために、作る書き込み（set）も記憶域に書く
     * （書き込みの入口が断らなければ、文書が作り直されるのが見える）。
     */
    val firestore: FirestoreWriteClient = object : FirestoreWriteClient {
        override suspend fun set(path: String, data: FsDocument) {
            record("firestore.set $path")
            documents[path] = data
        }

        override suspend fun update(path: String, data: FsDocument): Unit = error("退会の手順は文書を書かない")

        override suspend fun delete(path: String): Unit = write("delete", listOf(path))

        override suspend fun deleteAll(paths: List<String>) {
            batches += paths
            write("deleteAll", paths)
        }

        /**
         * トランザクション（タスク 31.3 のいいね・コメントの削除が使う）。中の書き込みは溜めておき、[block] が値を返したら
         * [commit] で 1 回にまとめて適用する（全てか無しか）。[block] が例外で抜けたら何も書かない（取りやめ）。
         * SDK と違い、競合によるやり直しはしない（単体テストでは同時に書く相手がいない）。
         */
        override suspend fun <T> runTransaction(block: suspend TxClient.() -> T): T {
            val writes = mutableListOf<TxWrite>()
            val tx = object : TxClient {
                override suspend fun get(path: String): RawDocument? {
                    record("tx.get $path")
                    txReadFailure(path)?.let { throw FirestoreWriteFailure(it, RuntimeException("偽物の失敗")) }
                    return documents[path]?.let { RawDocument(path.substringAfterLast('/'), it) }
                }

                /** 退会の手順は作らない。退会の途中に補完（作る）を呼ぶテストのために受け付ける。 */
                override fun set(path: String, data: FsDocument) {
                    writes += TxWrite.Set(path, data)
                }

                override fun update(path: String, data: FsDocument) {
                    writes += TxWrite.Update(path, data)
                }

                override fun delete(path: String) {
                    writes += TxWrite.Delete(path)
                }
            }
            val result = tx.block()
            commit(writes)
            return result
        }
    }

    /** トランザクションの中の書き込み（コミットまで溜めておく）。 */
    private sealed interface TxWrite {
        val path: String

        data class Update(override val path: String, val data: FsDocument) : TxWrite

        data class Delete(override val path: String) : TxWrite

        data class Set(override val path: String, val data: FsDocument) : TxWrite
    }

    /**
     * トランザクションの書き込みを 1 回のコミットとして適用する。記録は `firestore.commit <書き込み>;<書き込み>`
     * （例 `firestore.commit update posts/P1 likesCount-1;delete likes/L1`。書いた順）。
     * 本物の Firestore と同じく、存在しない文書の更新は不在（NotFound）で、そのときは何も書かない（全てか無しか）。
     * 更新は加算（[FsValue.Increment]）だけを受け付け、整数のフィールドに足す（無ければ 0 から）。[frozen] のあいだは記録だけで適用しない。
     */
    private fun commit(writes: List<TxWrite>) {
        record("firestore.commit ${writes.joinToString(";") { describe(it) }}")
        writeFailure("commit", writes.map { it.path })?.let { throw FirestoreWriteFailure(it, RuntimeException("偽物の失敗")) }
        if (writes.any { it is TxWrite.Update && it.path !in documents }) {
            throw FirestoreWriteFailure(AppError.NotFound, RuntimeException("偽物の不在"))
        }
        if (frozen) return
        for (write in writes) {
            when (write) {
                is TxWrite.Delete -> documents.remove(write.path)
                is TxWrite.Set -> documents[write.path] = write.data
                is TxWrite.Update -> {
                    val updated = documents.getValue(write.path).toMutableMap()
                    write.data.forEach { (key, value) ->
                        val by = (value as? FsValue.Increment)?.by ?: error("退会の手順は加算だけを書く: $key=$value")
                        updated[key] = (updated[key] as? Long ?: 0L) + by
                    }
                    documents[write.path] = updated
                }
            }
        }
    }

    private fun describe(write: TxWrite): String = when (write) {
        is TxWrite.Delete -> "delete ${write.path}"
        is TxWrite.Set -> "set ${write.path}"
        is TxWrite.Update -> "update ${write.path} " + write.data.entries.joinToString(",") { (key, value) ->
            val by = (value as? FsValue.Increment)?.by
            if (by == null) "$key=$value" else "$key${if (by >= 0) "+" else ""}$by"
        }
    }

    /**
     * 削除の書き込み。無い文書の削除は黙って成功する（Firestore の delete と同じ）。⚠️ 本物の rules では、削除の判定に `resource.data` を
     * 見るコレクション（follows・posts・drafts・likes・comments）の無い文書の削除は `PermissionDenied` になるが、ここでは再現しない
     * （再現が要るテストは [writeFailure] で差し込む）。
     */
    private fun write(operation: String, paths: List<String>) {
        record("firestore.$operation ${paths.joinToString(",")}")
        writeFailure(operation, paths)?.let { throw FirestoreWriteFailure(it, RuntimeException("偽物の失敗")) }
        if (!frozen) paths.forEach { documents.remove(it) }
    }

    /**
     * Storage の継ぎ目の偽物。本物と同じく、無いオブジェクトの削除は不在（NotFound）で失敗する。
     * 退会の手順はアップロードしないが、退会の途中に投稿の画像のアップロードを呼ぶテストのために、上げたオブジェクトも記憶域に置く。
     */
    val storage: StorageWriteClient = object : StorageWriteClient {
        override suspend fun put(path: String, bytes: ByteArray, contentType: String) {
            record("storage.put $path")
            objects += path
        }

        override suspend fun downloadUrl(path: String): String = "https://storage.example.test/$path"

        override suspend fun delete(path: String) {
            record("storage.delete $path")
            storageHang(path)?.await()
            storageFailure(path)?.let { throw StorageWriteFailure(it, RuntimeException("偽物の失敗")) }
            if (path !in objects) throw StorageWriteFailure(AppError.NotFound, RuntimeException("偽物の不在"))
            if (!frozen) objects.remove(path)
        }

        // 本物（listAll）と同じく、フォルダの直下のオブジェクトだけを返す（下のフォルダの中身は返さない）。無いフォルダは空
        override suspend fun list(path: String): List<String> {
            record("storage.list $path")
            listHang(path)?.await()
            listFailure(path)?.let { throw StorageWriteFailure(it, RuntimeException("偽物の失敗")) }
            return objects.filter { it.substringBeforeLast('/') == path }
        }
    }

    private fun describe(spec: QuerySpec): String = when (spec) {
        is QuerySpec.DrainByField -> "DrainByField.${spec.target}"
        is QuerySpec.AllOwned -> "AllOwned.${spec.collection}"
        else -> spec.toString()
    }
}

/** 再認証と認証のアカウントの削除だけを受け付ける AuthRepository の偽物。呼ばれたことを [backend] の記録に残す。 */
internal class DeletionAuthRepository(private val backend: DeletionBackend) : AuthRepository {

    override val session: StateFlow<SessionState> = MutableStateFlow(SessionState.SignedIn(Uid("UID-1"), "a@example.com", isAnonymous = false))

    /** 再認証に渡されたパスワード。 */
    val passwords = mutableListOf<String>()
    var reauthResult: AppResult<Unit> = AppResult.Ok(Unit)

    /** 再認証を、記録した後でこの値が完了するまで返さない（取り消しのテスト用）。null なら待たない。 */
    var reauthGate: CompletableDeferred<Unit>? = null
    var deleteResult: AppResult<Unit> = AppResult.Ok(Unit)

    /** 認証のアカウントの削除を、記録した後でこの値が完了するまで返さない（認証のアカウントを消す直前で止めるテスト用）。null なら待たない。 */
    var deleteGate: CompletableDeferred<Unit>? = null

    /**
     * 再認証の結果を、呼ばれた順に 1 つずつ使う（空になったら [reauthResult]）。最初の再認証は通り、認証のアカウントの削除を
     * 呼び直す前の 2 回目だけ失敗する、などの再現に使う（レビュー F11）。
     */
    val reauthResults = ArrayDeque<AppResult<Unit>>()

    /** 認証のアカウントの削除の結果を、呼ばれた順に 1 つずつ使う（空になったら [deleteResult]）。1 回目だけ断られる、などの再現に使う（レビュー F11）。 */
    val deleteResults = ArrayDeque<AppResult<Unit>>()

    override suspend fun reauthenticate(password: String): AppResult<Unit> {
        backend.record("auth.reauthenticate")
        passwords += password
        reauthGate?.await()
        return reauthResults.removeFirstOrNull() ?: reauthResult
    }

    override suspend fun deleteAuthAccount(): AppResult<Unit> {
        backend.record("auth.deleteAuthAccount")
        deleteGate?.await()
        return deleteResults.removeFirstOrNull() ?: deleteResult
    }

    override suspend fun signIn(email: String, password: String): AppResult<Unit> = error("退会では使わない")

    override suspend fun createEmailAccount(email: String, password: String): AppResult<Uid> = error("退会では使わない")

    override suspend fun signOut(): AppResult<Unit> = error("退会では使わない")
}

/**
 * タスク 31.3 の部品（いいね・コメントの削除）の偽物。呼ばれた種類と uid を [backend] の記録に残し、決めた結果を返す。
 * 手順の本体の順序・止まり方のテスト（DefaultAccountDeletionServiceTest）が使う。部品の本物（DefaultOwnReactionsDeleter）を
 * 組み込んだ確認は DefaultOwnReactionsDeleterTest で行う。
 */
internal class DeletionReactions(private val backend: DeletionBackend) : OwnReactionsDeleter {

    /** 種類ごとの結果（無ければ成功）。 */
    var results: Map<ReactionKind, AppResult<Unit>> = emptyMap()

    /** この種類のときに例外を投げる（約束を破った部品の再現）。 */
    var throwOn: ReactionKind? = null

    /** いいねの段階で、記録した後でこの値が完了するまで返さない（取り消しのテスト用）。null なら待たない。 */
    var likesGate: CompletableDeferred<Unit>? = null

    override suspend fun deleteAll(kind: ReactionKind, uid: Uid): AppResult<Unit> {
        backend.record("reactions.${kind.name} ${uid.value}")
        if (kind == throwOn) throw IllegalStateException("偽物の例外")
        if (kind == ReactionKind.LIKE) likesGate?.await()
        return results[kind] ?: AppResult.Ok(Unit)
    }
}

/** 端末内のデータの消去を、[backend] の記録に残すだけの SessionManager の偽物。 */
internal class DeletionSessionManager(private val backend: DeletionBackend) : SessionManager {
    override fun register(state: SessionScopedState) = Unit

    override suspend fun clearLocalUserData() {
        backend.record("session.clearLocalUserData")
    }
}
