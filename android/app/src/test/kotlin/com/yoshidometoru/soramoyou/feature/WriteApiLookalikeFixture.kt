// ⭐️ 書き込み API の閉じ込めの検査（タスク 6.5）の陰性対照：書き込み API と同じ名前でも、持ち主が SDK でないメソッドだけを呼ぶクラス（実行しない）
package com.yoshidometoru.soramoyou.feature

import com.google.firebase.firestore.FirebaseFirestore
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.data.remote.write.StorageGateway
import java.io.File
import java.util.concurrent.atomic.AtomicReference

/**
 * 画面や ViewModel（write パッケージの外）が普通に書く呼び出し。どれも書き込み API ではないので、WriteApiConfinementTest は検出してはいけない。
 * - 書き込みの入口の delete（自前の入口は、SDK と同じ名前のメソッドを持つ）
 * - List.add・File.delete・AtomicReference.set（SDK の書き込みと同じ名前の、SDK でないメソッド）
 * - Firestore の読み取り（document の get）
 */
internal class WriteApiLookalikeFixture {

    suspend fun callGateways(storage: StorageGateway, firestore: FirestoreWriteGateway, ref: DocRef) {
        storage.delete(WriteCapability.POST_DELETE, StoragePath("posts/writer-uid/public/IMG-1.jpg"))
        firestore.delete(WriteCapability.POST_DELETE, ref)
    }

    fun sameNames(items: MutableList<String>, file: File, latest: AtomicReference<String>) {
        items.add("空")
        file.delete()
        latest.set("空")
    }

    fun read(db: FirebaseFirestore) = db.collection("posts").document("POST-1").get()
}
