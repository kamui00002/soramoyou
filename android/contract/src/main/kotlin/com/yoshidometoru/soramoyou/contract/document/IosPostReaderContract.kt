// ⭐️ iOS 版が投稿を読めるかの判定（タスク 20.5・要件 7.10・7.11・17.7）
package com.yoshidometoru.soramoyou.contract.document

/**
 * iOS 版で投稿を読んだときの結果。
 */
sealed interface IosPostReadResult {

    /** 投稿ごと読めない（iOS の `Post.init(from:)` が throw する）。iOS のフィードから、その 1 件が消える。[reason] に値は入れない。 */
    data class Unreadable(val reason: String) : IosPostReadResult

    /**
     * 投稿は読める。[droppedImageIndexes] は、iOS が**黙って読み飛ばす**画像の `images` の添字（昇順）。
     * 空なら全ての画像が表示される。全部が落ちると、画像の無い投稿として表示される。
     */
    data class Readable(val droppedImageIndexes: List<Int>) : IosPostReadResult
}

/**
 * Firestore に保存された投稿（生のマップ）を、iOS 版が読めるかを判定する。用途はテストと検証に限る（設計書 :600-604）。
 * テストのソースでなく main に置くのは、タスク 25.3 で本番から読んだ文書の検証にも使えるようにするため
 * （アプリの画面からは呼ばない。使わなければリリースビルドの縮小で落ちる）。
 *
 * iOS の読み取り（Soramoyou/Soramoyou/Models/Post.swift:214-335 の `init(from:)`、ImageInfo.swift:80-100 の `init?(from:)`）のうち、
 * **読み取りを失敗させる条件だけ**を写してある。読める条件を全部写すと iOS の実装の写しになり、保守の対象が増えるため、
 * 任意の項目（キャプション・撮影日時・列挙値など。iOS は欠落も未知の値も既定値や nil に倒す）は見ない。
 *
 * ## 投稿ごと読めない条件（Post.swift:215-228）
 * - `postId` または `userId` が文字列でない（欠落を含む）
 * - `images` が「文字列をキーとするマップ」の配列でない（欠落・配列でない・マップでない要素や null が 1 つでも混ざる）。
 *   空の配列は読める（画像の無い投稿になる）
 *
 * ## 画像が読み飛ばされる条件（ImageInfo.swift:80-86。Post.swift:225 の `compactMap` で黙って落ちる）
 * - `url` が文字列でない
 * - `width`・`height`・`order` が、Swift の `as? Int` で読めない
 *
 * ## `as? Int` で読める値（Swift 6.4・macOS 27 で実測：手元（git の外）の `20.5-nsnumber_as_int.tsv`・`rv4-B7-swift.tsv`）
 * Firestore の iOS SDK は、整数を NSNumber(longLong)、小数を NSNumber(double)、真偽値を NSNumber(bool) で返す。
 * `as? Int` は、整数・**小数部が 0 の小数**（`1536.0`）・**真偽値**（true は 1・false は 0）を読み、小数部のある小数（`1536.5`）と文字列は読まない。
 * この判定も同じにする（Android の書き込みが整数で書くことは、契約 [ShapeContracts.POST_IMAGE] が別に守っている）。
 *
 * 生のマップの値は、Firestore の Android SDK の読み取りと同じ Kotlin の型を想定する
 * （整数＝[Long]、小数＝[Double]、真偽値＝[Boolean]、配列＝[List]、マップ＝[Map]）。
 */
object IosPostReaderContract {

    fun judge(document: Map<String, Any?>): IosPostReadResult {
        if (document["postId"] !is String || document["userId"] !is String) {
            return IosPostReadResult.Unreadable("postId or userId is not a string")
        }
        val images = document["images"] as? List<*>
            ?: return IosPostReadResult.Unreadable("images is not an array")
        if (!images.all(::isStringKeyedMap)) {
            return IosPostReadResult.Unreadable("images contains an element that is not a map")
        }
        val dropped = images.withIndex()
            .filterNot { (_, image) -> isReadableImage(image as Map<*, *>) }
            .map { it.index }
        return IosPostReadResult.Readable(dropped)
    }

    /** Swift の `as? [String: Any]` が通る要素（キーが全て文字列のマップ）。 */
    private fun isStringKeyedMap(element: Any?): Boolean = element is Map<*, *> && element.keys.all { it is String }

    /** ImageInfo.swift:81-84 の guard が通る画像。 */
    private fun isReadableImage(image: Map<*, *>): Boolean =
        image["url"] is String && readsAsSwiftInt(image["width"]) && readsAsSwiftInt(image["height"]) && readsAsSwiftInt(image["order"])

    /** Swift の `as? Int` が値を返すか（クラスの説明の実測）。 */
    private fun readsAsSwiftInt(value: Any?): Boolean = when (value) {
        is Long, is Int, is Boolean -> true
        // 小数部が 0 で、-2^63〜2^63 の小数だけ（実測：-2^63 と 2^63 は読む。2^63 は Int の最大値になる。
        // 無限大（正・負）・NaN・±1e300・最も小さい有限の小数・-2^63 と 2^63 の 1 つ外は読まない）
        is Double -> value.isFinite() && value == Math.floor(value) && value >= -TWO_POW_63 && value <= TWO_POW_63
        else -> false
    }

    private const val TWO_POW_63 = 9.223372036854775808E18
}
