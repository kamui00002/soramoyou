// ⭐️ 空の種類（タスク 3.2・要件 4.11・5.4・7.13・16.1）
package com.yoshidometoru.soramoyou.contract.model

/**
 * 空の種類。[raw] は Firestore の `skyType` にそのまま書く文字列、[displayName] は画面に出す日本語である。
 * どちらも iOS 版の `SkyType` と 1 文字も違わない（違うと、片方の OS で書いた値をもう片方が読み違える）。
 *
 * 出典（読んだ現物）:
 * - 文字列値と並び順：Soramoyou/Soramoyou/Models/SkyType.swift:12-16（`clear`・`cloudy`・`sunset`・`sunrise`・`storm`）
 * - 表示名：同 :19-27（晴れ・曇り・夕焼け・朝焼け・嵐）
 *
 * 移植しないもの：iOS の列挙にあるアイコン名（同 :30-38 の SF Symbols）は、描画用の値なのでここへ持ち込まない。
 */
enum class SkyType(val raw: String, val displayName: String) {
    CLEAR("clear", "晴れ"),
    CLOUDY("cloudy", "曇り"),
    SUNSET("sunset", "夕焼け"),
    SUNRISE("sunrise", "朝焼け"),
    STORM("storm", "嵐");

    companion object {
        /**
         * 文字列値から空の種類を引く。Swift の `init(rawValue:)` と同じく、完全一致・大文字小文字を区別する。
         * 前後の空白の除去や小文字化はしない（する理由が無く、iOS と挙動がずれる）。
         * 未知の文字列・`null` は例外にせず `null` を返す（未知の値で投稿の表示を失敗させない：要件 4.11）。
         */
        fun fromRaw(raw: String?): SkyType? = entries.firstOrNull { it.raw == raw }
    }
}
