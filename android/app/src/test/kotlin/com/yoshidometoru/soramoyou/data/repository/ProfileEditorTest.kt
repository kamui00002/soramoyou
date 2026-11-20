// ⭐️ プロフィールの保存の単体テスト（タスク 16.2・要件 10.6〜10.10）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.contract.document.FsValue
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.data.image.ImagePipeline
import com.yoshidometoru.soramoyou.data.image.JpegSpec
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.data.image.PreparedImage
import com.yoshidometoru.soramoyou.data.image.PreparedPostImage
import com.yoshidometoru.soramoyou.data.model.OwnProfile
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DefaultStorageGateway
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FakeFirestoreWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FakeStorageWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteFailure
import com.yoshidometoru.soramoyou.data.remote.write.FixedWriteGate
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import com.yoshidometoru.soramoyou.data.remote.write.StorageWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.TxClient
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * プロフィールの保存が、変えた項目と `updatedAt` だけを `users` → `publicProfiles` の順に部分更新し、
 * 公開プロフィールの失敗では種類を見ずに有無を確かめてから補完・やり直しをすることを確かめる（設計書 :868-883）。
 *
 * 本物の書き込みの入口（可否 → 形の検証 → 実行 → 記録）と本物の Storage の入口の上で動かし、偽物にするのは
 * SDK への継ぎ目・写真の変換・読み取り・補完だけ。形の検証は本物の契約なので、契約に合わない部分更新は ShapeViolation になる。
 *
 * 本番の書き込み・読み取り・補完は中断できる待ち（Tasks の await）を含むので、取り消された後に取り消さない範囲（NonCancellable）の
 * 外で呼ばれると、そこで止まる。偽物の書き込み（update・set）・読み取り（get）・補完は、記録する前に取り消しを確かめてこれを写す
 * （DefaultPostPublisherTest の削除と同じ形）。これが無いと、範囲を後ろの書き込みの手前まで狭めても取り消しのテストが緑のまま通る。
 */
class ProfileEditorTest {

    private val uid = Uid("UID-1")
    private val now: Instant = Instant.parse("2026-10-07T01:02:03Z")
    private val userPath = "users/UID-1"
    private val profilePath = "publicProfiles/UID-1"
    private val iconPath = "users/UID-1/profile/profile.jpg"

    private val analytics = RecordingAnalytics()
    private val firestore = ScriptedFirestoreClient()
    private val storageClient = FakeStorageWriteClient()
    private val pipeline = FakeImagePipeline()
    private val repairer = FakeRepairer()
    private val inFlight = InFlightWrites()

    private fun current(displayName: String? = "そら", bio: String? = "空が好き") =
        OwnProfile(uid, displayName = displayName, photoUrl = "https://example.com/old.jpg", bio = bio, postsCount = 3L)

    private fun editor(
        reader: FakeFirestoreReader = FakeFirestoreReader(),
        enabled: Set<WriteCapability> = ALL_WRITES_ENABLED,
        storageWriteClient: StorageWriteClient = storageClient,
    ) = DefaultProfileEditor(
        gateway = realWriteGatewayOver(firestore, enabled),
        storage = DefaultStorageGateway(FixedWriteGate(enabled), storageWriteClient, analytics, wait = {}),
        pipeline = pipeline,
        reader = CancellationCheckingReader(reader),
        repairer = repairer,
        analytics = analytics,
        inFlight = inFlight,
        clock = Clock.fixed(now, ZoneOffset.UTC),
    )

    private fun realWriteGatewayOver(client: FirestoreWriteClient, enabled: Set<WriteCapability>) =
        com.yoshidometoru.soramoyou.data.remote.write.DefaultFirestoreWriteGateway(
            FixedWriteGate(enabled),
            com.yoshidometoru.soramoyou.contract.document.AllowListShapeValidator,
            client,
            analytics,
        ) { uid }

    private fun save(edit: ProfileEdit, current: OwnProfile = current(), reader: FakeFirestoreReader = FakeFirestoreReader()) =
        runBlocking { editor(reader).save(edit, current) }

    // ── 何も変えない ──

