// ⭐️ 端末の保存を、実際の noBackupFilesDir で通す（Kiro android-edit-tools タスク 14.5・A4・design.md:1153・要件 7.8・8.6・8.15）
package com.yoshidometoru.soramoyou.data.edit

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.edit.EditWorkDocument
import com.yoshidometoru.soramoyou.contract.edit.EditWorkPhoto
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.data.image.AndroidImageCodec
import com.yoshidometoru.soramoyou.data.image.AndroidPhotoMetadataSource
import com.yoshidometoru.soramoyou.data.image.CapturedAtSource
import com.yoshidometoru.soramoyou.data.image.DefaultPhotoMetadataReader
import com.yoshidometoru.soramoyou.data.image.ImageSize
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import com.yoshidometoru.soramoyou.platform.ScreenName
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * JVM の単体テストは一時のフォルダで確かめるので、本番の置き場（[EditFileStore.forApp]）と、写真選択画面の URI から本物の ContentResolver で
 * 開いて写す道は、端末で確かめる。Firebase のエミュレータは使わない（AVD だけ）。実行は
 * `./gradlew :app:connectedEmulatorDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.yoshidometoru.soramoyou.data.edit.EditFilesDeviceTest`。
 *
 * 1. 写し→途中の保存→読み直し→下書き→開く→削除が通り、写し・下書きの写真・見本が全部 `noBackupFilesDir` の下にある
 *    （バックアップ・機種変更で引き継がず、消されうる場所〔cacheDir〕でもない：7.8・8.15。design.md:1153）
 * 2. 写しのファイルから、EXIF の向きと画素を読める（バイトのまま写す：利用者の判断 U5。元の写真の読む許可が切れても続きができる：8.6）
 *
 * 陽性対照：[EditFileStore.forApp] の `context.noBackupFilesDir` を `context.cacheDir` にすると、どちらのテストも
 * 「noBackupFilesDir の下にある」の確かめで失敗する。テストの利用者は毎回新しい uid で、終わったらその利用者のフォルダを消す
 * （装備のファイルなど、ほかの置き場には触れない）。
 */
