// ☁️ 撮影日時の読み取りの継ぎ目の本番の実装：ExifInterface と ContentResolver.query を呼ぶ（タスク 22.2）
package com.yoshidometoru.soramoyou.data.image

import android.content.ContentResolver
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import java.io.IOException

/**
 * [PhotoMetadataSource] の本番の実装。写真は [resolver] から URI で開く（フォトピッカーの URI は読み取りの権限つきで渡される）。
 *
 * - EXIF：元ファイルを開いて `ExifInterface` で `DateTimeOriginal`・`OffsetTimeOriginal` を文字列のまま読む（解釈は [DefaultPhotoMetadataReader] 側）
 * - 撮影日時の列：渡された URI **そのもの**に [COLUMN_DATE_TAKEN] を問い合わせる。端末内の画像全体（`MediaStore.Images`）には問い合わせない
 *   （広い読み取り権限を持たない設計：タスク 21.1 の `verifyNoBroadMediaPermission`）
 *
 * ⚠️ JVM の単体テストでは Android の API が動かないため、このクラスは単体テストの対象外。
 * 端末で動かす `AndroidPhotoMetadataSourceDeviceTest`（androidTestEmulator）で確かめる。
 */
internal class AndroidPhotoMetadataSource(private val resolver: ContentResolver) : PhotoMetadataSource {

    override fun readExifDateTime(uri: String): ExifDateTime {
        val exif = open(uri).use { ExifInterface(it) }
        return ExifDateTime(
            dateTimeOriginal = exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL),
            offsetTimeOriginal = exif.getAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL),
        )
    }

    override fun queryDateTakenMillis(uri: String): Long? =
        resolver.query(Uri.parse(uri), arrayOf(COLUMN_DATE_TAKEN), null, null, null)?.use { cursor ->
            // 列を返さない提供元は、問い合わせた名前を無視して別の列だけを返すことがあるので、位置を名前で引き直す
            val column = cursor.getColumnIndex(COLUMN_DATE_TAKEN)
            if (column < 0 || !cursor.moveToFirst() || cursor.isNull(column)) null else cursor.getLong(column)
        }

    private fun open(uri: String) =
        resolver.openInputStream(Uri.parse(uri)) ?: throw IOException("写真を開けない")

    internal companion object {
        /**
         * 写真選択画面の撮影日時の列（エポックからのミリ秒）。`MediaStore.PickerMediaColumns.DATE_TAKEN` と同じ値。
         * その定数は API 33（Android 11・12 は SDK 拡張 2）からなので、minSdk 26 でも参照できるよう文字列で持つ。
         * 値は SDK 36・37 の android.jar を javap で読んで確かめた（`MediaStore.MediaColumns.DATE_TAKEN` も同じ `"datetaken"`）。
         */
        const val COLUMN_DATE_TAKEN = "datetaken"
    }
}
