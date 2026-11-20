// ⭐️ フィードバックの種別（タスク 28・要件 13.2）
package com.yoshidometoru.soramoyou.contract.model

/**
 * フィードバックの種別。[raw] は Firestore の `feedback.category` にそのまま書く文字列、[displayName] は選択肢に出す日本語である。
 * どちらも iOS 版の `FeedbackCategory` と 1 文字も違わない（違うと、運営が集計するときに OS ごとに違う種別が混ざる）。
 *
 * 出典（読んだ現物）:
 * - 文字列値と並び順：Soramoyou/Soramoyou/Models/Feedback.swift:14-18（`bug`・`request`・`other`）
 * - 表示名：同 :21-28（不具合・要望・その他）
 *
 * 種別は任意の項目（選ばなければ `category` のキーを書かない）。書くだけの値なので、文字列から引く `fromRaw` は持たない
 * （Android は `feedback` を読まない。firestore.rules:385 は読み取りを全て拒否する）。
 * 契約（[com.yoshidometoru.soramoyou.contract.document.ShapeContracts.FEEDBACK_CREATE]）は、この [raw] の集合だけを通す。
 */
enum class FeedbackCategory(val raw: String, val displayName: String) {
    BUG("bug", "不具合"),
    REQUEST("request", "要望"),
    OTHER("other", "その他"),
}
