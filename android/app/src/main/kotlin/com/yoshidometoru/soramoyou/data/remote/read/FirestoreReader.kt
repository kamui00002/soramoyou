// ⭐️ Firestore からの読み取りの唯一の入口（タスク 7.1・23.1・31.1・要件 1.4・4.1・4.2・7.19・12.3）
package com.yoshidometoru.soramoyou.data.remote.read

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import kotlinx.coroutines.flow.Flow

/**
 * Firestore からの読み取りの入口（設計書の FirestoreReader。:690）。読み取りだけを持ち、書き込みは持たない
 * （書き込みは write パッケージの入口だけ。WriteApiConfinementTest が強制する）。
 *
 * 提供するのは、単一ドキュメントの取得と監視、[QuerySpec] の閉じた集合のクエリ、[CountSpec] の閉じた集合の集計だけである（要件 1.4）。
 */
interface FirestoreReader {

    /** [ref] のドキュメントを取得する。無ければ `Ok(null)`。 */
    suspend fun get(ref: DocRef, source: ReadSource = ReadSource.DEFAULT): AppResult<RawDocument?>

    /**
     * [spec] の形のクエリを実行し、変換前の生のドキュメントの列と、最後の 1 件を起点とするカーソルを返す。
     * 退会の取得（[QuerySpec.DrainByField]・[QuerySpec.AllOwned]）は、[source] によらず**常にサーバー**で読む
     * （通信が切れたときにキャッシュの一部を「全件」と誤認させないため。通信が切れたら `Err` になる）。
     */
    suspend fun query(spec: QuerySpec, source: ReadSource = ReadSource.DEFAULT): AppResult<RawPage>

    /**
     * [spec] の形の件数を、**常にサーバーで**集計して返す（設計書の count。タスク 23.1）。取得元を選ぶ引数は持たない。
     * 端末のキャッシュで数えると、キャッシュに載っている分だけの件数になり、それを投稿数として書いてしまうため。
     */
    suspend fun count(spec: CountSpec): AppResult<Long>

    /**
     * [ref] のドキュメントを監視し、届くたびに中身を `Ok` で流す（無ければ `Ok(null)`。タスク 15.1：自分のユーザー文書の監視）。
     * 失敗したら `Err` を 1 回流して終わる（SDK も失敗の後は監視を続けない）。監視は集め始めたときに張り、集めるのをやめたら外す。
     */
    fun observe(ref: DocRef): Flow<AppResult<RawDocument?>>
}
