// ☁️ 書き込みの値（FsValue）を Firestore の SDK の値に変える（タスク 6.2）
package com.yoshidometoru.soramoyou.data.remote.write

import com.google.firebase.Timestamp
import com.google.firebase.firestore.FieldValue
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.contract.document.FsValue

/** 文書（[FsDocument]）の全ての値を、SDK に渡せる値にする。キーと並びは変えない。 */
internal fun FsDocument.toSdkData(): Map<String, Any> = mapValues { (_, value) -> value.toSdkValue() }

/**
 * 1 つの値を SDK の値にする。FsValue は null と小数を持たないので、SDK にも null と小数は渡らない（タスク 3.3）。
 * 整数は Long のまま渡す（Firestore の整数型になる）。日時は Timestamp、サーバーの時刻・増減・配列の追加と削除・
 * フィールドの削除は FieldValue の各値にする。
 */
internal fun FsValue.toSdkValue(): Any = when (this) {
    is FsValue.Str -> value
    is FsValue.Int64 -> value
    is FsValue.Bool -> value
    is FsValue.Time -> Timestamp(instant)
    FsValue.ServerTime -> FieldValue.serverTimestamp()
    is FsValue.Increment -> FieldValue.increment(by)
    is FsValue.StrList -> values
    is FsValue.MapList -> values.map { element -> element.toSdkData() }
    is FsValue.ArrayUnion -> FieldValue.arrayUnion(*values.toTypedArray())
    is FsValue.ArrayRemove -> FieldValue.arrayRemove(*values.toTypedArray())
    FsValue.DeleteField -> FieldValue.delete()
}
