// ⭐️ Firestore から読んだ 1 件のドキュメントの、変換前の中身（タスク 6.2・7.1）
package com.yoshidometoru.soramoyou.data.remote

/**
 * Firestore から読んだ 1 件のドキュメントの、変換前の中身（設計書の RawDocument）。
 * トランザクションの中の読み取り（タスク 6.2 の TxScope.get）と、読み取り口（タスク 7.1 の FirestoreReader）が返す。
 * 表示用の型への変換は、ここでは行わない（投稿は PostDocumentReader。設計書 :717）。
 *
 * @property id ドキュメント ID（パスの最後の区切り）。
 * @property data フィールドの値。SDK が返したままの値（Timestamp・List・Map など）で、null の値もそのまま入る。
 */
data class RawDocument(val id: String, val data: Map<String, Any?>)
