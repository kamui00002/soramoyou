// ⭐️ uid・投稿 ID・Storage のパスの型（タスク 3.1・23.2）
package com.yoshidometoru.soramoyou.contract

import com.yoshidometoru.soramoyou.contract.model.Visibility

// iOS 版はこれらをどれも素の String で持っている（Post.swift:13-14、ImageInfo.swift:26）。
// ここでは、中身は同じ文字列でも別々の型にして、引数の取り違え（「uid の場所に投稿 ID」など）を
// コンパイルの時点で止める。@JvmInline なので、実行時に余計な箱は作られない。
//
// ⚠️ 形式（空でない・UUID であるなど）はここでは検査しない。サーバーから読んだ値をそのまま包むため、
//    検査して例外を投げると、壊れたデータ 1 件でページ全体が落ちる（設計書 Error Handling の「読み取りは部分的に劣化」）。
//    形式の検査は、書き込みの直前の DocumentShapeValidator（タスク 3.3）が受け持つ。

/** Firebase Authentication のユーザー ID。`users/{uid}`・`publicProfiles/{uid}` のドキュメント ID と同じ値。 */
@JvmInline
value class Uid(val value: String)

/**
 * 投稿のドキュメント ID。iOS 版は `UUID().uuidString`（大文字の UUID 文字列）で作る
 * （PostViewModel.swift:885）。Android も同じ形式で作る（このクラスは形式を強制しない）。
 */
@JvmInline
value class PostId(val value: String)

/**
 * Firebase Storage のオブジェクトのパス。
 * 本体は `posts/{uid}/{公開範囲}/{画像ID}.jpg`、サムネイルは `thumbnails/{uid}/{公開範囲}/{画像ID}_thumb.jpg`
 * （要件 7.3、ImageInfo.swift:24-25 の注記）。URL ではなくパスである点に注意する。
 */
@JvmInline
value class StoragePath(val value: String) {

    companion object {
        /**
         * プロフィールのアイコン `users/{uid}/profile/profile.jpg`（要件 10.8。iOS と同じパス：ProfileViewModel.swift:519-530）。
         * 1 人に 1 つで、選び直すたびに同じパスへ上書きする（iOS も同じ）。
         *
         * uid は 1 つの区切りでなければならない。空や `/` を含む uid は IllegalArgumentException で止める
         * （書き込み先のパスなので、DocRef の factory と同じ守り。[Uid] は形式を検査しない型のため）。
         */
        fun profileIcon(uid: Uid): StoragePath {
            require(uid.value.isNotEmpty() && '/' !in uid.value) { "uid に使えない値: 空か、/ を含む" }
            return StoragePath("users/${uid.value}/profile/profile.jpg")
        }

        /**
         * 投稿の本体の画像 `posts/{uid}/{公開範囲}/{画像ID}.jpg`（要件 7.3。iOS と同じパス：PostViewModel.swift:728-729）。
         * `{公開範囲}` は投稿の [Visibility.raw]（`public`・`followers`・`private`。storage.rules の 3 つの match と同じ）。
         *
         * uid と画像 ID は 1 つの区切りでなければならない（[profileIcon] と同じ守り。空や `/` を含む値は止める）。
         */
        fun postImage(uid: Uid, visibility: Visibility, imageId: String): StoragePath {
            requireSegment(uid.value, "uid")
            requireSegment(imageId, "画像 ID")
            return StoragePath("posts/${uid.value}/${visibility.raw}/$imageId.jpg")
        }

        /**
         * 投稿のサムネイル `thumbnails/{uid}/{公開範囲}/{画像ID}_thumb.jpg`（要件 7.3。iOS と同じパス：PostViewModel.swift:733-734）。
         * 画像 ID は本体（[postImage]）と同じ値を使う。守りも [postImage] と同じ。
         */
        fun postThumbnail(uid: Uid, visibility: Visibility, imageId: String): StoragePath {
            requireSegment(uid.value, "uid")
            requireSegment(imageId, "画像 ID")
            return StoragePath("thumbnails/${uid.value}/${visibility.raw}/${imageId}_thumb.jpg")
        }

        /** [value] がパスの 1 つの区切りとして使えなければ（空か、`/` を含めば）IllegalArgumentException で止める。 */
        private fun requireSegment(value: String, name: String) {
            require(value.isNotEmpty() && '/' !in value) { "$name に使えない値: 空か、/ を含む" }
        }
    }
}
