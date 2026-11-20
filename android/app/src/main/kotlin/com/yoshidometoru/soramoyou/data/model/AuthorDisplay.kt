// ⭐️ 投稿者の名前とアイコンの表示（タスク 9.2・要件 4.4・4.5）
package com.yoshidometoru.soramoyou.data.model

/**
 * 一覧などに出す投稿者の表示（設計書の AuthorDisplay。:766-769）。作るのは AuthorProfileCache だけである。
 * 名前とアイコンは `publicProfiles/{uid}` からだけ取り、Firebase Authentication のプロフィールは使わない（要件 4.4）。
 *
 * 画面は [name] と [photoUrl] を読むだけでよい。[Fallback] の名前は常に [FALLBACK_NAME] で、
 * uid や内部 ID の一部を名前に使うことはない（要件 4.5）。
 */
sealed interface AuthorDisplay {

    /** 画面に出す名前。 */
    val name: String

    /** アイコンの URL。無ければ null（画面は人の形の代わりの絵を出す。iOS：HomeView.swift の avatarPlaceholder）。 */
    val photoUrl: String?

    /** 公開プロフィールの表示名が読めたとき。 */
    data class Named(override val name: String, override val photoUrl: String?) : AuthorDisplay

    /**
     * 代替表示。公開プロフィールが無い・取得に失敗した・中の `id` がドキュメント ID と一致しないときは [photoUrl] も null。
     * プロフィールは正しいが表示名が無いときは、iOS と同じくアイコンだけは出す
     * （iOS は名前とアイコンを別々に `author?.displayName ?? "ユーザー"`・`author?.photoURL` で読む）。
     */
    data class Fallback(override val photoUrl: String?) : AuthorDisplay {
        override val name: String get() = FALLBACK_NAME
    }

    companion object {
        /**
         * 代替表示の名前。iOS 版の現物から一字一句写した
         * （origin/main `266d428` の HomeView.swift:558 `Text(author?.displayName ?? "ユーザー")`）。
         */
        const val FALLBACK_NAME: String = "ユーザー"
    }
}
