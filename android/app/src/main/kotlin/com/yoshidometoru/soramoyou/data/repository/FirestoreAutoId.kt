// ⭐️ Firestore の自動 ID と同じ形の ID を作る（タスク 29.1・要件 11.2）
package com.yoshidometoru.soramoyou.data.repository

import java.security.SecureRandom
import java.util.Random

/**
 * Firestore の自動 ID と同じ形（英大文字・英小文字・数字から 20 文字）の ID を作る。
 *
 * 通報（`reports`）は、iOS が `addDocument` で自動 ID を付けて作る。Android は `DocumentReference.set` で書く入口（FirestoreWriteGateway）を
 * 通すため、書き込む前に ID を決める必要がある（SDK の `document()` で ID を得ると、AppContainer の外で Firestore のインスタンスを触る）。
 * そこで SDK と同じ文字の集合・長さで作り、`reports` の文書の ID の形を OS で揃える（UUID にすると、運営が見る一覧に 2 種類の形が混ざる）。
 * 乱数は暗号用の `SecureRandom`（SDK の自動 ID と同じ）。
 */
internal object FirestoreAutoId {

    /** ID の長さ（Firestore の自動 ID と同じ）。 */
    const val LENGTH: Int = 20

    /** ID に使う文字（Firestore の自動 ID と同じ 62 文字）。 */
    const val ALPHABET: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

    private val secureRandom = SecureRandom()

    /** 新しい ID を 1 つ作る。[random] は単体テストで決まった並びに差し替えるための口で、製品は既定の `SecureRandom` を使う。 */
    fun next(random: Random = secureRandom): String =
        buildString(LENGTH) {
            repeat(LENGTH) { append(ALPHABET[random.nextInt(ALPHABET.length)]) }
        }
}