    @Test
    fun `何も変えずに保存するとFirestoreにもStorageにも書かずにOk`() {
        val result = save(ProfileEdit(displayName = "そら", bio = "空が好き", newIcon = null))

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(emptyList(), firestore.attempts)
        assertEquals(emptyList(), storageClient.calls)
        assertEquals(emptyList(), pipeline.calls)
    }

    @Test
    fun `無い項目を空のまま保存してもupdatedAtだけの更新を書かない`() {
        val result = save(ProfileEdit(displayName = "", bio = "", newIcon = null), current(displayName = null, bio = null))

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(emptyList(), firestore.attempts)
    }

    @Test
    fun `書き込みが無効なビルドでも何も変えなければOkで断りの記録も出さない`() {
        val result = runBlocking {
            editor(enabled = emptySet()).save(ProfileEdit("そら", "空が好き", null), current())
        }

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(emptyList(), analytics.errors)
    }

    // ── 変えた項目だけ ──

    @Test
    fun `表示名だけ変えるとusersとpublicProfilesの順に表示名とupdatedAtだけを部分更新する`() {
        val result = save(ProfileEdit(displayName = "あおぞら", bio = "空が好き", newIcon = null))

        assertEquals(AppResult.Ok(Unit), result)
        val expected = mapOf("updatedAt" to FsValue.Time(now), "displayName" to FsValue.Str("あおぞら"))
        assertEquals(listOf(Attempt(userPath, expected), Attempt(profilePath, expected)), firestore.attempts)
    }

    @Test
    fun `自己紹介だけ変えると自己紹介とupdatedAtだけを書く`() {
        save(ProfileEdit(displayName = "そら", bio = "夕焼けも好き", newIcon = null))

        assertEquals(
            mapOf("updatedAt" to FsValue.Time(now), "bio" to FsValue.Str("夕焼けも好き")),
            firestore.attempts.first().fields,
        )
    }

    @Test
    fun `空にした項目はキーの削除として書く`() {
        save(ProfileEdit(displayName = "", bio = "空が好き", newIcon = null))

        assertEquals(
            mapOf("updatedAt" to FsValue.Time(now), "displayName" to FsValue.DeleteField),
            firestore.attempts.first().fields,
        )
    }

    @Test
    fun `全角空白だけの自己紹介は空と同じく削除として書く`() {
        // 設計書 :623「空白だけかどうかの判定では、全角空白を含むUnicodeの空白を取り除く」。iOS は空白だけでも保存する（差）
        val result = save(ProfileEdit(displayName = "そら", bio = "　 　", newIcon = null))

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(
            mapOf("updatedAt" to FsValue.Time(now), "bio" to FsValue.DeleteField),
            firestore.attempts.first().fields,
        )
    }

    @Test
    fun `前後の空白は取り除かずにそのまま書く`() {
        save(ProfileEdit(displayName = " そら ", bio = "空が好き", newIcon = null))

        assertEquals(FsValue.Str(" そら "), firestore.attempts.first().fields["displayName"])
    }

    @Test
    fun `書き込みはupdateだけでsetもトランザクションも使わない`() {
        // 部分更新（要件 10.6）。set だと id・カウンタなどの他の項目が消える
        save(ProfileEdit(displayName = "あおぞら", bio = "", newIcon = null))

        assertEquals(listOf("update", "update"), firestore.inner.calls.map { it.operation })
    }

    // ── 入力の上限 ──

    @Test
    fun `表示名は書記素で50までなら保存できる`() {
        // ZWJ でつないだ家族の絵文字は 1 文字（iOS の String.count と同じ数え方）
        val fifty = "👨‍👩‍👧".repeat(50)

        assertEquals(AppResult.Ok(Unit), save(ProfileEdit(displayName = fifty, bio = "空が好き", newIcon = null)))
    }

    @Test
    fun `表示名が51文字なら何も書かずに入力の不備を返す`() {
        val result = save(ProfileEdit(displayName = "あ".repeat(51), bio = "空が好き", newIcon = Photo))

        assertEquals(AppResult.Err(AppError.Validation(ValidationReason.DISPLAY_NAME_TOO_LONG)), result)
        assertEquals(emptyList(), firestore.attempts)
        assertEquals(emptyList(), pipeline.calls)
    }

