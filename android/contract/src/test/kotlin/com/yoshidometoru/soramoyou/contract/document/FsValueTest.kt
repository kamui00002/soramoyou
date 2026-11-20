// ⭐️ 書き込み値の型 FsValue の単体テスト（タスク 3.3・要件 3.5・7.12）
package com.yoshidometoru.soramoyou.contract.document

import java.lang.reflect.Modifier
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * [FsValue] の種類と [ValueKind] が 1 対 1 に対応すること、
 * そして浮動小数を持たないことを固定する。
 *
 * null を表現できないこと（任意の項目は「キーを入れない」ことでしか表せない）は、
 * `FsDocument = Map<String, FsValue>` の値が非 null であるというコンパイル時の性質なので、ここでは検査しない。
 */
class FsValueTest {

    /** FsValue の全種類を 1 個ずつ。種類を足したら、ここと [FsValue.kind] の when の両方を直す。 */
    private val oneOfEachVariant: List<FsValue> = listOf(
        FsValue.Str("a"),
        FsValue.Int64(1L),
        FsValue.Bool(true),
        FsValue.Time(Instant.EPOCH),
        FsValue.ServerTime,
        FsValue.Increment(1L),
        FsValue.StrList(listOf("a")),
        FsValue.MapList(listOf(mapOf("k" to FsValue.Str("v")))),
        FsValue.ArrayUnion(listOf("a")),
        FsValue.ArrayRemove(listOf("a")),
        FsValue.DeleteField,
    )

    @Test
    fun `全ての種類のkindを集めるとValueKindの全値と一致する`() {
        val kinds = oneOfEachVariant.map { it.kind }
        assertEquals(ValueKind.entries.toSet(), kinds.toSet())
    }

    @Test
    fun `kindは種類ごとに重複しない1対1の対応である`() {
        val kinds = oneOfEachVariant.map { it.kind }
        assertEquals(ValueKind.entries.size, kinds.size)
        assertEquals(kinds.size, kinds.toSet().size, "同じ kind を返す種類がある: $kinds")
    }

    @Test
    fun `種類ごとのkindの対応を1つずつ固定する`() {
        assertEquals(ValueKind.STR, FsValue.Str("a").kind)
        assertEquals(ValueKind.INT64, FsValue.Int64(1L).kind)
        assertEquals(ValueKind.BOOL, FsValue.Bool(false).kind)
        assertEquals(ValueKind.TIME, FsValue.Time(Instant.EPOCH).kind)
        assertEquals(ValueKind.SERVER_TIME, FsValue.ServerTime.kind)
        assertEquals(ValueKind.INCREMENT, FsValue.Increment(-1L).kind)
        assertEquals(ValueKind.STR_LIST, FsValue.StrList(emptyList()).kind)
        assertEquals(ValueKind.MAP_LIST, FsValue.MapList(emptyList()).kind)
        assertEquals(ValueKind.ARRAY_UNION, FsValue.ArrayUnion(emptyList()).kind)
        assertEquals(ValueKind.ARRAY_REMOVE, FsValue.ArrayRemove(emptyList()).kind)
        assertEquals(ValueKind.DELETE, FsValue.DeleteField.kind)
    }

    @Test
    fun `FsValueの種類は11個で、ValueKindの個数と同じである`() {
        // 反射で数えて、oneOfEachVariant の書き漏れ（種類を足したのにテストを直していない）に気づく
        val declared = FsValue::class.java.declaredClasses.filter { FsValue::class.java.isAssignableFrom(it) }
        assertEquals(ValueKind.entries.size, declared.size, "FsValue の種類: ${declared.map { it.simpleName }}")
        assertEquals(oneOfEachVariant.size, declared.size)
    }

    @Test
    fun `どの種類も浮動小数のフィールドを持たない`() {
        // iOS の ImageInfo は width・height・order を `as? Int` で読む（ImageInfo.swift:80-86）。
        // 小数が混ざると画像が黙って落ちるので、MVP の FsValue は Float / Double を型として持たない。
        // 将来 editSettings を書くときに Float64 を足すのは意図した拡張なので、そのときこのテストも意図して直す。
        val declared = FsValue::class.java.declaredClasses.filter { FsValue::class.java.isAssignableFrom(it) }
        val fieldTypes = declared.flatMap { cls ->
            cls.declaredFields.filter { !Modifier.isStatic(it.modifiers) }.map { it.type }
        }
        // 基本型（double / float）と、箱型（Double / Float）の両方を見る
        val floatingPoint = fieldTypes.filter {
            it == Double::class.javaPrimitiveType || it == Float::class.javaPrimitiveType ||
                it == Double::class.javaObjectType || it == Float::class.javaObjectType
        }
        assertTrue(floatingPoint.isEmpty(), "浮動小数のフィールドがある: $floatingPoint")
        // 反射が空振りしていないこと（整数の Long は見えている）を確かめる
        assertTrue(fieldTypes.contains(Long::class.javaPrimitiveType), "フィールドの型を読めていない: $fieldTypes")
    }
}
