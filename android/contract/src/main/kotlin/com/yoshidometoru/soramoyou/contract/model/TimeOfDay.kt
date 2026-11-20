// ⭐️ 時間帯（タスク 3.2・要件 4.11・5.4・7.13・16.1）
package com.yoshidometoru.soramoyou.contract.model

/**
 * 時間帯。[raw] は Firestore の `timeOfDay` にそのまま書く文字列、[displayName] は画面に出す日本語である。
 * どちらも iOS 版の `TimeOfDay` と 1 文字も違わない（違うと、片方の OS で書いた値をもう片方が読み違える）。
 *
 * 出典（読んだ現物）:
 * - 文字列値と並び順：Soramoyou/Soramoyou/Models/TimeOfDay.swift:12-15（`morning`・`afternoon`・`evening`・`night`）
 * - 表示名：同 :18-25（朝・昼・夕方・夜）
 *
 * ここに置かないもの：
 * - アイコン名（同 :28-35 の SF Symbols）は、描画用の値なので移植しない。
 * - 時刻から時間帯を決める規則（同 :38-51 の `from(date:)`）は、この enum の担当ではない。
 *   タスク 20.2 の rules/TimeOfDayResolver が持つ。値と表示名の置き場と、時刻の規則の置き場を分けておく。
 */
enum class TimeOfDay(val raw: String, val displayName: String) {
    MORNING("morning", "朝"),
    AFTERNOON("afternoon", "昼"),
    EVENING("evening", "夕方"),
    NIGHT("night", "夜");

    companion object {
        /**
         * 文字列値から時間帯を引く。Swift の `init(rawValue:)` と同じく、完全一致・大文字小文字を区別する。
         * 前後の空白の除去や小文字化はしない（する理由が無く、iOS と挙動がずれる）。
         * 未知の文字列・`null` は例外にせず `null` を返す（未知の値で投稿の表示を失敗させない：要件 4.11）。
         */
        fun fromRaw(raw: String?): TimeOfDay? = entries.firstOrNull { it.raw == raw }
    }
}
