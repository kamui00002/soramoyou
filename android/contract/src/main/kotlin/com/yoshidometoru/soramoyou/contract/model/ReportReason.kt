// ⭐️ 投稿の通報理由（タスク 28・要件 11.2・11.3）
package com.yoshidometoru.soramoyou.contract.model

/**
 * 投稿の通報理由。[raw] は Firestore の `reports.reason` にそのまま書く文字列、[displayName] は選択肢に出す日本語である。
 * どちらも iOS 版の `ReportReason` と 1 文字も違わない（違うと、運営が通報を見るときに OS ごとに違う値が混ざる）。
 *
 * 出典（読んだ現物）:
 * - 文字列値と並び順：Soramoyou/Soramoyou/Models/ReportReason.swift:11-16
 *   （`inappropriate`・`spam`・`harassment`・`copyright`・`other`）
 * - 表示名：同 :19-32（不適切なコンテンツ・スパム・迷惑行為・嫌がらせ・誹謗中傷・著作権侵害・その他）
 *
 * 書くだけの値なので、文字列から引く `fromRaw` は持たない（Android は `reports` を読まない。firestore.rules:369 は読み取りを全て拒否する）。
 * 契約（[com.yoshidometoru.soramoyou.contract.document.ShapeContracts.REPORT_CREATE]）は、この [raw] の集合だけを通す。
 */
enum class ReportReason(val raw: String, val displayName: String) {
    INAPPROPRIATE("inappropriate", "不適切なコンテンツ"),
    SPAM("spam", "スパム・迷惑行為"),
    HARASSMENT("harassment", "嫌がらせ・誹謗中傷"),
    COPYRIGHT("copyright", "著作権侵害"),
    OTHER("other", "その他"),
}