    @Test
    fun `自己紹介が201文字なら何も書かずに入力の不備を返す`() {
        val result = save(ProfileEdit(displayName = "そら", bio = "あ".repeat(201), newIcon = null))

        assertEquals(AppResult.Err(AppError.Validation(ValidationReason.BIO_TOO_LONG)), result)
        assertEquals(emptyList(), firestore.attempts)
    }

    @Test
    fun `いまの値から変えていない表示名は上限を超えていても止めず、自己紹介とupdatedAtだけを書く`() {
        // iOS より多く数える古い端末で、iOS で上限ちょうどにした表示名を読んだときの形（全体レビュー 4 回目 R21 の利用者の決定）
        val longName = "あ".repeat(51)

        val result = save(ProfileEdit(displayName = longName, bio = "夕焼けも好き", newIcon = null), current(displayName = longName))

        assertEquals(AppResult.Ok(Unit), result)
        val expected = mapOf("updatedAt" to FsValue.Time(now), "bio" to FsValue.Str("夕焼けも好き"))
        assertEquals(listOf(Attempt(userPath, expected), Attempt(profilePath, expected)), firestore.attempts)
    }

    @Test
    fun `いまの値から変えていない自己紹介は上限を超えていても止めない`() {
        val longBio = "あ".repeat(201)

        val result = save(ProfileEdit(displayName = "あおぞら", bio = longBio, newIcon = null), current(bio = longBio))

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(
            mapOf("updatedAt" to FsValue.Time(now), "displayName" to FsValue.Str("あおぞら")),
            firestore.attempts.first().fields,
        )
    }

    @Test
    fun `上限を超えた値から変えた値がまだ上限を超えていれば止める`() {
        val result = save(ProfileEdit(displayName = "あ".repeat(51), bio = "空が好き", newIcon = null), current(displayName = "あ".repeat(52)))

        assertEquals(AppResult.Err(AppError.Validation(ValidationReason.DISPLAY_NAME_TOO_LONG)), result)
        assertEquals(emptyList(), firestore.attempts)
    }

    @Test
    fun `上限を超えた表示名を空にして消すのは止めない`() {
        val result = save(ProfileEdit(displayName = "", bio = "空が好き", newIcon = null), current(displayName = "あ".repeat(51)))

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(
            mapOf("updatedAt" to FsValue.Time(now), "displayName" to FsValue.DeleteField),
            firestore.attempts.first().fields,
        )
    }

    // ── アイコン ──

