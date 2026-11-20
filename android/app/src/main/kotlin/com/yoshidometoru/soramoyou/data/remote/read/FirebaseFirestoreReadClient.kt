// ☁️ 読み取りの継ぎ目の本番の実装：Firestore の SDK を呼ぶ（タスク 7.1・15.1・23.1・31.1）
package com.yoshidometoru.soramoyou.data.remote.read

import com.google.firebase.firestore.AggregateSource
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreException
import com.google.firebase.firestore.Query
import com.google.firebase.firestore.Source
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.write.firestoreErrorOf
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await

/**
 * [FirestoreReadClient] の本番の実装。[QueryPlan] を SDK のクエリにそのまま写すだけで、形は決めない。
 * SDK の失敗は、書き込みと同じ表（[firestoreErrorOf]。表を二重に持たない）で写して投げる。
 * インデックスの欠落（`FAILED_PRECONDITION`）は `Unknown` の名前に現れる（設計書 :707）。
 *
 * @param firestore 操作のたびに Firestore のインスタンスを得る（AppContainer の `firestore.current()`）。
 *   ログアウトでインスタンスが作り直されるので（タスク 5.1）、得たものを持ち続けない。
 */
internal class FirebaseFirestoreReadClient(private val firestore: () -> FirebaseFirestore) : FirestoreReadClient {

    override suspend fun get(path: String, source: ReadSource): RawDocument? =
        sdk { db -> db.document(path).get(source.toSdk()).await().toRawDocument() }

    override suspend fun query(plan: QueryPlan, source: ReadSource): List<RawSnapshot> = sdk { db ->
        var query: Query = db.collection(plan.collection)
        plan.equalTo.forEach { (field, value) -> query = query.whereEqualTo(field, value) }
        plan.orderByDescending.forEach { field -> query = query.orderBy(field, Query.Direction.DESCENDING) }
        // 上限なし（退会の全件取得）は limit を付けない。付けると「全件」にならない
        plan.limit?.let { query = query.limit(it.toLong()) }
        // 続きの起点は、前のページでこのクラスが返したスナップショット（RawSnapshot.token）だけ
        plan.after?.let { query = query.startAfter(it.token as DocumentSnapshot) }
        query.get(source.toSdk()).await().documents.map { snapshot ->
            RawSnapshot(RawDocument(id = snapshot.id, data = snapshot.data.orEmpty()), token = snapshot)
        }
    }

    override suspend fun count(plan: CountPlan): Long = sdk { db ->
        var query: Query = db.collection(plan.collection)
        plan.equalTo.forEach { (field, value) -> query = query.whereEqualTo(field, value) }
        // 集計はサーバーだけで行える（SDK の AggregateSource は SERVER だけ。firebase-firestore 26.6.0 を javap で確認）
        query.count().get(AggregateSource.SERVER).await().count
    }

    override fun observe(path: String): Flow<RawDocument?> = callbackFlow {
        // 集め始めたときのインスタンスに張る（ログアウトで作り直されたら、新しく集め直した側が新しいインスタンスに張る）
        val registration = firestore().document(path).addSnapshotListener { snapshot, error ->
            if (error != null) {
                // SDK は失敗の後に監視を続けないので、写した失敗で流れを閉じる
                close(FirestoreReadFailure(firestoreErrorOf(error.code.name), error))
            } else if (snapshot != null) {
                when (val observed = observedDocumentOf(snapshot.toRawDocument(), snapshot.metadata.isFromCache)) {
                    is AppResult.Ok -> trySend(observed.value)
                    // キャッシュの「無い」は確かめた不在ではないので、通信の失敗として閉じる（再試行は画面が出す。レビュー R17）
                    is AppResult.Err -> close(FirestoreReadFailure(observed.error, IllegalStateException(UNCONFIRMED_ABSENCE)))
                }
            }
        }
        awaitClose { registration.remove() }
    }.buffer(Channel.CONFLATED) // 画面が使うのは最新の中身だけなので、追いつかない間の古い中身は捨てる

    /** SDK を呼び、Firestore の失敗を [FirestoreReadFailure] に写す。それ以外の例外はそのまま伝える。 */
    private suspend inline fun <T> sdk(block: (FirebaseFirestore) -> T): T =
        try {
            block(firestore())
        } catch (e: FirebaseFirestoreException) {
            throw FirestoreReadFailure(firestoreErrorOf(e.code.name), e)
        }

    /** SDK の列挙はこのクラスの中だけで触る（JVM の単体テストでは SDK の列挙の初期化に失敗することがあるため）。 */
    private fun ReadSource.toSdk(): Source = when (this) {
        ReadSource.DEFAULT -> Source.DEFAULT
        ReadSource.SERVER -> Source.SERVER
    }

    /** 無ければ null。あれば ID と、SDK が返したままのフィールドの値。 */
    private fun DocumentSnapshot.toRawDocument(): RawDocument? =
        if (exists()) RawDocument(id = id, data = data.orEmpty()) else null

    private companion object {
        /** キャッシュの「無い」で閉じるときの原因の説明（パスは uid を含むので載せない）。 */
        const val UNCONFIRMED_ABSENCE = "document absent in cache only"
    }
}

/**
 * 文書の監視に届いた中身 [document]（無ければ null）を、流す値（`Ok`）か、流れを閉じる失敗（`Err`）にする（レビュー R17）。
 * SDK のスナップショット（DocumentSnapshot）は JVM の単体テストで作れないので、判定だけをこの純関数に切り出して確かめる。
 *
 * - ある → そのまま流す（キャッシュからでも。オフラインでも、前に読んだ文書は出す）
 * - 無いとサーバーが答えた（[isFromCache] が false）→ `Ok(null)`（文書が無い）
 * - 無いが、キャッシュからの答え（[isFromCache] が true）→ `Err(Network)`。オフラインで一度もサーバーから読んでいない文書は、
 *   キャッシュに無いだけで、本当に無いとは言えない。「無い」として流すと、自分のプロフィールの見出しが「ユーザー・投稿数 0」に化ける
 *
 * ⚠️ 流さずにサーバーの答えを待つ形にはしない。編集の画面は監視の最初の 1 回（first）を待つので、オフラインで読み込み中のまま止まる。
 */
internal fun observedDocumentOf(document: RawDocument?, isFromCache: Boolean): AppResult<RawDocument?> =
    if (document == null && isFromCache) AppResult.Err(AppError.Network) else AppResult.Ok(document)
