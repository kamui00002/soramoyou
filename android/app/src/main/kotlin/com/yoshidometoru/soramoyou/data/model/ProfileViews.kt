// ⭐️ プロフィールの表示（自分のユーザー文書・他人の公開プロフィール）（タスク 15.1・要件 10.1・10.3・10.4）
package com.yoshidometoru.soramoyou.data.model

import com.yoshidometoru.soramoyou.contract.Uid

/**
 * 自分のユーザー文書（`users/{uid}`）から読んだプロフィール（設計書の OwnProfile。:870）。作るのは ProfileRepository だけである。
 * 表示名・自己紹介は読んだままの値（空白だけの文字列も含む）で持つ。プロフィール編集（タスク 16.2）が「変えた項目」を比べる元にするため。
 * 代替表示「ユーザー」への置き換えは、画面に出すとき（[display]）に行う。
 *
 * @property uid ログイン中のユーザーの uid（ドキュメント ID）。
 * @property displayName 表示名。無いか文字列でなければ null。
 * @property photoUrl アイコンの URL。画面で読み込んでよいもの（このビルドの Storage のダウンロード URL の形）だけで、それ以外は null。
 * @property bio 自己紹介。無いか文字列でなければ null。
 * @property postsCount 投稿数。無いか数でなければ 0（iOS の `likesCount` の欠落と同じ扱い。設計書 :1114）。
 */
data class OwnProfile(
    val uid: Uid,
    val displayName: String?,
    val photoUrl: String?,
    val bio: String?,
    val postsCount: Long,
) {
    /** 画面に出す名前とアイコン。表示名が無いか空なら代替表示にし、uid などを名前に使わない（要件 10.3）。 */
    val display: AuthorDisplay
        get() = displayName?.takeIf { it.isNotBlank() }?.let { AuthorDisplay.Named(it, photoUrl) } ?: AuthorDisplay.Fallback(photoUrl)
}

/**
 * 他人の公開プロフィール（`publicProfiles/{uid}`）の表示（設計書の PublicProfileView。:1115）。作るのは ProfileRepository だけである。
 *
 * ドキュメントが無いとき・中の `id` が [uid] と一致しないときは、中身を使わない代替表示（[fallback]）になる（要件 4.5・10.3）。
 * 再試行しても変わらないので、取得の失敗（通信・権限）とは分けて成功として返す（2026-10-06 ユーザー判断）。
 *
 * @property uid 要求した uid。
 * @property author 名前とアイコン。名前が無い・空・代替表示のときは [AuthorDisplay.Fallback]。
 * @property bio 自己紹介。無ければ null。
 * @property postsCount 投稿数。無いか数でなければ 0。
 */
data class PublicProfileView(
    val uid: Uid,
    val author: AuthorDisplay,
    val bio: String?,
    val postsCount: Long,
) {
    companion object {
        /** 公開プロフィールが無い・`id` が一致しないときの表示。名前は代替表示、アイコン・自己紹介は無し、投稿数は 0。 */
        fun fallback(uid: Uid): PublicProfileView = PublicProfileView(uid, AuthorDisplay.Fallback(null), bio = null, postsCount = 0L)
    }
}
