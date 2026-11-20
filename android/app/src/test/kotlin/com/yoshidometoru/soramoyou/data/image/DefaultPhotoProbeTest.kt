// ⭐️ 選んだ写真を読み込めるかの確認の単体テスト（タスク 21.2・要件 6.9）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import java.io.IOException
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlinx.coroutines.runBlocking

/**
 * 寸法を読み、間引いて実際に画素を復号し、すぐ解放する、の順で窓口（の偽物）を呼ぶことと、
 * どこかで読めなければ `ImageUnreadable(何枚目か)` にすることを確かめる。
 * 実際の写真（壊れたファイル・対応していない形式）での判定は、端末で 1 回ずつ見る（タスク 21.2 の AVD の確認）。
 */
class DefaultPhotoProbeTest {

    private val uri = "content://media/picker/0/photo/7"

    private val codec = FakeImageCodec()
    private val probe = DefaultPhotoProbe(codec)

    private fun probe(index: Int = 3) = runBlocking { probe.probe(PickedPhoto(uri, index)) }

    @Test
    fun `読める写真は、寸法を読み、長辺256を下回らない範囲で間引いて復号し、すぐ解放してOkを返す`() {
        codec.size = ImageSize(4000, 3000)

        assertEquals(AppResult.Ok(Unit), probe())
        // 4000 を 8 で割ると 500（256 以上）、16 で割ると 250（256 未満）なので 8
        assertEquals(listOf("readSize($uri)", "decode($uri, 8)", "release(500x375)"), codec.calls)
    }

    @Test
    fun `小さい写真は間引かずに復号する`() {
        codec.size = ImageSize(200, 100)

        assertEquals(AppResult.Ok(Unit), probe())
        assertEquals("decode($uri, 1)", codec.calls[1])
    }

    @Test
    fun `寸法を読めない写真（対応していない形式など）は、復号せずに読めない`() {
        codec.size = null

        assertEquals(AppResult.Err(AppError.ImageUnreadable(3)), probe())
        assertEquals(listOf("readSize($uri)"), codec.calls)
    }

    @Test
    fun `寸法が0の写真は読めない`() {
        for (size in listOf(ImageSize(0, 100), ImageSize(100, 0))) {
            codec.size = size
            assertEquals(AppResult.Err(AppError.ImageUnreadable(3)), probe(), "$size")
        }
    }

    @Test
    fun `寸法は読めても画素を復号できない写真（中身が壊れている）は読めない`() {
        codec.decodeReturnsNull = true

        assertEquals(AppResult.Err(AppError.ImageUnreadable(5)), probe(index = 5))
        assertEquals(listOf("readSize($uri)", "decode($uri, 2)"), codec.calls)
    }

    @Test
    fun `写真を開けないなどの窓口の例外は読めない写真にする`() {
        codec.sizeFailure = IOException("写真を開けない")

        assertEquals(AppResult.Err(AppError.ImageUnreadable(3)), probe())
    }

    @Test
    fun `コルーチンの取り消しは失敗に写さず、そのまま伝える`() {
        codec.sizeFailure = CancellationException("取り消し")

        assertFailsWith<CancellationException> { probe() }
    }
}
