// ⭐️ 選んだ写真を読み込めるかを、写真を選んだ直後に確かめる（タスク 21.2・要件 6.9）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 選んだ写真を読み込めるか（画素まで復号できるか）を確かめる（要件 6.9「読み込めない写真は投稿の対象にせず、理由を表示する」）。
 *
 * 投稿の作成の画面が、写真を選んだ直後に 1 枚ずつ呼ぶ。読めない写真は、プレビューに出す前に投稿の対象から外す。
 * 投稿のときの変換（[ImagePipeline]）と同じ窓口（[ImageCodec]・本番は BitmapFactory）で復号するので、
 * ここで読めた写真は、投稿のときにも同じ理由では落ちない。
 */
interface PhotoProbe {

    /**
     * [photo] を読めれば `Ok`、読めなければ `ImageUnreadable(photo.index)` を返す。
     * 失敗の記録（`error_occurred`）はここでは行わず、呼び出し側が自分の発生箇所で行う（[ImagePipeline] と同じ）。
     */
    suspend fun probe(photo: PickedPhoto): AppResult<Unit>
}

/**
 * [PhotoProbe] の実装。次の順で確かめる。
 *
 * 1. 大きさ：[ImageCodec.readSize] で寸法だけを読む。読めない・0 なら読めない（対応していない形式は多くがここで落ちる）
 * 2. 復号：長辺が [PROBE_LONG_EDGE] を下回らない範囲で間引いて、実際に画素を復号する。復号できなければ読めない
 *    （寸法の書かれた先頭だけが無事で、中身が壊れている写真を落とすため）。復号した画像はすぐに解放する
 *
 * 間引くのは、確かめるためだけに大きな画像をメモリに持たないため（12MP の写真なら 1/8 に間引いて約 500px で復号する）。
 * 窓口の例外（写真を開けない・権限が無い）は読めない写真とし、コルーチンの取り消しは失敗に写さずにそのまま伝える。
 *
 * @param dispatcher 復号を行うスレッド。画面のスレッドで重い処理をしないよう、既定は IO
 */
class DefaultPhotoProbe internal constructor(
    private val codec: ImageCodec,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : PhotoProbe {

    override suspend fun probe(photo: PickedPhoto): AppResult<Unit> = withContext(dispatcher) {
        try {
            decodeOnce(photo)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            AppResult.Err(AppError.ImageUnreadable(photo.index))
        }
    }

    private fun decodeOnce(photo: PickedPhoto): AppResult<Unit> {
        val unreadable = AppResult.Err(AppError.ImageUnreadable(photo.index))
        val size = codec.readSize(photo.uri) ?: return unreadable
        if (size.width <= 0 || size.height <= 0) return unreadable
        val decoded = codec.decode(photo.uri, sampleSizeFor(size.width, size.height, PROBE_LONG_EDGE)) ?: return unreadable
        codec.release(decoded)
        return AppResult.Ok(Unit)
    }

    internal companion object {
        /** 確かめるときに復号する長辺の下限（px）。プレビューの格子 1 つ分より少し大きい程度で、復号の可否を見るには十分。 */
        const val PROBE_LONG_EDGE = 256
    }
}
