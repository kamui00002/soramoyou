// ☁️ 書き込みの値（FsValue）を Firestore の SDK の値に変える関数の単体テスト（タスク 6.2）
package com.yoshidometoru.soramoyou.data.remote.write

import com.google.firebase.Timestamp
import com.google.firebase.firestore.FieldValue
import com.yoshidometoru.soramoyou.contract.document.FsValue
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertSame

/**
 * SDK に渡る値の型と中身を確かめる。FieldValue の増減・配列の値は package-private の getter でしか読めないので、
 * リフレクションで読む（SDK の版が変わって getter が無くなったら、このテストが落ちて知らせる）。
 */
class SdkValuesTest {

    /** package-private の引数なしメソッドを呼ぶ。 */
    private fun Any.callHidden(name: String): Any? =
        javaClass.getDeclaredMethod(name).apply { isAccessible = true }.invoke(this)

    @Test
    fun `文字列・整数・真偽値は、そのままの型で渡す（整数はLong）`() {
        assertEquals("a", FsValue.Str("a").toSdkValue())
        val int = FsValue.Int64(3).toSdkValue()
        assertIs<Long>(int)
        assertEquals(3L, int)
        assertEquals(true, FsValue.Bool(true).toSdkValue())
    }

    @Test
    fun `日時はTimestampにする`() {
        val instant = Instant.parse("2026-10-04T01:02:03.456Z")
        assertEquals(Timestamp(instant), FsValue.Time(instant).toSdkValue())
    }

    @Test
    fun `サーバーの時刻とフィールドの削除は、SDKの決まった値にする`() {
        assertSame(FieldValue.serverTimestamp(), FsValue.ServerTime.toSdkValue())
        assertSame(FieldValue.delete(), FsValue.DeleteField.toSdkValue())
    }

    @Test
    fun `増減は、その量のincrementにする`() {
        val value = FsValue.Increment(-1).toSdkValue()
        assertEquals<Class<*>>(FieldValue.increment(-1L).javaClass, value.javaClass)
        assertEquals(-1L, value.callHidden("getOperand"))
    }

    @Test
    fun `配列への追加と削除は、要素をそのまま持つarrayUnionとarrayRemoveにする`() {
        val union = FsValue.ArrayUnion(listOf("a", "b")).toSdkValue()
        assertEquals<Class<*>>(FieldValue.arrayUnion("x").javaClass, union.javaClass)
        assertEquals(listOf("a", "b"), union.callHidden("getElements"))

        val remove = FsValue.ArrayRemove(listOf("c")).toSdkValue()
        assertEquals<Class<*>>(FieldValue.arrayRemove("x").javaClass, remove.javaClass)
        assertEquals(listOf("c"), remove.callHidden("getElements"))
    }

    @Test
    fun `文字列の配列はList、Mapの配列は中の値も変えたListにする`() {
        assertEquals(listOf("a", "b"), FsValue.StrList(listOf("a", "b")).toSdkValue())

        val instant = Instant.parse("2026-10-04T00:00:00Z")
        val images = FsValue.MapList(listOf(mapOf("width" to FsValue.Int64(1080), "at" to FsValue.Time(instant))))

        assertEquals(listOf(mapOf("width" to 1080L, "at" to Timestamp(instant))), images.toSdkValue())
    }

    @Test
    fun `文書はキーを変えずに、全ての値を変える`() {
        val doc = mapOf("id" to FsValue.Str("P1"), "count" to FsValue.Int64(0), "createdAt" to FsValue.ServerTime)

        assertEquals(
            mapOf("id" to "P1", "count" to 0L, "createdAt" to FieldValue.serverTimestamp()),
            doc.toSdkData(),
        )
    }
}
