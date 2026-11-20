// ⭐️ 投稿の公開範囲（タスク 3.2・要件 4.11・7.13・16.1）
package com.yoshidometoru.soramoyou.contract.model

/**
 * 投稿の公開範囲。[raw] は Firestore の `visibility` にそのまま書く文字列、[displayName] は画面に出す日本語である。
 * どちらも iOS 版の `Visibility` と 1 文字も違わない（違うと、片方の OS で書いた値をもう片方が読み違える）。
 *
 * 出典（読んだ現物）:
 * - 文字列値と並び順：Soramoyou/Soramoyou/Models/Visibility.swift:12-14（`public`・`followers`・`private`）
 * - 表示名：同 :17-23（公開・フォロワーのみ・非公開）
 *
 * ⚠️ 未知・欠落の `visibility` の扱いは、iOS と Android で違う。
 * - iOS は、`visibility` が未知または欠落のとき `.public` に倒す（Post.swift:328-331）。
 * - Android の設計（design.md「PostDocumentReader」の未知の列挙値の扱い）では、未知の列挙値は `null` にする。
 * - この enum 層は `null` を返すだけで、倒さない。表示のときに `null` を「公開」として見せるかどうかは、
 *   投稿の表示用変換（タスク 7.2 の PostView）の責務である。ここで勝手に倒すと、
 *   「読めなかった」と「公開だった」を呼び出し側が区別できなくなる。
 */
enum class Visibility(val raw: String, val displayName: String) {
    PUBLIC("public", "公開"),
    FOLLOWERS("followers", "フォロワーのみ"),
    PRIVATE("private", "非公開");

    companion object {
        /**
         * 文字列値から公開範囲を引く。Swift の `init(rawValue:)` と同じく、完全一致・大文字小文字を区別する。
         * 前後の空白の除去や小文字化はしない（する理由が無く、iOS と挙動がずれる）。
         * 未知の文字列・`null` は例外にせず `null` を返す（未知の値で投稿の表示を失敗させない：要件 4.11）。
         */
        fun fromRaw(raw: String?): Visibility? = entries.firstOrNull { it.raw == raw }
    }
}
