// ☁️ 画像のキャッシュの消去の本番の実装：Coil のメモリとディスクのキャッシュを消す（タスク 8.2・要件 2.9）
package com.yoshidometoru.soramoyou.platform

import android.content.Context
import coil3.SingletonImageLoader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * [ImageCacheCleaner] の本番の実装。Coil のアプリ全体で 1 つの ImageLoader（SingletonImageLoader）のキャッシュを消す。
 * 画面の画像は、この同じ ImageLoader で読む前提である（別の ImageLoader を作った画面のキャッシュは、ここでは消えない）。
 * 単体テストはしない（Coil は Android の部品を使う）。
 *
 * ディスクの消去はファイルを消すので、メインスレッドを止めないよう I/O のスレッドで行う。
 *
 * @param context アプリの Context（SingletonImageLoader はこれで 1 つに決まる）。
 */
class CoilImageCacheCleaner(private val context: Context) : ImageCacheCleaner {
    override suspend fun clear() {
        val loader = SingletonImageLoader.get(context)
        loader.memoryCache?.clear()
        withContext(Dispatchers.IO) { loader.diskCache?.clear() }
    }
}
