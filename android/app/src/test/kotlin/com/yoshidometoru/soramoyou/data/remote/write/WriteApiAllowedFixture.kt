// ⭐️ 書き込み API の閉じ込めの検査（タスク 6.5）の陰性対照：write パッケージの中で書き込み API を使うクラス（実行しない）
package com.yoshidometoru.soramoyou.data.remote.write

import com.google.firebase.firestore.DocumentReference

/** write パッケージの中なので、書き込み API を参照していても検出しない（許可の境界を確かめるためのもの）。 */
internal class WriteApiAllowedFixture {

    fun write(doc: DocumentReference) = doc.set(mapOf("caption" to "空"))
}
