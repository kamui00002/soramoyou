// ⭐️ Firestore へ書く値の型（タスク 3.3・要件 3.5・7.12）
package com.yoshidometoru.soramoyou.contract.document

import java.time.Instant

/**
 * Firestore へ書く値を表す閉じた型（設計書 :494-525）。次の 2 つを、**型として表現できない**ようにしてある。
 *
 * - **null**：任意の項目に値が無いときは、null や空文字を書かず「キーを入れない」ことでしか表せない
 *   （要件 3.5・7.12）。[FsDocument] の値は非 null なので、null を入れようとするとコンパイルが通らない。
 * - **浮動小数**：iOS の `ImageInfo` は `width`・`height`・`order` を `as? Int` で読む
 *   （Soramoyou/Soramoyou/Models/ImageInfo.swift:80-86）。小数が 1 つ混ざると、その画像が黙って読み飛ばされる。
 *   整数で書くべき値に小数を書く事故を、型の段階で起こせなくするため、MVP の [FsValue] は小数の種類を持たない。
 *   将来 `editSettings`（iOS は `Float` で読む：EditSettings.swift:222-252）を書くときに `Float64` を足す。
 *   それが唯一の拡張点（設計書 :503・8.3）。
 *
 * この型は Firebase の型を参照しない（`:contract` は純 Kotlin）。Firebase の値（`Timestamp`・`FieldValue` など）への
 * 変換は、`:app` のゲートウェイが受け持つ。
 *
 * 種類を足したら、[kind] の `when`（else 無し）がコンパイルエラーになって気づける。
 */
sealed interface FsValue {
    /** 文字列。 */
    data class Str(val value: String) : FsValue

    /** 整数。`width`・`height`・`order`・各カウンタなど、iOS が `Int` で読む値はこれで書く。 */
    data class Int64(val value: Long) : FsValue

    /** 真偽値。 */
    data class Bool(val value: Boolean) : FsValue

    /** 端末時刻の Timestamp。 */
    data class Time(val instant: Instant) : FsValue

    /** サーバー時刻（`FieldValue.serverTimestamp()`）。 */
    data object ServerTime : FsValue

    /** 加算（`FieldValue.increment`）。許す値（±1 のみ）は契約で制限する。 */
    data class Increment(val by: Long) : FsValue

    /** 文字列の配列。 */
    data class StrList(val values: List<String>) : FsValue

    /** マップの配列（`images` など）。各要素の形は、契約の `nested` で検証する。 */
    data class MapList(val values: List<Map<String, FsValue>>) : FsValue

    /** 配列への追加（`FieldValue.arrayUnion`）。 */
    data class ArrayUnion(val values: List<String>) : FsValue

    /** 配列からの削除（`FieldValue.arrayRemove`）。 */
    data class ArrayRemove(val values: List<String>) : FsValue

    /** フィールドの削除（`FieldValue.delete()`）。契約の `kinds` に `DELETE` が無ければ違反になる。 */
    data object DeleteField : FsValue
}

/** 書き込む 1 つのドキュメント（キー → 値）。キーが無いことが「値が無い」を表す。 */
typealias FsDocument = Map<String, FsValue>

/**
 * この値の種類。[ValueKind] と 1 対 1 に対応する。
 * `else` を書かない網羅的な `when` にしているので、[FsValue] に種類を足すとここがコンパイルエラーになる
 * （足したのに契約側の種類を決め忘れる、を防ぐ）。
 */
val FsValue.kind: ValueKind
    get() = when (this) {
        is FsValue.Str -> ValueKind.STR
        is FsValue.Int64 -> ValueKind.INT64
        is FsValue.Bool -> ValueKind.BOOL
        is FsValue.Time -> ValueKind.TIME
        FsValue.ServerTime -> ValueKind.SERVER_TIME
        is FsValue.Increment -> ValueKind.INCREMENT
        is FsValue.StrList -> ValueKind.STR_LIST
        is FsValue.MapList -> ValueKind.MAP_LIST
        is FsValue.ArrayUnion -> ValueKind.ARRAY_UNION
        is FsValue.ArrayRemove -> ValueKind.ARRAY_REMOVE
        FsValue.DeleteField -> ValueKind.DELETE
    }
