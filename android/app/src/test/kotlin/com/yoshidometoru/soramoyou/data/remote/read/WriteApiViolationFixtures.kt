// ⭐️ 書き込み API の閉じ込めの検査（タスク 6.5）の陽性対照：write パッケージの外で書き込み API を使うクラス（コンパイルするだけで、実行しない）
package com.yoshidometoru.soramoyou.data.remote.read

import android.net.Uri
import com.google.firebase.firestore.CollectionReference
import com.google.firebase.firestore.DocumentReference as Doc
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.google.firebase.firestore.Transaction
import com.google.firebase.storage.StorageMetadata
import com.google.firebase.storage.StorageReference
import java.io.InputStream

/**
 * 設計書 :276 の書き込み API と書き込み専用の型を、全て使うクラス（WriteApiConfinementTest が、全てを検出することを確かめる）。
 * - DocumentReference は別名で import している（ソースの文字列の走査では見逃す書き方も、クラスの走査なら検出できる）
 * - 定数プールで 2 枠を使う Long と Double の定数も持たせる（読み飛ばしを誤ると、それより後ろの参照を読み違える）
 */
internal class WriteApiViolationFixture {

    val retryMillis: Long = 12_345_678_901L

    val jpegQuality: Double = 0.85

    fun firestore(db: FirebaseFirestore, doc: Doc, posts: CollectionReference) {
        doc.set(mapOf("caption" to "空"))
        doc.set(mapOf("caption" to "空"), SetOptions.merge())
        doc.update(mapOf("likesCount" to FieldValue.increment(1)))
        doc.delete()
        posts.add(mapOf("caption" to "空"))
        db.batch().commit()
        db.runBatch { batch -> batch.delete(doc) }
        db.runTransaction { transaction -> transaction.get(doc) }
    }

    fun storage(ref: StorageReference, bytes: ByteArray, uri: Uri, stream: InputStream) {
        ref.putBytes(bytes)
        ref.putFile(uri)
        ref.putStream(stream)
        ref.delete()
        ref.updateMetadata(StorageMetadata.Builder().setContentType("image/jpeg").build())
    }
}

/** 書き込み専用の型を、引数の型に書くだけのクラス（型はメソッドの記述子にしか現れない。クラスの参照としては現れない）。 */
internal class WriteTypeOnlyFixture {

    fun keep(transaction: Transaction): Any = transaction
}
