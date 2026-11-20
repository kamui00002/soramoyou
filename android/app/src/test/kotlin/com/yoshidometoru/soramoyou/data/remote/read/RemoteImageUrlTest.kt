// ⭐️ 画面で読み込む画像の URL を、ビルドの変種の Storage のダウンロード URL の形だけに限る単体テスト（全体レビュー 4 回目 R11）
package com.yoshidometoru.soramoyou.data.remote.read

import com.yoshidometoru.soramoyou.contract.rules.StorageDownloadUrl
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

/**
 * 投稿の画像（`images[].url`・`thumbnail`）とプロフィールのアイコン（`photoURL`）は、
 * 本番のビルドは本番の Storage のダウンロード URL の形だけを、検証用のビルドはエミュレータの Storage の形だけを通す。
 */
class RemoteImageUrlTest {

    private val prodBase = "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/"
    private val emuBase = "http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/"

    /** Storage の名前（パスの `/` は `%2F` に符号化される）。 */
    private val name = "posts%2FUID-1%2Fpublic%2FIMG-0.jpg"

    @Test
    fun `forBuild は検証用のビルドならエミュレータの形を、それ以外は本番の形を選ぶ`() {
        assertEquals(RemoteImageUrlPolicy.EMULATOR, RemoteImageUrlPolicy.forBuild(useFirebaseEmulator = true))
        assertEquals(RemoteImageUrlPolicy.PRODUCTION, RemoteImageUrlPolicy.forBuild(useFirebaseEmulator = false))
    }

    @Test
    fun `形は書き込みの契約と同じ定数を使う`() {
        assertEquals(StorageDownloadUrl.PRODUCTION_PATTERN, RemoteImageUrlPolicy.PRODUCTION.regex.pattern)
        assertEquals(StorageDownloadUrl.EMULATOR_PATTERN, RemoteImageUrlPolicy.EMULATOR.regex.pattern)
    }

    @Test
    fun `本番の形は本番のStorageのダウンロードURLを作り直さずにそのまま通す`() {
        listOf(
            "$prodBase$name?alt=media&token=abc-123",
            "$prodBase$name",
            "https://firebasestorage.googleapis.com:443/v0/b/soramoyou-ios.firebasestorage.app/o/$name?alt=media&token=abc-123",
            "$prodBase$name?", // クエリは空でもよい（rules と同じ）
        ).forEach { assertSame(it, remoteImageUrlOf(it, RemoteImageUrlPolicy.PRODUCTION), it) }
    }

    @Test
    fun `本番の形はエミュレータのStorageのダウンロードURLを通さない`() {
        listOf(
            "$emuBase$name?alt=media&token=abc-123",
            "$emuBase$name",
        ).forEach { assertNull(remoteImageUrlOf(it, RemoteImageUrlPolicy.PRODUCTION), it) }
    }

    @Test
    fun `本番の形は本番のStorageのダウンロードURLでない文字列を通さない`() {
        listOf(
            "" to "空文字",
            "https://example.com/a.jpg" to "別のホスト",
            "http://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "http の本番のホスト",
            "HTTPS://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "scheme が大文字",
            "https://FIREBASESTORAGE.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "ホストが大文字",
            "https://firebasestorage.googleapis.com:8443/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "別のポート",
            "https://user@firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "利用者名つき",
            "https://firebasestorage.googleapis.com/v0/b/other-bucket.firebasestorage.app/o/$name" to "別のバケット",
            "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.appspot.com/o/$name" to "appspot.com のバケット",
            "${prodBase}posts/UID-1/IMG-0.jpg" to "名前に / がある",
            prodBase to "名前が空",
            "$prodBase$name?alt=media&token=a b" to "クエリに空白",
            " $prodBase$name" to "前に余計な文字（一部の一致では通さない）",
            "$prodBase$name#frag" to "後ろに余計な文字",
            "$prodBase$name\n" to "後ろに改行",
            "file:///data/data/com.yoshidometoru.soramoyou/files/a.jpg" to "file の方式",
            "content://media/external/images/media/1" to "content の方式",
            "android.resource://com.yoshidometoru.soramoyou/drawable/a" to "android.resource の方式",
            "javascript:alert(1)" to "javascript の方式",
            "/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "方式とホストの無いパスだけ",
        ).forEach { (value, why) -> assertNull(remoteImageUrlOf(value, RemoteImageUrlPolicy.PRODUCTION), why) }
    }

    @Test
    fun `検証用の形はエミュレータのStorageのダウンロードURLだけを通す`() {
        listOf(
            "$emuBase$name?alt=media&token=abc-123",
            "$emuBase$name",
        ).forEach { assertSame(it, remoteImageUrlOf(it, RemoteImageUrlPolicy.EMULATOR), it) }
        listOf(
            "$prodBase$name?alt=media&token=abc-123" to "本番の Storage",
            "https://firebasestorage.googleapis.com:443/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "本番の Storage（:443 つき）",
            "https://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/$name" to "https のエミュレータ",
            "http://127.0.0.1:9199/v0/b/demo-soramoyou.appspot.com/o/$name" to "別の住所のエミュレータ",
            "http://10.0.2.2:9198/v0/b/demo-soramoyou.appspot.com/o/$name" to "別のポートのエミュレータ",
            "http://10.0.2.2:9199/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "エミュレータの住所に本番のバケット",
            "https://example.com/a.jpg" to "別のホスト",
            emuBase to "名前が空",
        ).forEach { (value, why) -> assertNull(remoteImageUrlOf(value, RemoteImageUrlPolicy.EMULATOR), why) }
    }

    @Test
    fun `文字列でない値はどちらの形でも通さない`() {
        RemoteImageUrlPolicy.entries.forEach { policy ->
            listOf(null, 123L, mapOf("url" to "$prodBase$name"), listOf("$emuBase$name")).forEach {
                assertNull(remoteImageUrlOf(it, policy), "$policy: $it")
            }
        }
    }
}