    @Test
    fun `アイコンは長辺1024px・品質90で変換してiOSと同じパスへ上げ、そのURLをphotoURLに書く`() {
        val result = save(ProfileEdit(displayName = "そら", bio = "空が好き", newIcon = Photo))

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(Photo to JpegSpec.ICON), pipeline.calls)
        assertEquals(listOf("put", "downloadUrl"), storageClient.calls.map { it.operation })
        assertEquals(iconPath, storageClient.calls.first().path)
        assertEquals(pipeline.output.body.size, storageClient.calls.first().size)
        val expected = mapOf("updatedAt" to FsValue.Time(now), "photoURL" to FsValue.Str(FakeStorageWriteClient.urlOf(iconPath)))
        assertEquals(listOf(Attempt(userPath, expected), Attempt(profilePath, expected)), firestore.attempts)
    }

    @Test
    fun `写真を読めなければ上げも書きもせずに失敗を返して記録する`() {
        pipeline.result = AppResult.Err(AppError.ImageUnreadable(0))

        val result = save(ProfileEdit(displayName = "あおぞら", bio = "空が好き", newIcon = Photo))

        assertEquals(AppResult.Err(AppError.ImageUnreadable(0)), result)
        assertEquals(emptyList(), storageClient.calls)
        assertEquals(emptyList(), firestore.attempts)
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.ImageUnreadable(0), "ProfileEditor.save.icon")), analytics.errors)
    }

    @Test
    fun `アップロードに失敗したらFirestoreに書かずに失敗を返し1回だけ記録する`() {
        storageClient.failOn = "put"

        val result = save(ProfileEdit(displayName = "あおぞら", bio = "空が好き", newIcon = Photo))

        assertIs<AppResult.Err>(result)
        assertEquals(emptyList(), firestore.attempts)
        assertEquals(listOf(result.error to "ProfileEditor.save.upload"), analytics.errors.map { it.error to it.context })
    }

    @Test
    fun `入口が断った大きすぎる画像は入口の記録だけで二重に記録しない`() {
        // 変換は 5MB 未満を保証するが、入口（最後の砦）が断った場合の記録の数を固定する
        pipeline.output = PreparedImage(ByteArray(5 * 1024 * 1024), 1024, 1024)

        val result = save(ProfileEdit(displayName = "そら", bio = "空が好き", newIcon = Photo))

        assertEquals(AppResult.Err(AppError.ImageTooLarge(0, 5L * 1024 * 1024)), result)
        assertEquals(1, analytics.errors.size)
        assertEquals("StorageGateway.uploadJpeg", analytics.errors.single().context)
    }

    // ── users の失敗 ──

    @Test
    fun `usersの更新に失敗したらpublicProfilesを書かずに失敗を返して記録する`() {
        firestore.failures += AppError.Network

        val result = save(ProfileEdit(displayName = "あおぞら", bio = "空が好き", newIcon = null))

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(listOf(userPath), firestore.attempts.map { it.path })
        assertEquals(listOf(RecordingAnalytics.LoggedError(AppError.Network, "ProfileEditor.save.users")), analytics.errors)
    }

    @Test
    fun `書き込みが無効なビルドではWriteBlockedを返し入口の記録だけにする`() {
        val result = runBlocking {
            editor(enabled = emptySet()).save(ProfileEdit("あおぞら", "空が好き", null), current())
        }

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.PROFILE_EDIT)), result)
        assertEquals(1, analytics.errors.size)
    }

    // ── publicProfiles の失敗 ──

    @Test
    fun `publicProfilesの失敗では種類を見ずにサーバーから有無を確かめ、あれば失敗を返して補完しない`() {
        firestore.failures += listOf(null, AppError.PermissionDenied)
        val reader = FakeFirestoreReader(documents = mapOf(profilePath to AppResult.Ok(RawDocument("UID-1", mapOf("id" to "UID-1")))))

        val result = save(ProfileEdit("あおぞら", "空が好き", null), reader = reader)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(listOf(profilePath to ReadSource.SERVER), reader.gets.map { it.first.path to it.second })
        assertEquals(0, repairer.calls)
        assertEquals(listOf(userPath, profilePath), firestore.attempts.map { it.path })
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "ProfileEditor.save.publicProfiles")),
            analytics.errors,
        )
    }

    @Test
    fun `有無の確認に失敗したら元の失敗を返して補完しない`() {
        firestore.failures += listOf(null, AppError.Unknown("x"))
        val reader = FakeFirestoreReader(documents = mapOf(profilePath to AppResult.Err(AppError.Network)))

        val result = save(ProfileEdit("あおぞら", "空が好き", null), reader = reader)

        assertEquals(AppResult.Err(AppError.Unknown("x")), result)
        assertEquals(0, repairer.calls)
    }

    @Test
    fun `publicProfilesが無ければ補完してから同じ内容で1回だけやり直す`() {
        // 失敗の種類は NotFound に限らない（種類で判断しない）。ここでは権限の拒否で返ってきた場合
        firestore.failures += listOf(null, AppError.PermissionDenied)

        val result = save(ProfileEdit("あおぞら", "空が好き", null))

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(1, repairer.calls)
        assertEquals(listOf(userPath, profilePath, profilePath), firestore.attempts.map { it.path })
        // やり直しも同じ内容（時刻を読み直さない）
        assertEquals(firestore.attempts[1].fields, firestore.attempts[2].fields)
    }

    @Test
    fun `やり直しも失敗したらそれを返し、もう確かめも補完もしない`() {
        firestore.failures += listOf(null, AppError.NotFound, AppError.Network)
        val reader = FakeFirestoreReader()

        val result = save(ProfileEdit("あおぞら", "空が好き", null), reader = reader)

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(1, repairer.calls)
        assertEquals(1, reader.gets.size)
        assertEquals(3, firestore.attempts.size)
    }

    @Test
    fun `補完に失敗したらその失敗を返し、やり直さず、記録もし直さない`() {
        firestore.failures += listOf(null, AppError.NotFound)
        repairer.result = AppResult.Err(AppError.Network)

        val result = save(ProfileEdit("あおぞら", "空が好き", null))

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(2, firestore.attempts.size)
        // 記録は publicProfiles の最初の失敗の 1 件だけ（補完の失敗は補完が自分で記録する）
        assertEquals(listOf(AppError.NotFound), analytics.errors.map { it.error })
    }

    // ── 取り消し（レビュー R03）──

    @Test
    fun `usersの更新を待っている間に呼び出し側が取り消されても、publicProfilesの更新まで届く`() = runBlocking {
        // 保存中に「キャンセル」や戻るで画面を離れると、呼び出し側（ViewModel の scope）が取り消される。users だけ書いて止まると
        // publicProfiles が古いまま残り、比べる元が users なので同じ値で保存し直しても「変えていない」で直らない
        val release = CompletableDeferred<Unit>()
        firestore.holds[userPath] = release
        val job = launch(Dispatchers.Unconfined) { editor().save(ProfileEdit("あおぞら", "空が好き", null), current()) }
        try {
            // users の更新の応答を待って止まっている（publicProfiles はまだ）
            assertEquals(listOf(userPath), firestore.attempts.map { it.path })
            job.cancel()
        } finally {
            // 上の確かめが失敗しても待ちを外す（保存の後半は取り消さないので、外さないと runBlocking が子を待ち続けて止まる）
            release.complete(Unit)
        }
        job.join()

        val expected = mapOf("updatedAt" to FsValue.Time(now), "displayName" to FsValue.Str("あおぞら"))
        assertEquals(listOf(Attempt(userPath, expected), Attempt(profilePath, expected)), firestore.attempts)
    }

    @Test
    fun `アイコンの送信を待っている間に呼び出し側が取り消されても、usersとpublicProfilesの更新まで届く`() = runBlocking {
        // 送信の途中で止まると、profile.jpg だけが上書きされて photoURL が変わらない
        val release = CompletableDeferred<Unit>()
        val holding = object : StorageWriteClient by storageClient {
            override suspend fun put(path: String, bytes: ByteArray, contentType: String) {
                storageClient.put(path, bytes, contentType)
                release.await()
            }
        }
        val job = launch(Dispatchers.Unconfined) {
            editor(storageWriteClient = holding).save(ProfileEdit("そら", "空が好き", Photo), current())
        }
        try {
            // 送信の応答を待って止まっている（Firestore にはまだ書いていない）
            assertEquals(listOf("put"), storageClient.calls.map { it.operation })
            assertEquals(emptyList(), firestore.attempts)
            job.cancel()
        } finally {
            // 上の確かめが失敗しても待ちを外す（保存の後半は取り消さないので、外さないと runBlocking が子を待ち続けて止まる）
            release.complete(Unit)
        }
        job.join()

        val expected = mapOf("updatedAt" to FsValue.Time(now), "photoURL" to FsValue.Str(FakeStorageWriteClient.urlOf(iconPath)))
        assertEquals(listOf(Attempt(userPath, expected), Attempt(profilePath, expected)), firestore.attempts)
    }

    @Test
    fun `usersの更新を待っている間に呼び出し側が取り消されても、publicProfilesが無いときの確かめ・補完・やり直しまで届く`() = runBlocking {
        // 補完の枝（有無の確かめ → 補完 → やり直し）も取り消さない範囲の中にある。枝だけ外へ出すと、確かめの手前で止まって
        // publicProfiles が無いまま残る（最初の publicProfiles の更新までは届くので、上の 2 本では気づかない）
        firestore.failures += listOf(null, AppError.PermissionDenied)
        val reader = FakeFirestoreReader()
        val release = CompletableDeferred<Unit>()
        firestore.holds[userPath] = release
        val job = launch(Dispatchers.Unconfined) { editor(reader).save(ProfileEdit("あおぞら", "空が好き", null), current()) }
        try {
            // users の更新の応答を待って止まっている（publicProfiles はまだ）
            assertEquals(listOf(userPath), firestore.attempts.map { it.path })
            job.cancel()
        } finally {
            // 上の確かめが失敗しても待ちを外す（保存の後半は取り消さないので、外さないと runBlocking が子を待ち続けて止まる）
            release.complete(Unit)
        }
        job.join()

        // 戻り値は見ない（取り消した job は、中身が最後まで走っても取り消しで終わる）。書いた・読んだことだけを見る
        assertEquals(listOf(profilePath to ReadSource.SERVER), reader.gets.map { it.first.path to it.second })
        assertEquals(1, repairer.calls)
        assertEquals(listOf(userPath, profilePath, profilePath), firestore.attempts.map { it.path })
    }

    // ── ログアウトとの調整（全体レビュー 4 回目 Q03）──

    @Test
    fun `アイコンの送信からpublicProfilesの更新までを、走っている書き込みとして数える（ログアウトが終わりを待つ）`() = runBlocking {
        // ログアウトはこの数が 0 になるのを待ってからセッションを破棄する。数える範囲が取り消さない範囲より狭いと、その外の段
        // （users・publicProfiles の更新）がログアウトの後に未ログインとして断られ、R03 と同じ崩れが残る
        val iconRelease = CompletableDeferred<Unit>()
        val profileRelease = CompletableDeferred<Unit>()
        firestore.holds[profilePath] = profileRelease
        val holding = object : StorageWriteClient by storageClient {
            override suspend fun put(path: String, bytes: ByteArray, contentType: String) {
                storageClient.put(path, bytes, contentType)
                iconRelease.await()
            }
        }
        val job = launch(Dispatchers.Unconfined) {
            editor(storageWriteClient = holding).save(ProfileEdit("あおぞら", "空が好き", Photo), current())
        }
        try {
            // 最初の段：アイコンの送信の応答を待っている（Firestore にはまだ書いていない）
            assertEquals(listOf("put"), storageClient.calls.map { it.operation })
            assertTrue(inFlight.isBusy())
            iconRelease.complete(Unit)
            // 最後の段：publicProfiles の更新の応答を待っている（users は書いた）
            assertEquals(listOf(userPath, profilePath), firestore.attempts.map { it.path })
            assertTrue(inFlight.isBusy())
        } finally {
            // 上の確かめが失敗しても待ちを外す（保存の後半は取り消さないので、外さないと runBlocking が子を待ち続けて止まる）
            iconRelease.complete(Unit)
            profileRelease.complete(Unit)
        }
        job.join()

        assertFalse(inFlight.isBusy())
    }

    // ── 保存の段（全体レビュー 4 回目 Q04・Q05）──

    @Test
    fun `保存の段は、アイコンの送信中は送信中、usersとpublicProfilesの書き込み中は保存中で、終われば戻す`() = runBlocking {
        // 画面はこれを見て、前に開いた画面で始めた保存が終わるまで保存を押せなくし（Q04）、オフラインの案内を段で分ける（Q05：送信は
        // 接続が切れると再試行の上限で失敗して保存が終わるが、Firestore の書き込みは接続が戻るのを待って続く）
        val iconRelease = CompletableDeferred<Unit>()
        val userRelease = CompletableDeferred<Unit>()
        firestore.holds[userPath] = userRelease
        val holding = object : StorageWriteClient by storageClient {
            override suspend fun put(path: String, bytes: ByteArray, contentType: String) {
                storageClient.put(path, bytes, contentType)
                iconRelease.await()
            }
        }
        val profileEditor = editor(storageWriteClient = holding)
        assertEquals(ProfileSaveStage.IDLE, profileEditor.state.value)
        val job = launch(Dispatchers.Unconfined) { profileEditor.save(ProfileEdit("あおぞら", "空が好き", Photo), current()) }
        try {
            // 最初の段：アイコンの送信の応答を待っている（Firestore にはまだ書いていない）
            assertEquals(listOf("put"), storageClient.calls.map { it.operation })
            assertEquals(ProfileSaveStage.UPLOADING_ICON, profileEditor.state.value)
            iconRelease.complete(Unit)
            // 次の段：users の更新の応答を待っている
            assertEquals(listOf(userPath), firestore.attempts.map { it.path })
            assertEquals(ProfileSaveStage.SAVING, profileEditor.state.value)
        } finally {
            // 上の確かめが失敗しても待ちを外す（保存の後半は取り消さないので、外さないと runBlocking が子を待ち続けて止まる）
            iconRelease.complete(Unit)
            userRelease.complete(Unit)
        }
        job.join()

        assertEquals(listOf(userPath, profilePath), firestore.attempts.map { it.path })
        assertEquals(ProfileSaveStage.IDLE, profileEditor.state.value)
    }

    @Test
    fun `送信や書き込みに失敗して終わっても、保存の段を戻す`() = runBlocking {
        // 戻さないと、次に開いた編集画面がいつまでも保存を押せない
        val profileEditor = editor()
        storageClient.failOn = "put"
        assertIs<AppResult.Err>(profileEditor.save(ProfileEdit("あおぞら", "空が好き", Photo), current()))
        assertEquals(ProfileSaveStage.IDLE, profileEditor.state.value)

        storageClient.failOn = null
        firestore.failures += AppError.Network
        assertEquals(AppResult.Err(AppError.Network), profileEditor.save(ProfileEdit("あおぞら", "空が好き", null), current()))
        assertEquals(ProfileSaveStage.IDLE, profileEditor.state.value)
    }

    // ── 偽物 ──

    private data class Attempt(val path: String, val fields: FsDocument)

    /**
     * 本物の入口の下に置く継ぎ目。update を試みた順に記録し、[failures] の先頭から 1 つずつ取り出して、
     * null なら [inner] に通し、そうでなければその失敗を投げる（SDK の失敗を入口が写したときと同じ形）。
     * update・set は、記録する前に取り消しを確かめる（取り消さない範囲の外で呼ばれたら、試みとして残らない）。
     */
    private class ScriptedFirestoreClient(val inner: FakeFirestoreWriteClient = FakeFirestoreWriteClient()) : FirestoreWriteClient by inner {
        val attempts = mutableListOf<Attempt>()
        val failures = ArrayDeque<AppError?>()

        /** パスごとに、試みを記録した後でこの値が完了するまで応答しない（取り消しのテスト用。レビュー R03）。 */
        val holds = mutableMapOf<String, CompletableDeferred<Unit>>()

        override suspend fun update(path: String, data: FsDocument) {
            currentCoroutineContext().ensureActive()
            attempts += Attempt(path, data)
            holds[path]?.await()
            val failure = failures.removeFirstOrNull()
            if (failure != null) throw FirestoreWriteFailure(failure, IllegalStateException("偽物の失敗"))
            inner.update(path, data)
        }

        override suspend fun set(path: String, data: FsDocument) {
            currentCoroutineContext().ensureActive()
            attempts += Attempt(path, data)
            inner.set(path, data)
        }

        override suspend fun <T> runTransaction(block: suspend TxClient.() -> T): T {
            attempts += Attempt("runTransaction", emptyMap())
            return inner.runTransaction(block)
        }
    }

    private class FakeImagePipeline : ImagePipeline {
        val calls = mutableListOf<Pair<PickedPhoto, JpegSpec>>()
        var output = PreparedImage(ByteArray(1234), 1024, 768)
        var result: AppResult<PreparedImage>? = null

        override suspend fun prepare(photo: PickedPhoto, spec: JpegSpec): AppResult<PreparedImage> {
            calls += photo to spec
            return result ?: AppResult.Ok(output)
        }

        override suspend fun preparePost(photo: PickedPhoto, edit: PhotoEdit): AppResult<PreparedPostImage> =
            error("プロフィールの保存は投稿用の変換を使わない")
    }

    /** 補完の偽物。呼ばれた回数を数える前に取り消しを確かめる（本物の補完は読み書きの待ちを含む）。 */
    private class FakeRepairer : AccountDocumentRepairer {
        var calls = 0
        var result: AppResult<RepairOutcome> = AppResult.Ok(RepairOutcome.CREATED_PUBLIC_PROFILE)

        override suspend fun ensureAccountDocuments(): AppResult<RepairOutcome> {
            currentCoroutineContext().ensureActive()
            calls++
            return result
        }
    }

    /** 読み取りの偽物 [inner] の get の前で取り消しを確かめる（本物の get はサーバーの応答を待つ）。記録は [inner] が持つ。 */
    private class CancellationCheckingReader(private val inner: FakeFirestoreReader) : FirestoreReader by inner {
        override suspend fun get(ref: DocRef, source: ReadSource): AppResult<RawDocument?> {
            currentCoroutineContext().ensureActive()
            return inner.get(ref, source)
        }
    }

    private companion object {
        val Photo = PickedPhoto(uri = "content://media/picker/0/1", index = 0)
    }
}