@RunWith(AndroidJUnit4::class)
class EditFilesDeviceTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val files = EditFileStore.forApp(context)
    private val uid = Uid("editFilesDeviceTest" + UUID.randomUUID().toString().replace("-", ""))
    private val errors = DeviceTestErrors()
    private val sourceDir = File(context.cacheDir, "edit-files-device-test").apply { mkdirs() }
    private val codec = AndroidImageCodec(context.contentResolver)
    private val importer = DefaultWorkingPhotoImporter(
        files,
        context.contentResolver,
        DefaultPhotoMetadataReader(AndroidPhotoMetadataSource(context.contentResolver)),
        errors,
    )
    private val sessions = DefaultEditSessionStore(files, errors)
    private val drafts = DefaultLocalDraftRepository(files, errors)

    @After
    fun cleanUp() {
        sourceDir.deleteRecursively()
        files.userDir(uid).deleteRecursively()
    }

    // ── 1. 写しから削除まで ──

    @Test
    fun 写しから途中の保存_読み直し_下書き_開く_削除までが_noBackupFilesDirの中で通る() = runBlocking {
        val sources = listOf(writeOrientedJpeg("exif6.jpg"), writePlainPng("plain.png"))
        val picked = sources.mapIndexed { index, file -> PickedPhoto(Uri.fromFile(file).toString(), index) }

        // 写し
        val photos = importer.import(uid, picked)
        assertEquals(listOf("session/photo-0", "session/photo-1"), photos.map { it.relativeFile })
        for ((index, photo) in photos.withIndex()) {
            val copy = fileOf(photo.uri)
            assertUnderNoBackup("写し $index", copy)
            assertArrayEquals("写し $index はバイトのまま", sources[index].readBytes(), copy.readBytes())
        }
        assertEquals("1 枚目の撮影日時は EXIF から", CapturedAtSource.EXIF, photos[0].capturedAt?.source)
        assertNull("2 枚目の撮影日時は読まない", photos[1].capturedAt)

        // 途中の保存→読み直し
        val document = EditWorkDocument(
            sessionId = "SESSION-DEVICE",
            draftId = null,
            savedAtEpochMillis = 1_794_400_000_000L,
            caption = "端末の確かめ #空",
            visibilityRaw = "public",
            enteredInfo = false,
            photos = photos.mapIndexed { index, photo ->
                EditWorkPhoto(
                    file = checkNotNull(photo.relativeFile),
                    capturedAtEpochMillis = photo.capturedAt?.instant?.toEpochMilli(),
                    capturedAtSourceRaw = photo.capturedAt?.source?.raw ?: CapturedAtSource.NONE.raw,
                    edit = if (index == 0) PhotoEdit(filter = FilterId.WARM) else PhotoEdit.NONE,
                )
            },
        )
        assertEquals(AppResult.Ok(Unit), sessions.save(uid, document))
        val restored = sessions.load(uid)
        check(restored is SessionLoad.Restored) { "途中を読み直せない: $restored" }
        assertEquals(document, restored.document)
        assertEquals(photos.map { it.uri }, restored.photos.map { it.uri })
        assertEquals(
            photos.map { it.capturedAt?.instant?.toEpochMilli() },
            restored.photos.map { it.capturedAt?.instant?.toEpochMilli() },
        )

        // 下書き
        val saved = drafts.save(uid, document, sources[0].readBytes())
        check(saved is DraftSaveResult.Saved) { "下書きを保存できない: $saved" }
        val id = saved.id
        val summary = drafts.list(uid).single()
        assertEquals(id, summary.id)
        assertFalse(summary.isBroken)
        assertEquals(2, summary.photoCount)
        assertUnderNoBackup("下書きの見本", fileOf(checkNotNull(summary.thumbnailUri)))
        for (photo in photos) assertTrue("下書きに写した後も写しは残る", fileOf(photo.uri).isFile)

        // 開く
        val opened = drafts.open(uid, id)
        check(opened is DraftOpenResult.Opened) { "下書きを開けない: $opened" }
        assertEquals(id.value, opened.document.draftId)
        for ((index, photo) in opened.photos.withIndex()) {
            val draftPhoto = fileOf(photo.uri)
            assertUnderNoBackup("下書きの写真 $index", draftPhoto)
            assertArrayEquals("下書きの写真 $index はバイトのまま", sources[index].readBytes(), draftPhoto.readBytes())
        }
        assertEquals(ExifInterface.ORIENTATION_ROTATE_90, codec.readExifOrientation(opened.photos[0].uri))
        val reopened = sessions.load(uid)
        assertTrue("開いた後の途中は下書きを指す: $reopened", reopened is SessionLoad.Restored && reopened.document.draftId == id.value)

        // 削除
        assertEquals(AppResult.Ok(Unit), drafts.delete(uid, id))
        assertEquals(emptyList<LocalDraftSummary>(), drafts.list(uid))
        assertFalse("下書きのフォルダが消える", File(files.draftsDir(uid), id.value).exists())
        assertFalse("開いていた下書きの途中も消える", files.sessionDir(uid).exists())

        assertEquals("記録された失敗", emptyList<Pair<AppError, String>>(), errors.errors)
    }

    // ── 2. 写しから向きと画素を読める ──

    @Test
    fun 写しのファイルから_EXIFの向きと画素を読める() = runBlocking {
        val source = writeOrientedJpeg("exif6.jpg")

        val photo = importer.import(uid, listOf(PickedPhoto(Uri.fromFile(source).toString(), 0))).single()

        assertNotNull("写せた", photo.relativeFile)
        assertUnderNoBackup("写し", fileOf(photo.uri))
        // 元の写真を消しても、写しから読める（写真選択画面の読む許可が切れた後と同じ：8.6）
        assertTrue(source.delete())
        assertEquals(ExifInterface.ORIENTATION_ROTATE_90, codec.readExifOrientation(photo.uri))
        assertEquals(ImageSize(WIDTH, HEIGHT), codec.readSize(photo.uri))
        val decoded = checkNotNull(codec.decode(photo.uri, 1))
        try {
            val pixels = codec.readPixels(decoded)
            // 保存された画素の並びのまま（向きは EXIF に残り、画素は回していない）。隅から 10px 内側で見る
            assertNear("左上", Color.RED, pixels[10 * WIDTH + 10])
            assertNear("右上", Color.GREEN, pixels[10 * WIDTH + (WIDTH - 11)])
            assertNear("左下", Color.BLUE, pixels[(HEIGHT - 11) * WIDTH + 10])
            assertNear("右下", Color.WHITE, pixels[(HEIGHT - 11) * WIDTH + (WIDTH - 11)])
        } finally {
            codec.release(decoded)
        }
        assertEquals("記録された失敗", emptyList<Pair<AppError, String>>(), errors.errors)
    }

    // ── 道具 ──

    /** 写しは本番の置き場（noBackupFilesDir）の下にある。cacheDir などに置くと失敗する（陽性対照で見る所） */
    private fun assertUnderNoBackup(what: String, file: File) {
        val root = context.noBackupFilesDir.canonicalPath + File.separator
        assertTrue("$what は noBackupFilesDir の下にある", file.canonicalPath.startsWith(root))
        assertTrue("$what のファイルがある", file.isFile)
    }

    private fun fileOf(uri: String): File {
        val parsed = Uri.parse(uri)
        assertEquals("file の URI", "file", parsed.scheme)
        return File(checkNotNull(parsed.path))
    }

    /**
     * 300×200 の JPEG（左上 赤・右上 緑・左下 青・右下 白）に、EXIF の向き 6（時計回りに 90 度回して見る）と撮影日時を付ける。
     * 写真選択画面で選んだ元の写真の代わり（file の URI で開く）
     */
    private fun writeOrientedJpeg(name: String): File {
        val bitmap = Bitmap.createBitmap(WIDTH, HEIGHT, Bitmap.Config.ARGB_8888)
        val paint = Paint()
        val halfWidth = WIDTH / 2f
        val halfHeight = HEIGHT / 2f
        Canvas(bitmap).apply {
            for ((rect, color) in listOf(
                floatArrayOf(0f, 0f, halfWidth, halfHeight) to Color.RED,
                floatArrayOf(halfWidth, 0f, WIDTH.toFloat(), halfHeight) to Color.GREEN,
                floatArrayOf(0f, halfHeight, halfWidth, HEIGHT.toFloat()) to Color.BLUE,
                floatArrayOf(halfWidth, halfHeight, WIDTH.toFloat(), HEIGHT.toFloat()) to Color.WHITE,
            )) {
                paint.color = color
                drawRect(rect[0], rect[1], rect[2], rect[3], paint)
            }
        }
        val file = File(sourceDir, name)
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        bitmap.recycle()
        ExifInterface(file).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2026:10:09 07:30:00")
            setAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL, "+09:00")
            saveAttributes()
        }
        return file
    }

    /** EXIF の無い 64×48 の青い PNG */
    private fun writePlainPng(name: String): File {
        val bitmap = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).drawColor(Color.BLUE)
        val file = File(sourceDir, name)
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        return file
    }

    /** JPEG の誤差を許して、色が近いか */
    private fun assertNear(what: String, expected: Int, actual: Int) {
        val near = abs(Color.red(expected) - Color.red(actual)) <= TOLERANCE &&
            abs(Color.green(expected) - Color.green(actual)) <= TOLERANCE &&
            abs(Color.blue(expected) - Color.blue(actual)) <= TOLERANCE
        assertTrue("$what の色: 期待 #${Integer.toHexString(expected)} 実測 #${Integer.toHexString(actual)}", near)
    }

    /** 記録（logError）だけを控える分析の窓口の偽物（JVM の単体テストの偽物は端末のテストから見えないので、ここに置く） */
    private class DeviceTestErrors : AnalyticsFacade {
        val errors = mutableListOf<Pair<AppError, String>>()
        override fun logEvent(name: EventName, params: Map<String, ParamValue>) = Unit
        override fun logScreen(name: ScreenName) = Unit
        override fun logError(error: AppError, context: String) {
            errors += error to context
        }
        override fun setUserId(uid: Uid?) = Unit
    }

    private companion object {
        const val WIDTH = 300
        const val HEIGHT = 200

        /** JPEG（品質 95）の色の誤差の許容 */
        const val TOLERANCE = 8
    }
}
