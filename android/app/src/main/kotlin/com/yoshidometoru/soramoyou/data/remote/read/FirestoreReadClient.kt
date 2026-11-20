// ⭐️ 読み取りの入口と Firestore の SDK の間の継ぎ目（タスク 7.1・23.1・31.1。単体テストで偽物に差し替える）
package com.yoshidometoru.soramoyou.data.remote.read

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import kotlinx.coroutines.flow.Flow

/**
 * Firestore の SDK を呼ぶ部分だけを切り出した継ぎ目。クエリの形・カーソルの規則・失敗の写しは持たない（それは [DefaultFirestoreReader]）。
 * 本番の実装は [FirebaseFirestoreReadClient]、単体テストでは呼ばれた内容を記録する偽物を使う。
 *
 * 失敗は、写せるものは [FirestoreReadFailure] で、それ以外は元の例外のまま投げる。
 * この package の外から使わせないため internal にしている（書き込みの継ぎ目 FirestoreWriteClient と同じ）。
 */
internal interface FirestoreReadClient {

    /** [path] のドキュメントを取得する。無ければ null。 */
    suspend fun get(path: String, source: ReadSource): RawDocument?

    /** [plan] のとおりにクエリを実行し、結果を 1 件ずつ（中身と、続きの起点に使える不透明な値の組）クエリの順で返す。 */
    suspend fun query(plan: QueryPlan, source: ReadSource): List<RawSnapshot>

    /** [plan] の条件に合うドキュメントの件数を、サーバーで集計して返す（取得元は常にサーバー。キャッシュは使わない）。 */
    suspend fun count(plan: CountPlan): Long

    /**
     * [path] のドキュメントを監視し、届くたびに中身（無ければ null）を流す。失敗は流れの例外として投げて終わる。
     * キャッシュの答えで無いとき（オフラインでサーバーから読めていない）は、無いと確かめられないので Network の失敗で終わる（レビュー R17）。
     */
    fun observe(path: String): Flow<RawDocument?>
}

/**
 * [QuerySpec] を展開した、SDK に渡すクエリの中身。作るのは [DefaultFirestoreReader.planOf] だけ。
 * SDK の実装はこれを機械的に適用するだけにし、形の正しさを JVM の単体テストで確かめられるようにする。
 *
 * @property collection コレクションのパス（`posts` のような名前、またはお気に入りの `users/{uid}/favorites`）。
 * @property equalTo 等値の条件（フィールド名と値）。空なら条件なしで全件。
 * @property orderByDescending この順に、新しい（大きい）方から並べるフィールド名。空なら並び順を付けない。
 * @property limit 取得する件数。null なら上限なしで全件（退会の全件取得。[QuerySpec.AllOwned]）。
 * @property after 続きの起点。null なら先頭から。
 */
internal data class QueryPlan(
    val collection: String,
    val equalTo: List<Pair<String, Any>>,
    val orderByDescending: List<String>,
    val limit: Int?,
    val after: RawCursor?,
)

/**
 * [CountSpec] を展開した、SDK に渡す集計の中身。作るのは [DefaultFirestoreReader.countPlanOf] だけ（[QueryPlan] と同じ扱い）。
 * 件数を数えるだけなので、並び順・件数の上限・続きの起点は持たない。
 *
 * @property collection コレクション名。
 * @property equalTo 等値の条件（フィールド名と値）。
 */
internal data class CountPlan(
    val collection: String,
    val equalTo: List<Pair<String, Any>>,
)

/** クエリの結果の 1 件：変換前の中身と、続きの起点（[RawCursor]）に使う SDK のスナップショット（不透明な値）。 */
internal class RawSnapshot(val document: RawDocument, val token: Any)

/** SDK の失敗を [AppError] に写したもの。[FirestoreReadClient] の実装が投げ、入口が `AppResult.Err` にして返す。 */
internal class FirestoreReadFailure(val error: AppError, cause: Throwable) : Exception(cause)
