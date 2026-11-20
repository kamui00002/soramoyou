// ⭐️ 選んだ写真を、アップロード用の JPEG に変換する入口（設計書の部品 ImagePipeline。タスク 16.1・22.1・要件 6.9・7.1・7.2・7.4・7.5・10.8）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.FilterId

/**
 * フォトピッカーで選んだ 1 枚の写真。
 *
 * @param uri 写真の content URI（文字列）
 * @param index 何枚目の写真か（0 始まり）。失敗の `ImageUnreadable`・`ImageTooLarge` に載せて、どの写真かを画面に伝える。アイコンは 0
 */
data class PickedPhoto(val uri: String, val index: Int)

/**
 * 変換後の JPEG の規格。
 *
 * @param longEdge 長辺の上限（px）。これより大きい写真だけを縮小し、小さい写真は拡大しない
 * @param quality JPEG の圧縮品質（0〜100）
 */
data class JpegSpec(val longEdge: Int, val quality: Int) {
    init {
        require(longEdge > 0) { "longEdge は 1 以上: $longEdge" }
        require(quality in 0..100) { "quality は 0〜100: $quality" }
    }

    companion object {
        /** プロフィールのアイコン（長辺 1024px 以下・品質 90。タスク 16.1・16.2、要件 10.8）。 */
        val ICON = JpegSpec(longEdge = 1024, quality = 90)

        /** 投稿の本体（長辺 2048px 以下・品質 90。タスク 22.1、要件 7.1・7.4、設計書 Q5）。 */
        val POST_BODY = JpegSpec(longEdge = 2048, quality = 90)

        /** 投稿のサムネイル（長辺 512px 以下・品質 80。タスク 22.1、要件 7.3・7.4、設計書 Q5）。 */
        val POST_THUMBNAIL = JpegSpec(longEdge = 512, quality = 80)
    }
}

/**
 * 変換した JPEG。[bodyWidth]・[bodyHeight] は [body] の画素の寸法（正立に直した後の向き）。
 * 投稿の `images[].width`・`height` には、この値をそのまま書く（要件 7.11）。
 *
 * ByteArray を持つため data class にしない（data class の equals は配列を中身でなく参照で比べてしまう）。
 */
class PreparedImage(val body: ByteArray, val bodyWidth: Int, val bodyHeight: Int)

/**
 * 投稿用に変換した 1 枚（タスク 22.1）。[body] は本体（[JpegSpec.POST_BODY]）、[thumbnail] は同じ画素から作ったサムネイル
 * （[JpegSpec.POST_THUMBNAIL]）。[bodyWidth]・[bodyHeight] は本体の画素の寸法で、投稿の `images[].width`・`height` にそのまま書く（要件 7.11）。
 * サムネイルの寸法は投稿に書かないので持たない。
 *
 * ByteArray を持つため data class にしない（[PreparedImage] と同じ理由）。
 */
class PreparedPostImage(val body: ByteArray, val bodyWidth: Int, val bodyHeight: Int, val thumbnail: ByteArray)

/**
 * 写真を、iOS と同じ規則の JPEG に変換する（設計書「ImagePipeline・PhotoMetadataReader」）。
 *
 * - 大きさだけを先に読み、長辺が [JpegSpec.longEdge] を下回らない範囲で間引いて復号する
 * - EXIF の向き（回転・反転）を画素に焼き込んで正立にし、長辺を [JpegSpec.longEdge] 以下へ縮小して JPEG にする
 * - 出力に EXIF（撮影位置を含む）を書かない（要件 7.2）
 * - 変換後が 5MB 以上なら `AppError.ImageTooLarge`（要件 7.5）、読み込めない写真は `AppError.ImageUnreadable`（要件 6.9）
 *
 * 失敗の記録（`error_occurred`）はここでは行わず、呼び出し側が自分の発生箇所で行う。
 * アイコン（M2）は [prepare]、投稿（M4）は [preparePost] を使う。
 */
interface ImagePipeline {

    /** [photo] を [spec] の長辺と品質の JPEG にする（フィルターもサムネイルも無い。アイコン用）。 */
    suspend fun prepare(photo: PickedPhoto, spec: JpegSpec): AppResult<PreparedImage>

    /**
     * [photo] を投稿用の本体とサムネイルにする（タスク 22.1。引数は Kiro android-edit-tools タスク 2.3・K0 で `filter: FilterId?` から
     * [edit] に変えた：design.md:573）。
     *
     * - 本体：長辺を [JpegSpec.POST_BODY] 以下へ縮小し、[edit] のフィルターに今の行列（[FilterId.legacyMatrix]・プレビューと同じ定義）があれば
     *   それを掛けて、品質 90 の JPEG にする。フィルターが `null` なら「フィルターなし」
     * - サムネイル：本体と**同じ画素**（向きを直し、縮小し、フィルターを掛けた後）を、長辺 [JpegSpec.POST_THUMBNAIL] 以下へ縮小して品質 80 の JPEG にする
     *   （iOS もフィルター済みの縮小後の本体からサムネイルを作る：PostViewModel.swift:717-736）
     * - 本体・サムネイルのどちらかが 5MB 以上なら `ImageTooLarge`（バイト数は大きすぎた方）。読み込めない写真は `ImageUnreadable`
     *
     * K0 の時点では、[edit] のうちフィルターだけを見る（回転・切り抜き・ツールの値は見ない。それらと新しいフィルターの色は A1 が入れる：
     * design.md:871-879）。ナチュラル・ウォーム・クール・ビンテージは行列を持たないので、K0 では何もしない（design.md:360）。
     */
    suspend fun preparePost(photo: PickedPhoto, edit: PhotoEdit): AppResult<PreparedPostImage>
}
