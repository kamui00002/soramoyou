// ⭐️ Storage へのアップロードと削除の唯一の入口（設計書の部品 StorageGateway。タスク 6.3・要件 2.2・7.3・7.5・15.2）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.WriteCapability

/**
 * Firebase Storage への全ての書き込み（アップロードと削除）を行う、ただ 1 つの入口（設計書 :665-674）。
 * 退会で消す画像を探すための一覧（[list]。タスク 31.6）もここに置く。
 *
 * - 可否：全ての呼び出しの先頭で [WriteGate] に照会し、[cap] が無効なら Storage に到達せずに `AppError.WriteBlocked` を返す
 *   （M1 では全てがこれになる）
 * - Storage の失敗は `AppError` に写して返す（権限の拒否・未認証 → PermissionDenied、不在 → NotFound、
 *   SDK の再試行の上限 → Network）
 *
 * 記録（`error_occurred` と、分類に応じて Crashlytics）は [FirestoreWriteGateway] と同じく、この入口が自分で断ったもの
 * （可否・大きすぎる画像・[exclusively] の区間）だけをここで行う。写して返した Storage の失敗は記録しないので、呼び出し側が自分の発生箇所で記録する。
 */
interface StorageGateway {

    /**
     * [bytes]（JPEG）を [path] にアップロードし、そのダウンロード URL を返す。
     *
     * - `contentType` は `image/jpeg` に固定する（要件 7.3。`storage.rules` は画像の contentType だけを受け付ける）
     * - [bytes] が 5MB（5 * 1024 * 1024 バイト）以上なら送信せずに `AppError.ImageTooLarge`（[index] とバイト数）を返す
     *   （`storage.rules` は「5MB 未満」。主な検査は写真の変換（タスク 16.1）が行い、ここは最後の砦）
     * - ダウンロード URL の取得は、間隔を空けて最大 3 回まで試し、やり直すたびに `retry_operation` を記録する
     *
     * アップロードが成功してダウンロード URL の取得だけが 3 回とも失敗したときは、その失敗を返す。
     * アップロードしたオブジェクトは Storage に残るので、消すかどうかは呼び出し側が決める（投稿の取り消しなど）。
     *
     * @param index 何枚目の画像か（0 始まり）。`ImageTooLarge` に載せて、どの画像が大きすぎたかを画面に伝える。アイコンは 0
     */
    suspend fun uploadJpeg(cap: WriteCapability, path: StoragePath, bytes: ByteArray, index: Int): AppResult<String>

    /**
     * [path] のオブジェクトを消す。
     * 無ければ `AppError.NotFound` を返す（Firestore の delete と違い、Storage は無いものの削除を失敗にする）。
     * 「既に無ければ成功」とみなすかどうかは呼び出し側が決める（設計書 :903 の退会など）。
     */
    suspend fun delete(cap: WriteCapability, path: StoragePath): AppResult<Unit>

    /**
     * フォルダ [folder] の直下のオブジェクトのパスを全て返す（下のフォルダは含めない）。退会が、投稿の文書から拾えなかった画像を
     * 自分のフォルダから探して消すために使う（タスク 31.6）。読み取りだが、消すための一覧なので可否は [delete] と同じく照会する。
     *
     * - `storage.rules` は葉のフォルダ（`posts/{uid}/public` など、規則の `{imageId}` の 1 つ上）の一覧だけを判定する。
     *   その上の階層（`posts/{uid}`・`users/{uid}`）の一覧は当たる規則が無く `PermissionDenied` になる（タスク 33.1 で実測）
     * - [exclusively] の区間の中でも断らない（区間が断るのはアップロードだけ）
     */
    suspend fun list(cap: WriteCapability, folder: StoragePath): AppResult<List<StoragePath>>

    /**
     * [block] を実行している間、[cap] 以外のアップロード（[uploadJpeg]）を、Storage に届けずに `AppError.PermissionDenied` で断って記録する
     * （発生箇所は `StorageGateway.uploadJpeg.during_<cap の名前の小文字>`）。退会（タスク 31.2）が画像を消している間に、投稿やアイコンの保存が
     * 新しい画像を上げないため。理由と決まりは [FirestoreWriteGateway.exclusively] と同じで、削除（[delete]）は通す
     * （投稿の後片付けが、上げた画像を消せるように）。可否の判定が先で、[block] が終われば元に戻る。
     */
    suspend fun <T> exclusively(cap: WriteCapability, block: suspend () -> T): T

    companion object {
        /**
         * `storage.rules` が受け付ける大きさの上限（これ未満だけを受け付ける）。
         * この入口（最後の砦）と写真の変換（タスク 16.1 の ImagePipeline）が、同じ値で `>=` を断る。
         */
        const val MAX_UPLOAD_BYTES = 5 * 1024 * 1024
    }
}
