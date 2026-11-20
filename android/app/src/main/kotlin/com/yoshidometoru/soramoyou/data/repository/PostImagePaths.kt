// ⭐️ 自分の投稿を消すときに、消す画像の Storage のパスを投稿の文書から解決する（タスク 24・要件 10.11）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.model.Visibility
import java.net.URI
import java.net.URLDecoder

/**
 * 投稿の文書の中身 [data] から、投稿を消すときに一緒に消す画像のパスを集める（iOS の `deletePostImages`：StorageService.swift:332-350）。
 *
 * - `images[]`：本体（`storagePath`。無ければ `url` から解決）とサムネイル（`thumbnailStoragePath`。無ければ `thumbnail` から解決）
 * - `originalImages[]`（iOS で作った投稿の編集前の元画像）：本体だけ（iOS もサムネイルは消さない）。2026-10-11 ユーザー判断で消す
 * - パスの値が空でない文字列なら、それを使う（URL には戻らない。iOS の `resolveStoragePath` と同じ）
 * - [isDeletablePostImagePath] を満たさないパスは捨てる（投稿の画像の形でないものは消さない）
 * - 同じパスは 1 回だけ。並びは文書の順（`images` → `originalImages`、各画像は本体 → サムネイル）
 *
 * 型の違う要素（地図でない画像・文字列でない値）は飛ばす（壊れた文書でも、消せる画像は消す）。
 */
internal fun postImagePathsOf(data: Map<String, Any?>, uid: Uid): List<StoragePath> {
    val candidates = buildList {
        mapsOf(data["images"]).forEach { image ->
            add(resolvePath(image["storagePath"], image["url"]))
            add(resolvePath(image["thumbnailStoragePath"], image["thumbnail"]))
        }
        mapsOf(data["originalImages"]).forEach { image ->
            add(resolvePath(image["storagePath"], image["url"]))
        }
    }
    return candidates
        .filterNotNull()
        .filter { isDeletablePostImagePath(it, uid) }
        .distinct()
        .map(::StoragePath)
}

/**
 * [path] が、投稿を消すときに消してよい画像のパスか。
 * `{posts|thumbnails|originals}/{uid}/{public|followers|private}/{名前}` の 4 区切りの形で、uid が [uid] のときだけ true。
 * `storage.rules` が持ち主に削除を許す投稿の画像の形（posts・thumbnails・originals の 3 つ × 公開範囲の 3 つの match）と同じである。
 * アイコン（`users/{uid}/profile/profile.jpg`）や他人のパスは消さない。
 */
internal fun isDeletablePostImagePath(path: String, uid: Uid): Boolean {
    val segments = path.split('/')
    return segments.size == 4 &&
        segments[0] in DELETABLE_ROOTS &&
        segments[1] == uid.value &&
        Visibility.fromRaw(segments[2]) != null &&
        segments[3].isNotEmpty()
}

/**
 * 退会で一覧して、残っている画像を消す [uid] のフォルダ（タスク 31.6）。投稿の画像の 9 つ
 * （`{posts|thumbnails|originals}/{uid}/{public|followers|private}`。[isDeletablePostImagePath] の形の 1 つ上）と、アイコンの `users/{uid}/profile`。
 * `storage.rules` が持ち主に一覧（read）と削除を許す葉のフォルダだけを並べる（上の階層の一覧は rules が断る：タスク 33.1 で実測）。
 * iOS が開発中（2025-12-06〜2026-01-16）だけ使った古いアイコン `users/{uid}/profile.jpg` は含めない。
 *
 * uid は 1 つの区切りでなければならない（`StoragePath.profileIcon` と同じ検査。空や `/` を含む値は断る）。
 */
internal fun ownImageFolders(uid: Uid): List<StoragePath> {
    require(uid.value.isNotEmpty() && '/' !in uid.value) { "uid に使えない値: 空か、/ を含む" }
    val postFolders = DELETABLE_ROOTS.flatMap { root -> Visibility.entries.map { visibility -> "$root/${uid.value}/${visibility.raw}" } }
    return (postFolders + "users/${uid.value}/profile").map(::StoragePath)
}

/**
 * Storage のダウンロード URL から、オブジェクトのパスを取り出す（iOS の `storagePathFromDownloadURL`：StorageService.swift:378-388）。
 *
 * 受け付けるのは、パスが `/v0/b/{バケット}/o/{符号化したパス}` の形の URL だけ（本番の `https://firebasestorage.googleapis.com/…` も、
 * エミュレータの `http://10.0.2.2:9199/…` も同じ形）。最後の区切りの `%XX` を戻して返す。それ以外の形・戻せない符号は null。
 *
 * - `+` は空白に戻さない（`URLDecoder` は `+` を空白にするので、先に `%2B` へ逃がす。パスの `+` はそのまま `+` である）
 * - iOS は最初の `o` の次の区切りを取る。Android は形を全て確かめる（バケット名が `o` でも取り違えない）
 */
internal fun storagePathFromDownloadUrl(url: String): String? {
    // 解釈できない文字列（空白を含むなど）は URISyntaxException になる
    val rawPath = runCatching { URI(url).rawPath }.getOrNull() ?: return null
    // "/v0/b/{バケット}/o/{符号化したパス}" → ["", "v0", "b", バケット, "o", 符号化したパス]
    val segments = rawPath.split('/')
    val matches = segments.size == 6 &&
        segments[0].isEmpty() &&
        segments[1] == "v0" &&
        segments[2] == "b" &&
        segments[3].isNotEmpty() &&
        segments[4] == "o"
    if (!matches) return null
    // 壊れた %XX（%G1 や末尾の % など）は IllegalArgumentException になる。charset は名前で渡す（Charset を取る形は API 33 から）
    val decoded = runCatching { URLDecoder.decode(segments[5].replace("+", "%2B"), "UTF-8") }.getOrNull() ?: return null
    return decoded.ifEmpty { null }
}

/** 消してよいパスの先頭の区切り（本体・サムネイル・元画像）。 */
private val DELETABLE_ROOTS = setOf("posts", "thumbnails", "originals")

/** パスの値（[stored]）が空でない文字列ならそれを、無ければ [url] から解決したパスを返す。どちらも無ければ null。 */
private fun resolvePath(stored: Any?, url: Any?): String? {
    (stored as? String)?.takeIf { it.isNotEmpty() }?.let { return it }
    return (url as? String)?.let(::storagePathFromDownloadUrl)
}

/** [value] が地図のリストなら、その地図だけを（キーが文字列のものとして）返す。リストでなければ空。 */
private fun mapsOf(value: Any?): List<Map<*, *>> = (value as? List<*>).orEmpty().filterIsInstance<Map<*, *>>()
