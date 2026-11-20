// ⭐️ Firestore の失敗の種類を AppError に写す関数の単体テスト（タスク 6.2・設計書 :662）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppError
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * JVM の単体テストでは `FirebaseFirestoreException` も、その `Code` の値も作れない（作る途中で Android の TextUtils・SparseArray を呼ぶ）。
 * そこで、写し方は名前で確かめ、その名前が SDK の列挙に実在することを、クラスを初期化せずにリフレクションで確かめる。
 */
class FirestoreErrorsTest {

    @Test
    fun `権限の拒否・不在・通信の断絶を、それぞれのAppErrorに写す`() {
        assertEquals(AppError.PermissionDenied, firestoreErrorOf("PERMISSION_DENIED"))
        assertEquals(AppError.NotFound, firestoreErrorOf("NOT_FOUND"))
        assertEquals(AppError.Network, firestoreErrorOf("UNAVAILABLE"))
    }

    @Test
    fun `それ以外の種類はUnknownにし、種類の名前だけを載せる`() {
        assertEquals(AppError.Unknown("FirebaseFirestoreException.ABORTED"), firestoreErrorOf("ABORTED"))
    }

    @Test
    fun `写し方に使う名前は、SDKのFirebaseFirestoreException_Codeに実在する`() {
        // initialize = false：static 初期化（SparseArray）を走らせずに、列挙の定数名だけを読む
        val code = Class.forName(
            "com.google.firebase.firestore.FirebaseFirestoreException\$Code",
            false,
            javaClass.classLoader,
        )
        val names = code.declaredFields.filter { it.isEnumConstant }.map { it.name }.toSet()

        // 読めていること自体の確かめ（空なら下の検査は意味を持たない）
        assertTrue("OK" in names && "ABORTED" in names, "SDK の列挙の定数名を読めていない: $names")
        for (name in listOf("PERMISSION_DENIED", "NOT_FOUND", "UNAVAILABLE")) {
            assertTrue(name in names, "$name は SDK の FirebaseFirestoreException.Code に無い: $names")
        }
    }
}
