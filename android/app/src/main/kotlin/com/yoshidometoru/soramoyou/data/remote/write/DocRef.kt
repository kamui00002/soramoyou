// ⭐️ 書き込み先のドキュメントのパス。型付きの factory からしか作れない（タスク 6.2・要件 2.2）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid

/**
 * 書き込み先のドキュメントのパス（設計書の DocRef。例 `posts/{postId}`）。
 * 文字列から自由に作れないよう、構築子を private にして型付きの factory（[user]・[post] など）だけを公開する。
 * コレクション名の綴りと ID の組み立て方は、ここにだけ書く。
 *
 * ID は 1 つの区切りでなければならない。空や `/` を含む ID は、factory が IllegalArgumentException で止める
 * （Uid・PostId は形式を検査しない型のため。Identifiers.kt）。
 *
 * factory は次の 2 種類だけを置いた。
 * - 書き込み先の ID の形が決まっているもの（形の契約〔ContractId〕があるコレクション）：[user]・[publicProfile]・[post]・[like]
 *   （設計書の「FirestoreReader と クエリ×インデックス表」の節の、表の「単一ドキュメント」の行）。[report]（自動 ID）はタスク 29.1、
 *   [feedback]（大文字の UUID）はタスク 30 で足した
 * - 退会でサーバーから取った ID のまま消すもの（ID を組み立て直さないので、形の違う旧データも消せる。削除なので形の検査はしない）：
 *   [follow]・[draft]・[favorite]（users/{uid}/favorites）はタスク 31.2、[likeById]・[comment] はタスク 31.3 で足した
 */
@JvmInline
value class DocRef private constructor(val path: String) {

    /** ドキュメント ID（パスの最後の区切り）。形の検証で「値がドキュメント ID と一致すること」を見るのに使う。 */
    val documentId: String get() = path.substringAfterLast('/')

    companion object {
        /** `users/{uid}`（非公開のユーザー文書）。 */
        fun user(uid: Uid): DocRef = DocRef("users/${segment(uid.value)}")

        /** `publicProfiles/{uid}`（公開プロフィール）。 */
        fun publicProfile(uid: Uid): DocRef = DocRef("publicProfiles/${segment(uid.value)}")

        /** `posts/{postId}`（投稿）。 */
        fun post(postId: PostId): DocRef = DocRef("posts/${segment(postId.value)}")

        /** `likes/{uid}_{postId}`（いいね。1 人が 1 投稿に 1 件だけ持てる ID の形。設計書 :709・:1039）。 */
        fun like(uid: Uid, postId: PostId): DocRef = DocRef("likes/${segment(uid.value)}_${segment(postId.value)}")

        /**
         * `feedback/{大文字の UUID}`（アプリ内フィードバック。タスク 30）。ID は書き込む側が作る大文字の UUID（iOS の `Feedback.id`：
         * Feedback.swift:44 の `UUID().uuidString`）。フィードバックは作成だけで、読み取り・更新・削除は rules が全て拒否する。
         */
        fun feedback(feedbackId: String): DocRef = DocRef("feedback/${segment(feedbackId)}")

        /**
         * `reports/{自動 ID}`（通報。タスク 29.1）。ID は書き込む側が作る Firestore の自動 ID（iOS の `addDocument` と同じ形）で、
         * 通報される投稿の ID ではない。通報は作成だけで、読み取り・更新・削除は rules が全て拒否する。
         */
        fun report(reportId: String): DocRef = DocRef("reports/${segment(reportId)}")

        /**
         * `likes/{likeId}`（いいね。タスク 31.3 の退会で消す）。[like] と違い ID を組み立て直さず、**サーバーから取った文書の ID をそのまま**渡す
         * （`postId` が欠けた・壊れた旧データのいいねも、取った文書そのものを消すため）。
         */
        fun likeById(likeId: String): DocRef = DocRef("likes/${segment(likeId)}")

        /** `comments/{commentId}`（コメント。タスク 31.3 の退会で消す）。ID はサーバーから取った文書の ID をそのまま渡す（iOS は自動 ID）。 */
        fun comment(commentId: String): DocRef = DocRef("comments/${segment(commentId)}")

        /**
         * `follows/{followId}`（フォロー関係。タスク 31.2 の退会で消す）。ID は iOS が作る `{followerId}_{followeeId}` の形
         * （firestore.rules の follows の create）だが、退会では**サーバーから取った文書の ID をそのまま**渡す（組み立て直さない。形の違う旧データも消すため）。
         */
        fun follow(followId: String): DocRef = DocRef("follows/${segment(followId)}")

        /** `drafts/{draftId}`（下書き。タスク 31.2 の退会で消す）。ID はサーバーから取った文書の ID をそのまま渡す。 */
        fun draft(draftId: String): DocRef = DocRef("drafts/${segment(draftId)}")

        /**
         * `users/{uid}/favorites/{favoriteId}`（お気に入り。タスク 31.2 の退会で消す）。ID はサーバーから取った文書の ID
         * （iOS は投稿の ID にしている：firestore.rules の favorites の create）をそのまま渡す。持ち主の uid と ID の両方が 1 つの区切りであること。
         */
        fun favorite(uid: Uid, favoriteId: String): DocRef =
            DocRef("users/${segment(uid.value)}/favorites/${segment(favoriteId)}")

        /** パスの 1 つの区切りとして使える ID か（空でなく、`/` を含まない）を確かめて返す。 */
        private fun segment(id: String): String {
            require(id.isNotEmpty() && '/' !in id) { "ドキュメント ID に使えない値: 空か、/ を含む" }
            return id
        }
    }
}
