// ⭐️ Firestore の失敗の種類を AppError に写す（タスク 6.2・設計書 :662）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.AppError

/**
 * Firestore の失敗の種類（`FirebaseFirestoreException.Code` の名前）を [AppError] に写す（設計書 :662）。
 * - `PERMISSION_DENIED` → [AppError.PermissionDenied]
 * - `NOT_FOUND` → [AppError.NotFound]（部分更新の先が無いときなど）
 * - `UNAVAILABLE` → [AppError.Network]（通信の断絶。SDK が再試行してもつながらなかった）
 * - それ以外 → [AppError.Unknown]（種類の名前だけを載せる）
 *
 * 列挙そのものでなく名前で受けるのは、`Code` の static 初期化が Android の SparseArray を使い、
 * JVM の単体テストでは列挙の値に触れることすらできないため。名前が SDK の列挙に実在することは FirestoreErrorsTest が確かめる。
 */
internal fun firestoreErrorOf(codeName: String): AppError = when (codeName) {
    "PERMISSION_DENIED" -> AppError.PermissionDenied
    "NOT_FOUND" -> AppError.NotFound
    "UNAVAILABLE" -> AppError.Network
    else -> AppError.Unknown("FirebaseFirestoreException.$codeName")
}
