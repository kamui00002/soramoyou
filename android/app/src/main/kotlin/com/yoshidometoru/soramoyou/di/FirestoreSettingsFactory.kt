// ⭐️☁️ Firestore の設定：ローカルキャッシュをメモリだけにする（タスク 5.1・要件 2.2・2.9）
package com.yoshidometoru.soramoyou.di

import com.google.firebase.firestore.FirebaseFirestoreSettings
import com.google.firebase.firestore.MemoryCacheSettings

/**
 * Firestore のインスタンスに当てる設定を作る（設計書「M1の書き込みゼロ保証」6・research.md「Firestoreのローカルキャッシュをメモリだけにする」）。
 *
 * - ローカルキャッシュはメモリだけにし、ディスクに永続化しない。オフラインの書き込みの待ち行列も、
 *   ログアウトした人の読み取り結果も、端末に残さないため（オフラインでは閲覧できなくなるが、MVP の要件には無い）。
 * - SDK の既定は、ディスクに永続化する（firebase-firestore 26.6.0 の Builder の persistenceEnabled = true。javap で確認）。
 *   そのため、インスタンスを作るたびに必ずこの設定を当てる（[ResettableInstance] の configure）。
 * - メモリのキャッシュの掃除の仕方（GC）は SDK の既定のまま。接続先のホスト・SSL も既定のまま（本番の Firestore）。
 */
object FirestoreSettingsFactory {

    /** ローカルキャッシュをメモリだけにした設定。 */
    fun memoryOnly(): FirebaseFirestoreSettings =
        FirebaseFirestoreSettings.Builder()
            .setLocalCacheSettings(MemoryCacheSettings.newBuilder().build())
            .build()
}
