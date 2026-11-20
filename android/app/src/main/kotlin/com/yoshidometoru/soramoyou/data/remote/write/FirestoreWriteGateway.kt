// ⭐️ Firestore への書き込みの唯一の入口（設計書の部品 FirestoreWriteGateway。タスク 6.2・要件 2.2・2.10）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.contract.document.ShapeContract
import com.yoshidometoru.soramoyou.data.remote.RawDocument

/**
 * Firestore への全ての書き込みを、可否の判定 → 形の検証 → 実行 → 記録 の順で行う、ただ 1 つの入口（設計書 :633-663）。
 *
 * - 可否：[cap] が [WriteGate] で無効なら、Firebase に到達せずに `AppError.WriteBlocked` を返す（M1 では全てがこれになる）
 * - 形の検証：契約（[ShapeContract]）に合わない文書は書かずに `AppError.ShapeViolation` を返す（fail-closed）
 * - Firebase の失敗は `AppError` に写して返す（権限の拒否 → PermissionDenied、不在 → NotFound、通信 → Network）
 * - 既存の値とマージする書き込み（merge の指定つきの set）は提供しない（既存の値を巻き戻す経路を作らない）
 *
 * 記録（`error_occurred` と、分類に応じて Crashlytics）は、この入口が自分で断ったもの（可否・形の検証・未ログイン・[exclusively] の区間）だけを
 * ここで行う。写して返した Firebase の失敗は記録しないので、呼び出し側が自分の発生箇所で記録する
 * （断ったものを呼び出し側がもう一度記録すると、監視する件数が二重になる）。
 */
interface FirestoreWriteGateway {

    /** [ref] に [doc] を新しく書く（set。merge の指定なし。既にあれば丸ごと置き換わる）。[doc] は [contract] で検証する。 */
    suspend fun create(cap: WriteCapability, ref: DocRef, contract: ShapeContract, doc: FsDocument): AppResult<Unit>

    /** [ref] の [fields] だけを書き換える（部分更新。ドキュメントが無ければ NotFound）。[fields] は [contract] で検証する。 */
    suspend fun update(cap: WriteCapability, ref: DocRef, contract: ShapeContract, fields: FsDocument): AppResult<Unit>

    /**
     * [ref] を消す。Firestore の delete と同じく、文書が無くても成功する。ただし rules が削除の判定に `resource.data` を見るコレクション
     * （follows・posts・drafts・likes・comments）では、無い文書の削除は rules の評価が拒否になり `PermissionDenied` が返る
     * （「無くても成功」になるのは、rules がパスだけで判定する users・publicProfiles・users/{uid}/favorites など）。
     */
    suspend fun delete(cap: WriteCapability, ref: DocRef): AppResult<Unit>

    /**
     * [refs] をまとめて消す。Firestore の一括書き込みの上限に合わせて 500 件ずつに分けて送る。
     * 分けた束はそれぞれ別のコミットで、全体としては原子的でない。最初に失敗した束で止め、その失敗を返す
     * （それより前の束は消えている。消す処理は何度やり直しても同じ結果になるので、呼び出し側はやり直してよい）。
     */
    suspend fun batchDelete(cap: WriteCapability, refs: List<DocRef>): AppResult<Unit>

    /**
     * [block] を 1 つのトランザクションとして実行し、その戻り値を返す。可否は始める前に 1 回だけ判定する。
     *
     * Firestore のトランザクションの規則がそのまま当てはまる：
     * - 読んだ文書が途中で変わると、Firestore が [block] を最初からやり直す。[block] は何度実行されても良い書き方にする
     *   （外の変数を書き換えない）
     * - 読み取り（[TxScope.get]）は、全ての書き込みより前に行う（書いた後に読むと SDK が例外を投げる）
     * - [block] の中でディスパッチャを切り替えない（`withContext(Dispatchers.IO)` など）。[block] は SDK の実行器のスレッドで動き、
     *   [TxScope.get] はそのスレッドの上で同期の `Transaction.get` を呼ぶため（[FirebaseFirestoreWriteClient.runTransaction]）
     *
     * [block] の中の書き込みが形の検証に違反したら、トランザクション全体を取りやめて `AppError.ShapeViolation` を返す。
     */
    suspend fun <T> transaction(cap: WriteCapability, block: suspend TxScope.() -> T): AppResult<T>

    /**
     * [block] を実行している間、[cap] 以外の「作る・書き換える」書き込み（[create]・[update]・[transaction]）を、Firebase に届けずに
     * `AppError.PermissionDenied` で断って記録する（発生箇所は `FirestoreWriteGateway.<操作名>.during_<cap の名前の小文字>`）。
     * 退会（タスク 31.2）が消している間に、他の画面の書き込み（プロフィールを開いたときの補完・プロフィールの保存・投稿・いいね）が、
     * 消したばかりの文書を作り直さないため（理由の詳細は [ExclusiveWrites]）。
     *
     * - 消す書き込み（[delete]・[batchDelete]）は通す。消すだけなので何も残さないうえ、投稿の後片付け（PostPublisher）のような削除まで
     *   止めると、かえって残してしまうため
     * - 可否（[WriteGate]）の判定が先。無効な書き込みは、区間の中でも `WriteBlocked` のまま
     * - 区間に入る前に入口を通った書き込み（送信中のもの）は止められない
     * - [block] が終われば（成功・失敗・例外・取り消しのどれでも）元に戻る。入れ子・同時に呼んでよいのは同じ [cap] だけ
     *   （別の [cap] の区間の中で呼ぶと [IllegalStateException]）
     */
    suspend fun <T> exclusively(cap: WriteCapability, block: suspend () -> T): T
}

/** [FirestoreWriteGateway.transaction] の中で使える操作（設計書 :654-659）。書き込みは全て形の検証を通る。 */
interface TxScope {

    /** [ref] を読む。無ければ null。 */
    suspend fun get(ref: DocRef): RawDocument?

    /** [ref] に [doc] を新しく書く（merge の指定なし）。違反があればトランザクション全体を取りやめる。 */
    fun create(ref: DocRef, contract: ShapeContract, doc: FsDocument)

    /** [ref] の [fields] だけを書き換える。違反があればトランザクション全体を取りやめる。 */
    fun update(ref: DocRef, contract: ShapeContract, fields: FsDocument)

    /** [ref] を消す。 */
    fun delete(ref: DocRef)
}
