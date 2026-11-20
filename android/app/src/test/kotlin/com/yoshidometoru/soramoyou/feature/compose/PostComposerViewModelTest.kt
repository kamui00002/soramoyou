// ⭐️ 投稿の作成の画面の状態の単体テスト（タスク 21.1・21.2・23.5・要件 6.4〜6.9・7.5・7.6・7.8・7.9・7.21・7.22・15.4・15.8。Kiro android-edit-tools I1〔18.2〜18.4〕）
package com.yoshidometoru.soramoyou.feature.compose

import androidx.lifecycle.SavedStateHandle
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.CropMath
import com.yoshidometoru.soramoyou.contract.edit.EditGeometry
import com.yoshidometoru.soramoyou.contract.edit.EditHistory
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.EditWorkDocument
import com.yoshidometoru.soramoyou.contract.edit.EditWorkPhoto
import com.yoshidometoru.soramoyou.contract.edit.Loadout
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.edit.ToolValues
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.edit.DraftId
import com.yoshidometoru.soramoyou.data.edit.DraftOpenResult
import com.yoshidometoru.soramoyou.data.edit.DraftSaveResult
import com.yoshidometoru.soramoyou.data.edit.FakeEditSessionStore
import com.yoshidometoru.soramoyou.data.edit.FakeLoadoutStore
import com.yoshidometoru.soramoyou.data.edit.FakeLocalDraftRepository
import com.yoshidometoru.soramoyou.data.edit.FakeWorkingPhotoImporter
import com.yoshidometoru.soramoyou.data.edit.LocalDraftSummary
import com.yoshidometoru.soramoyou.data.edit.SessionLoad
import com.yoshidometoru.soramoyou.data.edit.WorkingPhoto
import com.yoshidometoru.soramoyou.data.image.CapturedAt
import com.yoshidometoru.soramoyou.data.image.CapturedAtSource
import com.yoshidometoru.soramoyou.data.image.EditPreviewRenderer
import com.yoshidometoru.soramoyou.data.image.FakeEditPreviewRenderer
import com.yoshidometoru.soramoyou.data.image.PhotoProbe
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.data.image.PreviewBase
import com.yoshidometoru.soramoyou.data.repository.PostDraft
import com.yoshidometoru.soramoyou.data.repository.PostPhoto
import com.yoshidometoru.soramoyou.data.repository.PostPublisher
import com.yoshidometoru.soramoyou.data.repository.PublishState
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.afterProcessDeath
import com.yoshidometoru.soramoyou.feature.immediateScope
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.EventName
import com.yoshidometoru.soramoyou.platform.ParamValue
import com.yoshidometoru.soramoyou.platform.ScreenName
import java.io.File
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * 選んだ写真を 1 枚ずつ確かめて読めない写真を外すこと、フィルターの置き換えと「なし」、3 段の行き来、画面名の送り方、
 * 投稿情報の段の上限・投稿の結果・進み具合の拾い方を確かめる。
 * 陽性対照は手元の台本（git の外。改変ごとに、狙ったテストだけが赤になることを確かめた）。
 * 投稿の失敗の消し方（レビュー Q07）と、プロセスが落ちて作り直したときに残す入力（全体レビュー 4 回目 Q09）の陽性対照も同じ。
 * 写真ごとの編集・プレビュー・装備・途中の保存と作り直し・離れるときの確かめ・下書き・投稿の後始末（Kiro android-edit-tools I1）は、
 * 「写真ごとの編集」より下の節。陽性対照の壊し方は tasks.md の 18.2〜18.4 の記録に書く。
 *
 * 末尾の「画面の書き方」は、投稿の作成の画面（PostComposerScreen.kt）のソースを文字列として読む検査（レビュー R05・R18・Q07）。
 * 画面の描画は JVM の単体テストでは確かめられない（Robolectric も Compose の UI テストも無い）ので、ProfileEditScreenSourceTest と
 * 同じ考え方で書き方を固定する。見るのは文字列なので、コメントの中の一致も数える。陽性対照は手元の台本（git の外）。
 */
class PostComposerViewModelTest {

    private val probe = FakePhotoProbe()
    private val analytics = RecordingFeatureAnalytics()
    private val publisher = FakePostPublisher()
    private val isOnline = MutableStateFlow(true)
    private val savedState = SavedStateHandle()

    // ── 編集の部品の偽物（Kiro android-edit-tools I1）。作り直した ViewModel と、開き直した 2 つ目の ViewModel にも同じ実体を渡す ──
    private val importer = FakeWorkingPhotoImporter()
    private val sessionStore = FakeEditSessionStore()
    private val draftStore = FakeLocalDraftRepository()
    private val loadoutStore = FakeLoadoutStore()
    private val renderer = FakeEditPreviewRenderer()

    /** いまログインしている人（ViewModel は呼ぶたびに読む）。既定はログインしていない（写真を写さない、今までのテストの形）。 */
    private var signedIn: Uid? = null

    /** 送ったイベントの名前（新しいイベントを送らないことを見る。RecordingFeatureAnalytics はイベントを残さないので、ここで拾う）。 */
    private val events = mutableListOf<EventName>()
    private val recordingAnalytics: AnalyticsFacade = object : AnalyticsFacade by analytics {
        override fun logEvent(name: EventName, params: Map<String, ParamValue>) {
            events += name
        }
    }

    private val viewModel = newViewModel()

    /**
     * 投稿の画面の ViewModel を作る（偽物はこのテストの実体を共有する。uid は [signedIn] を呼ぶたびに読む）。
     * 途中の保存の待ちは既定で Long.MAX_VALUE（`delay` は時計に載せずに待ち続ける）なので、途中は onStop か、
     * 待ちを 0 にした ViewModel でだけ書かれる（:app のテストには仮想の時計が無い）。
     */
    private fun newViewModel(
        handle: SavedStateHandle = savedState,
        photoProbe: PhotoProbe = probe,
        saveDelayMillis: Long = Long.MAX_VALUE,
    ) = PostComposerViewModel(
        photoProbe,
        recordingAnalytics,
        publisher,
        isOnline,
        handle,
        immediateScope(),
        importer,
        sessionStore,
        draftStore,
        loadoutStore,
        renderer,
        { signedIn },
        immediateScope(),
        saveDelayMillis,
    )

    /** プロセスが落ちて、この画面を作り直した ViewModel（[savedState] の中身と、端末の中のファイル＝偽物の中身だけが戻る）。 */
    private fun recreated() = newViewModel(handle = savedState.afterProcessDeath(), photoProbe = FakePhotoProbe())

    private val state get() = viewModel.state.value

    private fun uris(count: Int, prefix: String = "p") = (0 until count).map { "content://media/picker/0/photo/$prefix$it" }

    /**
     * 読めた写真 [uri] の、編集の段の 1 枚（design.md:686）。ログインしていない間の形：写真を写さず（選んだ URI のまま・
     * relativeFile は null）、撮影日時も読まず、フィルターだけを [filter] に置き、履歴は空のまま。
     * 状態は番号を持たず、並びの位置が番号になる（投稿・変換に渡すときに [WorkingPhoto.toPickedPhoto] で 0 から振る）。
     */
    private fun editing(uri: String, filter: FilterId? = null) =
        EditingPhoto(WorkingPhoto(uri, relativeFile = null, capturedAt = null), PhotoEdit(filter = filter))

    /** 今の写真ごとのフィルター（フィルターは写真ごとの編集にあり、表示中の写真にだけ掛かる）。 */
    private fun filters(): List<FilterId?> = state.photos.map { it.edit.filter }

    // ── 編集の部品を使うテストの補助（Kiro android-edit-tools I1） ──

    private val uid = Uid("UID-A")
    private val otherUid = Uid("UID-B")
    private val draft1 = DraftId("DRAFT-1")

    /** [user] でログインし、写しを作れる形にする（写した写真は場所 session/photo-{番号} と relativeFile を持つ。1 枚目だけ [capturedAt]）。 */
    private fun signIn(user: Uid = uid, capturedAt: CapturedAt? = null) {
        signedIn = user
        importer.result = { _, photos ->
            photos.mapIndexed { index, photo -> copied(photo.uri, index, if (index == 0) capturedAt else null) }
        }
    }

    /** 写した写真。場所は写しの決まり（毎回同じ session/photo-{番号}）で、見分けるために元の URI の末尾を # の後に残す。 */
    private fun copied(uri: String, index: Int, capturedAt: CapturedAt? = null) = WorkingPhoto(
        "file:///edit/session/photo-$index#${uri.substringAfterLast('/')}",
        relativeFile = "session/photo-$index",
        capturedAt = capturedAt,
    )

    /** [vm] に onStop で途中を書かせ、書いた文書を返す（印と中身を読むため。書いた日時は時計なので丸ごとは比べない）。 */
    private fun writtenSession(vm: PostComposerViewModel = viewModel): EditWorkDocument {
        vm.onStop()
        return sessionStore.calls.filterIsInstance<FakeEditSessionStore.Call.Save>().last().document
    }

    /** 途中の保存の部品への呼び出しのうち、書く（Save）以外（読む・丸ごと消す・印つきで消す）。 */
    private fun sessionCalls(): List<FakeEditSessionStore.Call> = sessionStore.calls.filterNot { it is FakeEditSessionStore.Call.Save }

    /** 書いた途中の文書の数。 */
    private fun saveCount(): Int = sessionStore.calls.count { it is FakeEditSessionStore.Call.Save }

    /**
     * [id] の下書きを開ける形にする（写真 [count] 枚・1 枚目にフィルター [filter]・キャプションと公開範囲つき）。
     * 開いた時の途中の文書は印が空（DefaultLocalDraftRepository.openDraft と同じ）。
     */
    private fun prepareDraft(
        id: DraftId = draft1,
        count: Int = 2,
        filter: FilterId? = FilterId.VINTAGE,
        caption: String = "下書きの文",
        visibility: Visibility = Visibility.FOLLOWERS,
    ): List<WorkingPhoto> {
        val photos = (0 until count).map { WorkingPhoto("file:///edit/drafts/${id.value}/photo-$it", "drafts/${id.value}/photo-$it", null) }
        val document = EditWorkDocument(
            sessionId = "",
            draftId = id.value,
            savedAtEpochMillis = 1_000L,
            caption = caption,
            visibilityRaw = visibility.raw,
            enteredInfo = false,
            photos = photos.mapIndexed { index, photo ->
                EditWorkPhoto(
                    file = "drafts/${id.value}/photo-$index",
                    capturedAtEpochMillis = null,
                    capturedAtSourceRaw = CapturedAtSource.NONE.raw,
                    edit = if (index == 0) PhotoEdit(filter = filter) else PhotoEdit.NONE,
                )
            },
        )
        draftStore.openResults[id] = DraftOpenResult.Opened(document, photos)
        return photos
    }

    /** 描いた絵の画素に、掛けたフィルターの番号（「なし」は -1）を入れる。見本の土台は長辺で見分けられる大きさ（2×2）にする。 */
    private fun markRenderedFilters() {
        renderer.loadBaseResult = { _, _, longEdge ->
            val size = if (longEdge == EditPreviewRenderer.FILTER_SAMPLE_EDGE) 2 else 4
            AppResult.Ok(PreviewBase(IntArray(size * size), size, size))
        }
        renderer.renderResult = { base, recipe -> IntArray(base.width * base.height) { recipe.filter?.ordinal ?: -1 } }
    }

    /** プレビュー（長辺 1024 の土台と、スライダーを動かしている間の表示中の写真の長辺 720 の土台。この偽物ではどちらも幅 4）に掛けた色。 */
    private fun previewRecipes(): List<ColorRecipe> =
        renderer.calls.filterIsInstance<FakeEditPreviewRenderer.Call.Render>().filter { it.base.width == 4 }.map { it.recipe }

    /** 長辺 [longEdge] で読んだ土台の数。 */
    private fun loadBaseCount(longEdge: Int): Int =
        renderer.calls.count { it is FakeEditPreviewRenderer.Call.LoadBase && it.longEdge == longEdge }

    // ── 画面名 ──

    @Test
    fun `画面名「投稿」は、表示のたびに呼ばれても最初の1回だけ送る`() {
        viewModel.onScreenShown()
        viewModel.onScreenShown()

        assertEquals(listOf(ScreenName.POST), analytics.screens)
    }

    @Test
    fun `読めた写真で編集の段に入ったら「編集」を送り、編集の段のまま選び直しても送り直さない`() {
        viewModel.onPhotosPicked(uris(2))
        assertTrue(state.isEditing)
        assertEquals(listOf(ScreenName.EDIT), analytics.screens)

        viewModel.onPhotosPicked(uris(3, prefix = "q"))
        assertEquals(listOf(ScreenName.EDIT), analytics.screens)
    }

    @Test
    fun `写真の選択の段に戻ってから選び直すと、編集の段に入るたびに「編集」を送る`() {
        viewModel.onPhotosPicked(uris(1))
        // 変更が無いので、確かめずに写真の選択の段に戻る（今までの backToSelecting の入口が requestLeave になった：design.md:977）
        viewModel.requestLeave()
        viewModel.onPhotosPicked(uris(1, prefix = "q"))

        assertEquals(listOf(ScreenName.EDIT, ScreenName.EDIT), analytics.screens)
    }

    // ── 読めない写真 ──

    @Test
    fun `読めない写真は外して位置（1始まり）を残し、外した写真ごとに記録し、残りを0から振り直す`() {
        val picked = uris(4)
        probe.unreadable += setOf(picked[1], picked[3])

        viewModel.onPhotosPicked(picked)

        assertEquals(listOf(editing(picked[0]), editing(picked[2])), state.photos)
        assertEquals(listOf(2, 4), state.unreadablePositions)
        assertEquals(
            listOf<Pair<AppError, String>>(
                AppError.ImageUnreadable(1) to "PostComposerViewModel.onPhotosPicked",
                AppError.ImageUnreadable(3) to "PostComposerViewModel.onPhotosPicked",
            ),
            analytics.errors,
        )
        // 1 枚ずつ、選んだ順に確かめる
        assertEquals(picked.mapIndexed { index, uri -> PickedPhoto(uri, index) }, probe.probed)
        assertFalse(state.isChecking)

        // 状態は番号を持たないので、0 から振り直した番号は投稿に渡す写真で見る（Kiro android-edit-tools K0 で、状態の写真から番号が無くなった）
        viewModel.goToInfo()
        viewModel.publish()
        assertEquals(listOf(PickedPhoto(picked[0], 0), PickedPhoto(picked[2], 1)), publisher.drafts.single().photos.map { it.photo })
    }

    @Test
    fun `全部読めなければ編集の段に入らず「編集」も送らないが、選んだことは残るので何も選ばずに閉じても画面は閉じない`() {
        val picked = uris(2)
        probe.unreadable += picked

        viewModel.onPhotosPicked(picked)

        assertFalse(state.isEditing)
        assertEquals(listOf(1, 2), state.unreadablePositions)
        assertTrue(analytics.screens.isEmpty())
        assertFalse(shouldCloseAfterPicker(emptyList(), state))
    }

    // ── 上限（タスク 21.1 から移した） ──

    @Test
    fun `11枚以上は先頭の10枚だけを確かめて受け付け、超えたことを伝える`() {
        viewModel.onPhotosPicked(uris(12))

        assertEquals(10, probe.probed.size)
        assertEquals(10, state.photos.size)
        assertTrue(state.exceeded)
    }

    @Test
    fun `選び直すと前の選択を丸ごと置き換え、何も選ばずに閉じたら前の選択を残す`() {
        viewModel.onPhotosPicked(uris(12))
        val replacement = listOf("content://media/picker/0/photo/99")

        viewModel.onPhotosPicked(replacement)
        assertEquals(listOf(editing(replacement[0])), state.photos)
        assertFalse(state.exceeded)

        viewModel.onPhotosPicked(emptyList())
        assertEquals(listOf(editing(replacement[0])), state.photos)
    }

    // ── フィルター ──

    @Test
    fun `フィルターは選ぶと前のフィルターを置き換え、「なし」で元の写真に戻る`() {
        viewModel.onPhotosPicked(uris(1))
        assertEquals(listOf<FilterId?>(null), filters())

        viewModel.selectFilter(FilterId.CLEAR)
        assertEquals(listOf<FilterId?>(FilterId.CLEAR), filters())
        viewModel.selectFilter(FilterId.MONOCHROME)
        assertEquals(listOf<FilterId?>(FilterId.MONOCHROME), filters())
        viewModel.selectFilter(null)
        assertEquals(listOf<FilterId?>(null), filters())
    }

    @Test
    fun `選び直すと編集と履歴は空から始まり、編集の段を離れた後に選んだ写真も「なし」から始まる`() {
        // 今までの「選び直してもフィルターは残す」は、要件 6.10（選び直しで履歴を空にする）と写真ごとの編集で、空から始まるに変わった
        viewModel.onPhotosPicked(uris(1))
        viewModel.selectFilter(FilterId.VIVID)

        viewModel.onPhotosPicked(uris(2, prefix = "q"))
        assertEquals(listOf<FilterId?>(null, null), filters())
        assertTrue(state.photos.all { it.history == EditHistory.EMPTY })
        assertFalse(state.canUndo)

        // 選び直した写真が全て読めない → 編集の段を離れる。フィルターは写真ごとの編集にあるので、写真と一緒に無くなる
        // （「なし」に戻ったことは、次に選んだ写真が「なし」から始まることで見る）
        viewModel.selectFilter(FilterId.DRAMA)
        val broken = uris(1, prefix = "x")
        probe.unreadable += broken
        viewModel.onPhotosPicked(broken)
        assertEquals(emptyList(), state.photos)

        viewModel.onPhotosPicked(uris(1, prefix = "r"))
        assertEquals(listOf<FilterId?>(null), filters())
        viewModel.selectFilter(FilterId.SOFT)
        // 変更があるので確かめが出る。破棄を選ぶと写真の選択の段に戻る
        viewModel.requestLeave()
        viewModel.answerLeave(LeaveChoice.DISCARD)
        assertEquals(emptyList(), state.photos)
        viewModel.onPhotosPicked(uris(1, prefix = "s"))
        assertEquals(listOf<FilterId?>(null), filters())
    }

    // ── 写真の選択の段に戻る ──

    @Test
    fun `写真の選択の段に戻ると、選んだ写真と案内を捨て、選んだことだけを残す`() {
        val picked = uris(12)
        probe.unreadable += picked[0]
        viewModel.onPhotosPicked(picked)

        // 変更が無いので、確かめずに戻る
        viewModel.requestLeave()

        assertEquals(PostComposerUiState(hasPicked = true, draftCountLoaded = true), state)
        assertFalse(shouldCloseAfterPicker(emptyList(), state))
    }

    // ── 確かめている途中 ──

    @Test
    fun `確かめている間は読み込み中で、途中で選び直したら前の確認の結果で上書きしない`() {
        val first = uris(1, prefix = "a")
        val gate = CompletableDeferred<Unit>()
        probe.gates[first[0]] = gate

        viewModel.onPhotosPicked(first)
        assertTrue(state.isChecking)
        assertFalse(state.isEditing)

        val second = uris(1, prefix = "b")
        viewModel.onPhotosPicked(second)
        gate.complete(Unit)

        assertEquals(listOf(editing(second[0])), state.photos)
        assertFalse(state.isChecking)
        assertEquals(listOf(ScreenName.EDIT), analytics.screens)
    }

    @Test
    fun `確かめている途中で写真の選択の段に戻ったら、確認の結果を捨てる`() {
        val picked = uris(1)
        val gate = CompletableDeferred<Unit>()
        probe.gates[picked[0]] = gate
        viewModel.onPhotosPicked(picked)

        viewModel.requestLeave()
        gate.complete(Unit)

        assertEquals(PostComposerUiState(hasPicked = true, draftCountLoaded = true), state)
        assertTrue(analytics.screens.isEmpty())
    }

    // ── 何も選ばずに閉じたとき ──

    @Test
    fun `一度も選ばないうちに何も選ばずに閉じたら画面を閉じ、選んだら閉じない`() {
        assertTrue(shouldCloseAfterPicker(emptyList(), PostComposerUiState()))
        assertFalse(shouldCloseAfterPicker(uris(1), PostComposerUiState()))
        assertFalse(shouldCloseAfterPicker(emptyList(), PostComposerUiState(hasPicked = true)))
    }

    // ── 投稿情報の段（タスク 23.5） ──

    /** 写真を [count] 枚選び、フィルターを [filter] にして投稿情報の段に進む。 */
    private fun enterInfo(count: Int = 2, filter: FilterId? = FilterId.VIVID): List<String> {
        val picked = uris(count)
        viewModel.onPhotosPicked(picked)
        viewModel.selectFilter(filter)
        viewModel.goToInfo()
        return picked
    }

    @Test
    fun `編集の段で「次へ」を押すと投稿情報の段に進み、写真とフィルターを持ち越し、公開範囲は公開から始まる`() {
        val picked = enterInfo()

        assertEquals(ComposeStep.INFO, state.step)
        assertFalse(state.isEditing)
        // フィルターは表示中の 1 枚目にだけ掛かる（写真ごとの編集：要件 5.3）。選んだ 1 手は履歴に残る
        assertEquals(picked, state.photos.map { it.photo.uri })
        assertEquals(listOf<FilterId?>(FilterId.VIVID, null), filters())
        assertTrue(state.canUndo)
        assertEquals(Visibility.PUBLIC, state.visibility)
        assertTrue(state.canPublish)
        // 投稿情報の段は画面名を送らない（iOS の PostInfoView も送らない）
        assertEquals(listOf(ScreenName.EDIT), analytics.screens)
    }

    @Test
    fun `写真の選択の段と、写真を確かめている間は「次へ」で進まない`() {
        viewModel.goToInfo()
        assertEquals(ComposeStep.SELECTING, state.step)

        viewModel.onPhotosPicked(uris(1))
        val second = uris(1, prefix = "b")
        val gate = CompletableDeferred<Unit>()
        probe.gates[second[0]] = gate
        viewModel.onPhotosPicked(second)
        assertTrue(state.isChecking)

        viewModel.goToInfo()
        // 確認が終わると isEnteringInfo は戻るので、進まなかったことは確認中のうちに見る
        assertEquals(ComposeStep.EDITING, state.step)
        gate.complete(Unit)

        assertEquals(ComposeStep.EDITING, state.step)
    }

    @Test
    fun `投稿情報の段から戻ると、写真・フィルター・キャプション・公開範囲を残して編集の段に戻り、写真の選択まで戻ると全て捨てる`() {
        enterInfo()
        viewModel.onCaptionChange("夕焼け #空")
        viewModel.selectVisibility(Visibility.FOLLOWERS)

        viewModel.backToEditing()
        assertEquals(ComposeStep.EDITING, state.step)
        assertEquals(listOf<FilterId?>(FilterId.VIVID, null), filters())
        assertEquals("夕焼け #空", state.caption)
        assertEquals(Visibility.FOLLOWERS, state.visibility)
        // 投稿情報の段から戻っても「編集」を送り直さない
        assertEquals(listOf(ScreenName.EDIT), analytics.screens)

        viewModel.goToInfo()
        assertEquals("夕焼け #空", state.caption)

        viewModel.backToEditing()
        // 変更があるので確かめが出る（要件 1.7）。破棄を選ぶと全て捨てて写真の選択の段に戻る
        viewModel.requestLeave()
        assertEquals(LeaveQuestion.DISCARD_OR_DRAFT, state.leaveQuestion)
        viewModel.answerLeave(LeaveChoice.DISCARD)
        assertEquals(PostComposerUiState(hasPicked = true, draftCountLoaded = true), state)
    }

    @Test
    fun `キャプションはUTF-16で2000まで投稿でき、超えても入力は切らずに残し、投稿ボタンを押せなくする`() {
        enterInfo()
        // 絵文字 1 つは UTF-16 で 2（書記素で数えると 1000 と 1001 になり、どちらも上限内になってしまう）
        viewModel.onCaptionChange("😀".repeat(1000))
        assertEquals(2000, state.captionLength)
        assertFalse(state.isCaptionTooLong)
        assertTrue(state.canPublish)

        val tooLong = "😀".repeat(1001)
        viewModel.onCaptionChange(tooLong)
        assertEquals(tooLong, state.caption)
        assertEquals(2002, state.captionLength)
        assertTrue(state.isCaptionTooLong)
        assertFalse(state.canPublish)
        viewModel.publish()
        assertTrue(publisher.drafts.isEmpty())
    }

    @Test
    fun `キャプションの文字数は前後の空白を除いて数える（保存するのは除いた後の値）`() {
        enterInfo()
        viewModel.onCaptionChange("  " + "a".repeat(2000) + "\n　")

        assertEquals(2000, state.captionLength)
        assertTrue(state.canPublish)
    }

    @Test
    fun `ハッシュタグは30個まで投稿でき、31個で案内を出して投稿ボタンを押せなくする（重複も数える）`() {
        enterInfo()
        viewModel.onCaptionChange((1..30).joinToString(" ") { "#空" })
        assertEquals(30, state.hashtags.size)
        assertFalse(state.hasTooManyHashtags)
        assertTrue(state.canPublish)

        viewModel.onCaptionChange((1..31).joinToString(" ") { "#空" })
        assertTrue(state.hasTooManyHashtags)
        assertFalse(state.canPublish)
    }

    @Test
    fun `投稿すると、写真・フィルター・入力欄のままのキャプション・公開範囲をPostPublisherに渡す`() {
        val picked = enterInfo(count = 3, filter = FilterId.MONOCHROME)
        viewModel.onCaptionChange("  朝の空 #朝焼け  ")
        viewModel.selectVisibility(Visibility.PRIVATE)

        viewModel.publish()

        assertEquals(
            listOf(
                PostDraft(
                    // フィルターは写真ごとの編集で、選んだのは表示中の 1 枚目だけ。ログインしていない間は写さないので撮影日時は null
                    photos = picked.mapIndexed { index, uri ->
                        PostPhoto(PickedPhoto(uri, index), if (index == 0) PhotoEdit(filter = FilterId.MONOCHROME) else PhotoEdit.NONE)
                    },
                    caption = "  朝の空 #朝焼け  ",
                    visibility = Visibility.PRIVATE,
                    firstPhotoCapturedAt = null,
                ),
            ),
            publisher.drafts,
        )
    }

    @Test
    fun `成功したら完了を出し、もう一度は押せない`() {
        enterInfo()
        viewModel.publish()

        assertTrue(state.published)
        assertFalse(state.isPublishing)
        assertNull(state.publishError)
        assertFalse(state.canPublish)
        viewModel.publish()
        assertEquals(1, publisher.drafts.size)
    }

    @Test
    fun `失敗したら理由を出して完了は出さず、もう一度押せる。理由は入力を変えても編集の段に戻っても消さず、OKでだけ消す`() {
        enterInfo()
        publisher.result = AppResult.Err(AppError.ImageTooLarge(1, 6_000_000))

        viewModel.publish()
        assertEquals(AppError.ImageTooLarge(1, 6_000_000), state.publishError)
        assertFalse(state.published)
        assertTrue(state.canPublish)
        // 失敗は記録しない（PostPublisher が記録済み）
        assertTrue(analytics.errors.isEmpty())

        // 画面はダイアログで出すので、見せた印は OK だけ（レビュー Q07）
        viewModel.onCaptionChange("a")
        viewModel.selectVisibility(Visibility.PRIVATE)
        viewModel.backToEditing()
        assertEquals(ComposeStep.EDITING, state.step)
        assertEquals(AppError.ImageTooLarge(1, 6_000_000), state.publishError)

        viewModel.dismissPublishError()
        assertNull(state.publishError)
    }

    @Test
    fun `投稿が戻るまでは、もう一度押してもPostPublisherを呼ばない`() {
        enterInfo()
        val gate = CompletableDeferred<AppResult<PostId>>()
        publisher.gate = gate

        viewModel.publish()
        assertTrue(state.isPublishing)
        assertFalse(state.canPublish)
        viewModel.publish()
        assertEquals(1, publisher.drafts.size)

        gate.complete(AppResult.Ok(PostId("P1")))
        assertTrue(state.published)
    }

    @Test
    fun `アップロード中は進み具合を出し、投稿ボタンを押せず、戻る操作でもキャンセルでも離れない`() {
        enterInfo()
        publisher.gate = CompletableDeferred()
        viewModel.publish()
        publisher.state.value = PublishState.Uploading(done = 1, total = 2)

        assertEquals(PublishProgress.Uploading(1, 2), state.progress)
        assertFalse(state.canLeave)
        assertFalse(state.canPublish)
        viewModel.backToEditing()
        assertEquals(ComposeStep.INFO, state.step)
        viewModel.requestLeave()
        assertEquals(ComposeStep.INFO, state.step)
        assertNull(state.leaveQuestion)
    }

    @Test
    fun `保存中は離れてよく、写真の選択まで戻っても進み具合を失わず、保存が終われば完了を出す`() {
        enterInfo()
        val gate = CompletableDeferred<AppResult<PostId>>()
        publisher.gate = gate
        viewModel.publish()
        publisher.state.value = PublishState.Saving

        assertTrue(state.canLeave)
        viewModel.backToEditing()
        assertEquals(ComposeStep.EDITING, state.step)
        // 変更（フィルター）があるので確かめが出る。破棄を選ぶと写真の選択の段に戻る
        viewModel.requestLeave()
        viewModel.answerLeave(LeaveChoice.DISCARD)
        assertEquals(ComposeStep.SELECTING, state.step)
        // 共有の状態は Saving のまま変わらないので、ここで捨てると戻らない
        assertEquals(PublishProgress.Saving, state.progress)
        assertTrue(state.isPublishing)

        publisher.state.value = PublishState.Succeeded(PostId("P1"))
        gate.complete(AppResult.Ok(PostId("P1")))
        assertNull(state.progress)
        assertTrue(state.published)
    }

    @Test
    fun `前に開いた画面の投稿が保存中なら、この画面の投稿ではないと分かる形で出し、投稿ボタンを押せなくする`() {
        publisher.state.value = PublishState.Saving
        val viewModel = newViewModel(handle = SavedStateHandle(), photoProbe = FakePhotoProbe())
        viewModel.onPhotosPicked(uris(1))
        viewModel.goToInfo()

        assertEquals(PublishProgress.Saving, viewModel.state.value.progress)
        assertTrue(viewModel.state.value.isOthersProgress)
        assertFalse(viewModel.state.value.canPublish)

        // 保存が終われば押せる。前の投稿の成功は、この画面の完了として出さない
        publisher.state.value = PublishState.Succeeded(PostId("P0"))
        assertNull(viewModel.state.value.progress)
        assertFalse(viewModel.state.value.published)
        assertTrue(viewModel.state.value.canPublish)
    }

    @Test
    fun `開いたときに共有の状態が前の投稿の成功・失敗のままでも、完了も理由も出さない`() {
        listOf(PublishState.Succeeded(PostId("P0")), PublishState.Failed(AppError.Network)).forEach { last ->
            publisher.state.value = last
            val viewModel = newViewModel(handle = SavedStateHandle(), photoProbe = FakePhotoProbe())
            viewModel.onPhotosPicked(uris(1))
            viewModel.goToInfo()

            val state = viewModel.state.value
            assertNull(state.progress, "$last")
            assertFalse(state.published, "$last")
            assertNull(state.publishError, "$last")
            assertTrue(state.canPublish, "$last")
        }
    }

    @Test
    fun `前の投稿の処理中と断られたら、その理由を出す`() {
        enterInfo()
        publisher.result = AppResult.Err(AppError.Validation(ValidationReason.PUBLISH_IN_PROGRESS))

        viewModel.publish()

        assertEquals(AppError.Validation(ValidationReason.PUBLISH_IN_PROGRESS), state.publishError)
        assertFalse(state.published)
    }

    // ── オフライン（レビュー R05）──

    @Test
    fun `オフラインの間は投稿を押してもPostPublisherに届かず、接続が戻れば届く`() {
        // オフラインで始めると、画像のアップロードが接続を待って止まり、アップロード中は戻る・キャンセルも効かない
        // （兄弟の ProfileEditViewModel の保存と同じく、入口で止める。canPublish には接続を入れないので、ここは呼んだ結果で見る）
        enterInfo()
        isOnline.value = false

        viewModel.publish()
        assertTrue(publisher.drafts.isEmpty())
        assertFalse(state.isPublishing)

        isOnline.value = true
        viewModel.publish()
        assertEquals(1, publisher.drafts.size)
    }

    // ── 保存中に段を戻った後の失敗（レビュー R18・Q07）──

    /** 投稿情報の段で投稿し、保存中まで進めて止める。戻り値を完了させると、この画面の投稿が戻る。 */
    private fun publishAndHoldWhileSaving(): CompletableDeferred<AppResult<PostId>> {
        enterInfo()
        val gate = CompletableDeferred<AppResult<PostId>>()
        publisher.gate = gate
        viewModel.publish()
        publisher.state.value = PublishState.Saving
        return gate
    }

    @Test
    fun `保存中に編集の段へ戻った後に保存が失敗したら、編集の段のまま失敗が見え、写真の選択の段に戻ってもOKまで消さない`() {
        val gate = publishAndHoldWhileSaving()
        viewModel.backToEditing()

        publisher.state.value = PublishState.Failed(AppError.PermissionDenied)
        gate.complete(AppResult.Err(AppError.PermissionDenied))

        // 画面は段によらずダイアログで出す（下の「画面の書き方」で固定する）
        assertEquals(ComposeStep.EDITING, state.step)
        assertEquals(AppError.PermissionDenied, state.publishError)
        assertFalse(state.isPublishing)
        assertFalse(state.published)

        // 変更（フィルター）があるので、確かめで破棄を選んで写真の選択の段に戻る
        viewModel.requestLeave()
        viewModel.answerLeave(LeaveChoice.DISCARD)
        assertEquals(ComposeStep.SELECTING, state.step)
        assertEquals(AppError.PermissionDenied, state.publishError)
        viewModel.dismissPublishError()
        assertNull(state.publishError)
    }

    @Test
    fun `保存中に写真の選択まで戻り、写真選択画面を開いている間に届いた失敗は、写真を選んでもOKまで消さない`() {
        val gate = publishAndHoldWhileSaving()
        viewModel.backToEditing()
        viewModel.requestLeave()
        viewModel.answerLeave(LeaveChoice.DISCARD)

        // 写真の選択の段で写真選択画面を開いている間に届く（画面は写真選択画面の下にあって、まだ見えていない）
        publisher.state.value = PublishState.Failed(AppError.PermissionDenied)
        gate.complete(AppResult.Err(AppError.PermissionDenied))
        assertEquals(ComposeStep.SELECTING, state.step)
        assertEquals(AppError.PermissionDenied, state.publishError)

        // 写真を選んで戻っても消さない（戻ったときにダイアログで見える。レビュー Q07）
        viewModel.onPhotosPicked(uris(1, prefix = "n"))
        assertEquals(ComposeStep.EDITING, state.step)
        assertEquals(AppError.PermissionDenied, state.publishError)

        // OK で消し、次の下書きは投稿情報の段まで進んで投稿できる
        viewModel.dismissPublishError()
        assertNull(state.publishError)
        viewModel.goToInfo()
        assertEquals(ComposeStep.INFO, state.step)
        assertNull(state.publishError)
        assertTrue(state.canPublish)
    }

    @Test
    fun `保存中に写真の選択まで戻り、写真を選び直した後に届いた前の失敗も、OKまで出す`() {
        val gate = publishAndHoldWhileSaving()
        viewModel.backToEditing()
        viewModel.requestLeave()
        viewModel.answerLeave(LeaveChoice.DISCARD)
        viewModel.onPhotosPicked(uris(1, prefix = "n"))
        viewModel.goToInfo()
        assertEquals(ComposeStep.INFO, state.step)
        // 前の投稿がまだ戻っていないので、次の下書きは投稿できない
        assertFalse(state.canPublish)

        publisher.state.value = PublishState.Failed(AppError.PermissionDenied)
        gate.complete(AppResult.Err(AppError.PermissionDenied))
        // 画面はダイアログで出す（次の下書きの投稿ボタンの上には出さない：下の「画面の書き方」）
        assertEquals(AppError.PermissionDenied, state.publishError)
        assertFalse(state.isPublishing)
        assertTrue(state.canPublish)

        viewModel.dismissPublishError()
        assertNull(state.publishError)
        assertEquals(ComposeStep.INFO, state.step)
    }

    // ── プロセスが落ちて作り直したとき（全体レビュー 4 回目 Q09）──

    @Test
    fun `プロセスが落ちて作り直しても、打ったキャプション・公開範囲と一度選んだことを残し、途中を読めなければ写真は戻さず案内を出す`() {
        // 裏に回っている間にメモリの不足で殺されると、戻る履歴と写真選択画面を開いた印（rememberSaveable）は戻るが、
        // ViewModel は作り直される。残さないと、打ったキャプションが黙って消える
        // （ログインしていない＝写真を写せないので、途中は読み戻せない。読み戻せる形は「作り直されたとき」の節で見る：要件 12.2）
        enterInfo()
        viewModel.onCaptionChange("夕焼け #空")
        viewModel.selectVisibility(Visibility.FOLLOWERS)

        val recreated = recreated()

        val restored = recreated.state.value
        assertEquals("夕焼け #空", restored.caption)
        assertEquals(Visibility.FOLLOWERS, restored.visibility)
        // 一度選んだことが残らないと、写真選択画面を何も選ばずに閉じただけで投稿の画面ごと閉じ、残したキャプションも消える
        assertTrue(restored.hasPicked)
        assertFalse(shouldCloseAfterPicker(emptyList(), restored))
        // 途中を読めないので、写真と編集は戻らず、案内を出して写真の選択の段から始める（要件 12.3）
        // （フィルターは写真ごとの編集にあるので写真と一緒に戻らない。戻らなかったことは、選び直した写真が「なし」から始まることで見る）
        assertEquals(emptyList(), restored.photos)
        assertEquals(ComposeStep.SELECTING, restored.step)
        assertTrue(restored.sessionUnreadable)

        // 写真を選び直して進むと、投稿情報の段に打った入力が戻る
        recreated.onPhotosPicked(uris(1, prefix = "r"))
        assertEquals(listOf<FilterId?>(null), recreated.state.value.photos.map { it.edit.filter })
        recreated.goToInfo()
        assertEquals(ComposeStep.INFO, recreated.state.value.step)
        assertEquals("夕焼け #空", recreated.state.value.caption)
        assertEquals(Visibility.FOLLOWERS, recreated.state.value.visibility)
    }

    @Test
    fun `写真の選択の段に戻ったら、残した入力も捨てる（一度選んだことは残す）`() {
        enterInfo()
        viewModel.onCaptionChange("捨てる文")
        viewModel.selectVisibility(Visibility.PRIVATE)
        viewModel.backToEditing()
        // 変更があるので確かめで破棄を選ぶ（途中があることの印も消えるので、作り直した画面は途中を読みに行かず、案内も出さない）
        viewModel.requestLeave()
        viewModel.answerLeave(LeaveChoice.DISCARD)

        assertEquals(PostComposerUiState(hasPicked = true, draftCountLoaded = true), recreated().state.value)
    }

    @Test
    fun `投稿できたら、残した入力を捨てる（作り直した画面に投稿済みのキャプションを戻さない）`() {
        enterInfo()
        viewModel.onCaptionChange("投稿した文")
        viewModel.selectVisibility(Visibility.PRIVATE)
        viewModel.publish()
        assertTrue(state.published)

        assertEquals(PostComposerUiState(hasPicked = true, draftCountLoaded = true), recreated().state.value)
    }

    @Test
    fun `投稿に失敗したら、残した入力はそのまま`() {
        publisher.result = AppResult.Err(AppError.Network)
        enterInfo()
        viewModel.onCaptionChange("送り直す文")
        viewModel.publish()
        assertEquals(AppError.Network, state.publishError)

        assertEquals("送り直す文", recreated().state.value.caption)
    }

    // ── 写真ごとの編集・プレビュー・装備（Kiro android-edit-tools 18.2） ──

    @Test
    fun `操作は表示中の写真だけに掛かり、写真を切り替えると元に戻す・やり直しの可否が切り替えた先の履歴になる`() {
        viewModel.onPhotosPicked(uris(3))
        viewModel.showPhoto(1)
        viewModel.selectFilter(FilterId.VIVID)

        assertEquals(1, state.currentIndex)
        assertEquals(listOf<FilterId?>(null, FilterId.VIVID, null), filters())
        assertTrue(state.canUndo)
        assertFalse(state.canRedo)

        viewModel.undo()
        assertEquals(listOf<FilterId?>(null, null, null), filters())
        assertFalse(state.canUndo)
        assertTrue(state.canRedo)

        // 切り替えた先（履歴の無い 1 枚目）では、どちらも押せず、やり直しても何も変わらない
        viewModel.showPhoto(0)
        assertFalse(state.canUndo)
        assertFalse(state.canRedo)
        viewModel.redo()
        assertEquals(listOf<FilterId?>(null, null, null), filters())

        // 戻ると、その写真の履歴のまま
        viewModel.showPhoto(1)
        assertTrue(state.canRedo)
        viewModel.redo()
        assertEquals(listOf<FilterId?>(null, FilterId.VIVID, null), filters())
    }

    @Test
    fun `スライダーは動かしている間は履歴に積まず、離した時に触れた時の内容を1手として積む`() {
        viewModel.onPhotosPicked(uris(2))
        viewModel.onSliderChange(EditTool.EXPOSURE, 10)
        viewModel.onSliderChange(EditTool.EXPOSURE, 30)

        assertEquals(30, state.photos[0].edit.tools[EditTool.EXPOSURE])
        assertEquals(0, state.photos[1].edit.tools[EditTool.EXPOSURE])
        assertEquals(PhotoEdit.NONE, state.sliderStart)
        assertFalse(state.canUndo)

        viewModel.onSliderFinished()
        assertNull(state.sliderStart)
        assertTrue(state.canUndo)

        // 触れてから離すまでが 1 手：1 回で触れる前に戻る（要件 6.2）
        viewModel.undo()
        assertEquals(PhotoEdit.NONE, state.photos[0].edit)
        assertFalse(state.canUndo)
    }

    @Test
    fun `スライダーを動かしている途中に写真を切り替えると、元の写真の1手にしてから切り替える`() {
        viewModel.onPhotosPicked(uris(2))
        viewModel.onSliderChange(EditTool.FADE, 30)
        viewModel.showPhoto(1)

        assertNull(state.sliderStart)
        assertFalse(state.canUndo)
        viewModel.showPhoto(0)
        assertTrue(state.canUndo)
        assertEquals(30, state.photos[0].edit.tools[EditTool.FADE])
    }

    @Test
    fun `トリミング・回転の画面の間は、元に戻す・やり直し・スライダー・フィルター・写真の送り・「次へ」を受け付けない`() {
        viewModel.onPhotosPicked(uris(2))
        viewModel.selectFilter(FilterId.VIVID)
        viewModel.selectFilter(FilterId.SOFT)
        viewModel.undo()
        // 元に戻す・やり直しのどちらも効く状態にしてから開く
        assertTrue(state.canUndo)
        assertTrue(state.canRedo)
        viewModel.openTool(EditTool.CROP_AND_ROTATE)
        assertNotNull(state.cropSession)
        val before = state.photos

        viewModel.undo()
        assertEquals(before, state.photos, "トリミング・回転の画面の間に元に戻すが効いた")
        viewModel.redo()
        assertEquals(before, state.photos, "トリミング・回転の画面の間にやり直しが効いた")
        viewModel.onSliderChange(EditTool.EXPOSURE, 50)
        assertEquals(before, state.photos, "トリミング・回転の画面の間にスライダーが効いた")
        assertNull(state.sliderStart)
        viewModel.selectFilter(FilterId.MONOCHROME)
        assertEquals(before, state.photos, "トリミング・回転の画面の間にフィルターの選択が効いた")
        viewModel.showPhoto(1)
        assertEquals(0, state.currentIndex)
        viewModel.goToInfo()
        assertEquals(ComposeStep.EDITING, state.step)

        // 取りやめれば受け付ける
        viewModel.cancelCrop()
        assertNull(state.cropSession)
        viewModel.undo()
        assertEquals(listOf<FilterId?>(null, null), filters())
    }

    @Test
    fun `トリミング・回転は確定すると表示中の写真にだけ掛かり、枠と回転が別の手になり、取りやめると始める前のまま`() {
        viewModel.onPhotosPicked(uris(2))
        viewModel.openTool(EditTool.CROP_AND_ROTATE)
        assertEquals(EditTool.CROP_AND_ROTATE, state.openTool)
        viewModel.onCropDrag(CropMath.Handle.TOP_LEFT, 0.2, 0.1)
        viewModel.rotateRight()
        viewModel.confirmCrop()

        assertNull(state.cropSession)
        assertNull(state.openTool)
        val dragged = EditGeometry(crop = CropMath.dragged(NormalizedRect.FULL, CropMath.Handle.TOP_LEFT, 0.2, 0.1))
        assertEquals(dragged.rotatedClockwise(), state.photos[0].edit.geometry)
        assertEquals(EditGeometry.NONE, state.photos[1].edit.geometry)
        // 枠を動かす→回す→確定 は 2 手（元に戻す 1 回で回転だけが戻り、もう 1 回で枠が戻る）
        viewModel.undo()
        assertEquals(dragged, state.photos[0].edit.geometry)
        viewModel.undo()
        assertEquals(EditGeometry.NONE, state.photos[0].edit.geometry)

        // 取りやめ：回しても辺を動かしても、写真は始める前のまま（要件 4.5）
        val photos = state.photos
        viewModel.openTool(EditTool.CROP_AND_ROTATE)
        viewModel.rotateLeft()
        viewModel.onCropNudge(CropMath.Edge.LEFT, inward = true)
        viewModel.cancelCrop()
        assertEquals(photos, state.photos)
        assertNull(state.cropSession)
        assertNull(state.openTool)
    }

    @Test
    fun `プレビューは表示中の写真とその両隣だけをプレビューの部品の絵で持ち、フィルターの見本は表示中の写真の11個`() {
        markRenderedFilters()
        val picked = uris(4)
        viewModel.onPhotosPicked(picked)

        assertEquals(setOf(0, 1), state.previews.keys)
        assertEquals(4, state.previews.getValue(0).width)
        assertTrue(state.previews.getValue(0).pixels.all { it == -1 }, "「なし」の色を掛けた絵でない")
        // 見本は FILTER_OPTIONS の並びで、それぞれそのフィルターだけを掛けた小さな絵（長辺 112 の土台）
        assertEquals(FILTER_OPTIONS.size, state.filterSamples.size)
        state.filterSamples.forEachIndexed { index, sample ->
            val image = assertNotNull(sample, "見本 $index が無い")
            assertEquals(2, image.width)
            assertEquals(FILTER_OPTIONS[index]?.ordinal ?: -1, image.pixels[0])
        }
        // 読んだ土台：表示中の写真と両隣は長辺 1024、見本は長辺 112（番号は並びの位置）
        assertTrue(
            renderer.calls.containsAll(
                listOf(
                    FakeEditPreviewRenderer.Call.LoadBase(PickedPhoto(picked[0], 0), 0, EditPreviewRenderer.PREVIEW_LONG_EDGE),
                    FakeEditPreviewRenderer.Call.LoadBase(PickedPhoto(picked[1], 1), 0, EditPreviewRenderer.PREVIEW_LONG_EDGE),
                    FakeEditPreviewRenderer.Call.LoadBase(PickedPhoto(picked[0], 0), 0, EditPreviewRenderer.FILTER_SAMPLE_EDGE),
                ),
            ),
            "読んだ土台が違う: ${renderer.calls.filterIsInstance<FakeEditPreviewRenderer.Call.LoadBase>()}",
        )

        viewModel.showPhoto(2)
        assertEquals(setOf(1, 2, 3), state.previews.keys)
        viewModel.selectFilter(FilterId.VIVID)
        assertTrue(state.previews.getValue(2).pixels.all { it == FilterId.VIVID.ordinal })
        assertTrue(state.previews.getValue(1).pixels.all { it == -1 })
    }

    @Test
    fun `フィルターの見本は、表示中の写真かその回転が変わったときだけ作り直し、ツールとフィルターの値では作り直さない`() {
        val picked = uris(2)
        viewModel.onPhotosPicked(picked)
        assertEquals(1, loadBaseCount(EditPreviewRenderer.FILTER_SAMPLE_EDGE))

        viewModel.onSliderChange(EditTool.EXPOSURE, 40)
        viewModel.onSliderFinished()
        viewModel.selectFilter(FilterId.SOFT)
        assertEquals(1, loadBaseCount(EditPreviewRenderer.FILTER_SAMPLE_EDGE))

        viewModel.openTool(EditTool.CROP_AND_ROTATE)
        viewModel.rotateRight()
        viewModel.confirmCrop()
        assertEquals(2, loadBaseCount(EditPreviewRenderer.FILTER_SAMPLE_EDGE))
        assertEquals(
            FakeEditPreviewRenderer.Call.LoadBase(PickedPhoto(picked[0], 0), 1, EditPreviewRenderer.FILTER_SAMPLE_EDGE),
            renderer.calls.filterIsInstance<FakeEditPreviewRenderer.Call.LoadBase>().last { it.longEdge == EditPreviewRenderer.FILTER_SAMPLE_EDGE },
        )

        viewModel.showPhoto(1)
        assertEquals(3, loadBaseCount(EditPreviewRenderer.FILTER_SAMPLE_EDGE))
    }

    @Test
    fun `描き直しは最新の値だけで、描いている間に来た値は最後の1つだけを次に描く`() {
        markRenderedFilters()
        val gate = CompletableDeferred<Unit>()
        renderer.renderGate = gate
        viewModel.onPhotosPicked(uris(1))
        // 1 枚目の「なし」の絵を描いている途中に、スライダーの値が 3 回来る
        viewModel.onSliderChange(EditTool.EXPOSURE, 10)
        viewModel.onSliderChange(EditTool.EXPOSURE, 20)
        viewModel.onSliderChange(EditTool.EXPOSURE, 30)
        assertEquals(listOf(ColorRecipe.of(PhotoEdit.NONE)), previewRecipes())

        gate.complete(Unit)

        val latest = PhotoEdit(tools = ToolValues.NONE.with(EditTool.EXPOSURE, 30))
        assertEquals(listOf(ColorRecipe.of(PhotoEdit.NONE), ColorRecipe.of(latest)), previewRecipes())
        assertEquals(setOf(0), state.previews.keys)
    }

    // ── スライダーを動かしている間の土台の長辺（タスク 20.5・design.md:1157・利用者の決定 2026-11-14）──

    /** 動かしている間に描く土台の長辺（design.md:1157 の 720。本体の定数から作らない）。 */
    private val dragLongEdge = 720

    /** 土台の幅を、読んだときの長辺そのものにする（高さは 1）。描いた絵の幅で、どの長辺の土台から描いたかを見分ける。 */
    private fun markBaseWidthsByLongEdge() {
        renderer.loadBaseResult = { _, _, longEdge -> AppResult.Ok(PreviewBase(IntArray(longEdge), longEdge, 1)) }
    }

    /** [from] 番目より後の呼び出しのうち、土台の読み込み。 */
    private fun loadBasesSince(from: Int): List<FakeEditPreviewRenderer.Call.LoadBase> =
        renderer.calls.drop(from).filterIsInstance<FakeEditPreviewRenderer.Call.LoadBase>()

    /** [from] 番目より後の呼び出しを、読みは長辺・描きは土台の幅（＝読んだ長辺）の文字にして並べる。 */
    private fun callsSince(from: Int): List<String> = renderer.calls.drop(from).map { call ->
        when (call) {
            is FakeEditPreviewRenderer.Call.LoadBase -> "load ${call.longEdge}"
            is FakeEditPreviewRenderer.Call.Render -> "render ${call.base.width}"
            is FakeEditPreviewRenderer.Call.DraftThumbnail -> "thumbnail"
        }
    }

    @Test
    fun `スライダーを指で引いている間（値が2回変わってから）は、表示中の写真だけを長辺720の土台で描き、両隣は読み直さない`() {
        markBaseWidthsByLongEdge()
        val picked = uris(3)
        viewModel.onPhotosPicked(picked)
        viewModel.showPhoto(1)
        assertEquals(setOf(0, 1, 2), state.previews.keys, "テストの前提（表示中の写真と両隣を描いた）が崩れた")

        val from = renderer.calls.size
        viewModel.onSliderChange(EditTool.EXPOSURE, 10)
        // 値が 1 回変わっただけでは、読んである長辺 1024 の土台で描く（1 手の操作と見分けられない）
        assertEquals(emptyList<FakeEditPreviewRenderer.Call.LoadBase>(), loadBasesSince(from), "値が 1 回変わっただけで土台を読んだ")
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, state.previews.getValue(1).width, "値が 1 回変わっただけで長辺 720 で描いた")

        viewModel.onSliderChange(EditTool.EXPOSURE, 20)
        viewModel.onSliderChange(EditTool.EXPOSURE, 30)

        // 読み直すのは表示中の写真の長辺 720 の土台 1 回だけ（3 回目の値は、読んだ 720 の土台を使い回す）
        assertEquals(
            listOf(FakeEditPreviewRenderer.Call.LoadBase(PickedPhoto(picked[1], 1), 0, dragLongEdge)),
            loadBasesSince(from),
        )
        assertEquals(dragLongEdge, state.previews.getValue(1).width)
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, state.previews.getValue(0).width)
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, state.previews.getValue(2).width)
        // 表示中の絵は、最新の値で描いてある
        val last = renderer.calls.filterIsInstance<FakeEditPreviewRenderer.Call.Render>().last()
        assertEquals(ColorRecipe.of(PhotoEdit(tools = ToolValues.NONE.with(EditTool.EXPOSURE, 30))), last.recipe)
        assertEquals(dragLongEdge, last.base.width)
    }

    @Test
    fun `スライダーを離すと、残しておいた長辺1024の土台で離した時の値を描き、土台を読み直さない`() {
        markBaseWidthsByLongEdge()
        val picked = uris(2)
        viewModel.onPhotosPicked(picked)
        viewModel.onSliderChange(EditTool.EXPOSURE, 20)
        viewModel.onSliderChange(EditTool.EXPOSURE, 30)
        assertEquals(dragLongEdge, state.previews.getValue(0).width, "指で引いている間に長辺 720 で描いていない")

        val from = renderer.calls.size
        viewModel.onSliderFinished()

        assertEquals(listOf("render ${EditPreviewRenderer.PREVIEW_LONG_EDGE}"), callsSince(from))
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, state.previews.getValue(0).width)
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, state.previews.getValue(1).width)
        val last = renderer.calls.filterIsInstance<FakeEditPreviewRenderer.Call.Render>().last()
        assertEquals(ColorRecipe.of(PhotoEdit(tools = ToolValues.NONE.with(EditTool.EXPOSURE, 30))), last.recipe)
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, last.base.width)
    }

    @Test
    fun `スライダーを指で引いている途中で写真を送ると、元の写真は長辺1024の土台で描き直す`() {
        markBaseWidthsByLongEdge()
        viewModel.onPhotosPicked(uris(2))
        viewModel.onSliderChange(EditTool.EXPOSURE, 20)
        viewModel.onSliderChange(EditTool.EXPOSURE, 30)
        assertEquals(dragLongEdge, state.previews.getValue(0).width, "指で引いている間に長辺 720 で描いていない")

        viewModel.showPhoto(1)

        assertNull(state.sliderStart)
        assertEquals(0, state.sliderChanges)
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, state.previews.getValue(0).width)
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, state.previews.getValue(1).width)
    }

    @Test
    fun `1手の操作（値の変更と離すを続けて呼ぶ）は、長辺1024の描き1回だけで、土台を読まない`() {
        // TalkBack の ±5・「0に戻す」・線のタップは、画面が onSliderChange と onSliderFinished を続けて呼ぶ（EditToolPanel）
        markBaseWidthsByLongEdge()
        viewModel.onPhotosPicked(uris(1))
        val from = renderer.calls.size

        viewModel.onSliderChange(EditTool.EXPOSURE, 5)
        viewModel.onSliderFinished()

        assertEquals(listOf("render ${EditPreviewRenderer.PREVIEW_LONG_EDGE}"), callsSince(from))
    }

    @Test
    fun `同じ値が続けて届いても値の変わった回数は1回と数え、離すまで長辺1024のまま`() {
        markBaseWidthsByLongEdge()
        viewModel.onPhotosPicked(uris(1))
        val from = renderer.calls.size

        viewModel.onSliderChange(EditTool.EXPOSURE, 10)
        viewModel.onSliderChange(EditTool.EXPOSURE, 10)
        assertEquals(1, state.sliderChanges)
        viewModel.onSliderFinished()

        assertEquals(0, state.sliderChanges)
        assertEquals(listOf("render ${EditPreviewRenderer.PREVIEW_LONG_EDGE}"), callsSince(from))
    }

    @Test
    fun `指で引いて離した後の1手の操作も、長辺1024の描き1回だけ`() {
        markBaseWidthsByLongEdge()
        viewModel.onPhotosPicked(uris(1))
        viewModel.onSliderChange(EditTool.EXPOSURE, 10)
        viewModel.onSliderChange(EditTool.EXPOSURE, 20)
        viewModel.onSliderFinished()
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, state.previews.getValue(0).width, "テストの前提（離した後に 1024 で描いた）が崩れた")

        val from = renderer.calls.size
        viewModel.onSliderChange(EditTool.EXPOSURE, 25)
        viewModel.onSliderFinished()

        assertEquals(listOf("render ${EditPreviewRenderer.PREVIEW_LONG_EDGE}"), callsSince(from))
    }

    @Test
    fun `指で引き始めて長辺720の土台を読んでいる間も、表示中の写真の前の絵を出したままにする`() {
        markBaseWidthsByLongEdge()
        viewModel.onPhotosPicked(uris(2))
        viewModel.onSliderChange(EditTool.EXPOSURE, 10)
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, state.previews.getValue(0).width, "テストの前提（1 回目は 1024 で描いた）が崩れた")
        val gate = CompletableDeferred<Unit>()
        renderer.loadBaseGate = gate

        viewModel.onSliderChange(EditTool.EXPOSURE, 20)
        assertEquals("load $dragLongEdge", callsSince(renderer.calls.size - 1).single(), "テストの前提（長辺 720 の土台を読んでいる途中）が崩れた")
        assertEquals(setOf(0, 1), state.previews.keys, "長辺 720 の土台を読んでいる間に、表示中の写真の絵が消えた")
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, state.previews.getValue(0).width)

        gate.complete(Unit)
        assertEquals(dragLongEdge, state.previews.getValue(0).width)
    }

    @Test
    fun `指を離して長辺1024で描き直している間も、表示中の写真の前の絵を出したままにする`() {
        markBaseWidthsByLongEdge()
        viewModel.onPhotosPicked(uris(1))
        viewModel.onSliderChange(EditTool.EXPOSURE, 10)
        viewModel.onSliderChange(EditTool.EXPOSURE, 20)
        assertEquals(dragLongEdge, state.previews.getValue(0).width, "テストの前提（指で引いている間に 720 で描いた）が崩れた")
        val gate = CompletableDeferred<Unit>()
        renderer.renderGate = gate

        viewModel.onSliderFinished()
        assertEquals(
            "render ${EditPreviewRenderer.PREVIEW_LONG_EDGE}",
            callsSince(renderer.calls.size - 1).single(),
            "テストの前提（長辺 1024 で描いている途中）が崩れた",
        )
        assertEquals(setOf(0), state.previews.keys, "長辺 1024 で描き直している間に、表示中の写真の絵が消えた")
        assertEquals(dragLongEdge, state.previews.getValue(0).width)

        gate.complete(Unit)
        assertEquals(EditPreviewRenderer.PREVIEW_LONG_EDGE, state.previews.getValue(0).width)
    }

    @Test
    fun `指で引いている間に長辺720の土台を読めないときは、前の絵を外して描けない印だけを付け、離すと1024で描き直す`() {
        markBaseWidthsByLongEdge()
        val ok = renderer.loadBaseResult
        renderer.loadBaseResult = { photo, turns, longEdge ->
            if (longEdge == dragLongEdge) AppResult.Err(AppError.Unknown("IOException")) else ok(photo, turns, longEdge)
        }
        viewModel.onPhotosPicked(uris(1))
        assertEquals(setOf(0), state.previews.keys, "テストの前提（長辺 1024 で描いた）が崩れた")

        viewModel.onSliderChange(EditTool.EXPOSURE, 10)
        viewModel.onSliderChange(EditTool.EXPOSURE, 20)

        // 前の絵と「描けない」の印を同時に出さない
        assertEquals(emptySet(), state.previews.keys, "描けない印と一緒に、前の絵が残った")
        assertEquals(setOf(0), state.failedPreviews)

        viewModel.onSliderFinished()
        assertEquals(setOf(0), state.previews.keys)
        assertEquals(emptySet(), state.failedPreviews)
    }

    // ── 描けない写真の印（タスク 20.6 の③・利用者の決定 2026-11-14）──

    /** [broken] の写真だけ、プレビューの土台（長辺 1024）を読めなくする。フィルターの見本の土台は、どの写真も読める。 */
    private fun failPreviewBaseOf(broken: Set<String>) {
        val ok = renderer.loadBaseResult
        renderer.loadBaseResult = { photo, turns, longEdge ->
            if (photo.uri in broken && longEdge == EditPreviewRenderer.PREVIEW_LONG_EDGE) AppResult.Err(AppError.Unknown("IOException")) else ok(photo, turns, longEdge)
        }
    }

    @Test
    fun `土台を読めない写真にだけ描けない印が付き、まだ描いていない写真には付かない`() {
        val picked = uris(3)
        failPreviewBaseOf(setOf(picked[1]))
        // 1 枚目の絵を描いている途中で止める（2 枚目はまだ読んでいない＝「まだ描いていない」）
        val gate = CompletableDeferred<Unit>()
        renderer.renderGate = gate
        viewModel.onPhotosPicked(picked)
        assertTrue(state.previews.isEmpty(), "テストの前提（まだ 1 枚も描いていない）が崩れた")
        assertEquals(emptySet(), state.failedPreviews, "まだ描いていないだけの写真に、描けない印が付いた")

        gate.complete(Unit)

        // 表示中（0）と右隣（1）を描いた。読めない 2 枚目にだけ印が付き、絵は無い
        assertEquals(setOf(0), state.previews.keys)
        assertEquals(setOf(1), state.failedPreviews)
    }

    @Test
    fun `描けない印は、編集の値を変えても付いたままで、窓の外へ出ると外れ、戻ると付き直す`() {
        val picked = uris(4)
        failPreviewBaseOf(setOf(picked[0]))
        viewModel.onPhotosPicked(picked)
        assertEquals(setOf(0), state.failedPreviews)
        assertEquals(setOf(1), state.previews.keys)

        // 値を変えるたびに読み直すが、読み直している間も印は付いたまま（描き直しの頭で外すと、文言が消えて出る）。
        // 読み直しを途中で止めて、その間の印を見る
        val gate = CompletableDeferred<Unit>()
        renderer.loadBaseGate = gate
        val loadsBefore = loadBaseCount(EditPreviewRenderer.PREVIEW_LONG_EDGE)
        viewModel.selectFilter(FilterId.VIVID)
        assertEquals(loadsBefore + 1, loadBaseCount(EditPreviewRenderer.PREVIEW_LONG_EDGE), "テストの前提（読めない写真を読み直している途中）が崩れた")
        assertEquals(setOf(0), state.failedPreviews, "読み直している間に、描けない印が外れた")
        gate.complete(Unit)
        assertEquals(setOf(0), state.failedPreviews)

        // 3 枚目を表示すると、1 枚目は窓（表示中とその両隣）の外。印は窓の分だけ持つ
        viewModel.showPhoto(2)
        assertEquals(emptySet(), state.failedPreviews)
        viewModel.showPhoto(1)
        assertEquals(setOf(0), state.failedPreviews)
    }

    @Test
    fun `描けない印は、写真を選び直すと消え、読めるようになった写真からは外れる`() {
        val first = uris(2)
        failPreviewBaseOf(setOf(first[0], first[1]))
        viewModel.onPhotosPicked(first)
        assertEquals(setOf(0, 1), state.failedPreviews)
        assertTrue(state.previews.isEmpty())

        // 読めない写真を読み直している途中（描き直しが止まっている間）に、別の写真（どれも読める）へ選び直す。
        // 新しい写真の描き直しが始まる前でも、同じ位置に前の印を残さない
        val loadGate = CompletableDeferred<Unit>()
        renderer.loadBaseGate = loadGate
        viewModel.selectFilter(FilterId.VIVID)
        viewModel.onPhotosPicked(uris(2, prefix = "q"))
        assertEquals(emptySet(), state.failedPreviews, "選び直した直後の別の写真に、前の描けない印が残った")

        // 新しい写真の 1 枚目を描いている途中にも、前の印を戻さない（印は写真の一覧の世代と組で持つ）
        val renderGate = CompletableDeferred<Unit>()
        renderer.renderGate = renderGate
        loadGate.complete(Unit)
        assertTrue(state.previews.isEmpty(), "テストの前提（新しい写真をまだ 1 枚も描いていない）が崩れた")
        assertEquals(emptySet(), state.failedPreviews, "新しい写真を描いている途中に、前の描けない印が戻った")
        renderGate.complete(Unit)
        assertEquals(emptySet(), state.failedPreviews)
        assertEquals(setOf(0, 1), state.previews.keys)

        // 写真の選択の段に戻っても残さない
        viewModel.onPhotosPicked(first)
        assertEquals(setOf(0, 1), state.failedPreviews)
        viewModel.requestLeave()
        assertEquals(ComposeStep.SELECTING, state.step)
        assertEquals(emptySet(), state.failedPreviews)
    }

    @Test
    fun `描けない印は、同じ写真が読めるようになって描けたら外れる`() {
        val picked = uris(1)
        val ok = renderer.loadBaseResult
        renderer.loadBaseResult = { _, _, _ -> AppResult.Err(AppError.Unknown("IOException")) }
        viewModel.onPhotosPicked(picked)
        assertEquals(setOf(0), state.failedPreviews)

        // 次の描き直し（フィルターを選ぶ）では読める
        renderer.loadBaseResult = ok
        viewModel.selectFilter(FilterId.VIVID)
        assertEquals(setOf(0), state.previews.keys)
        assertEquals(emptySet(), state.failedPreviews, "描けた写真に、描けない印が残った")
    }

    @Test
    fun `装備は保存の部品の値を写して並べ、1個も無ければ保存せず、失敗は案内し、保存できたら閉じる`() {
        assertEquals(Loadout.DEFAULT, state.loadout)
        assertEquals(EditTool.entries.toList(), state.toolsToShow)
        loadoutStore.loadoutFlow.value = Loadout(listOf(EditTool.FADE, EditTool.EXPOSURE))
        assertEquals(listOf(EditTool.FADE, EditTool.EXPOSURE), state.toolsToShow)

        viewModel.openLoadout()
        assertTrue(state.showLoadout)
        // 1 個も選ばない装備は、保存の部品に渡さない（要件 7.5）
        viewModel.saveLoadout(Loadout(emptyList()))
        assertTrue(loadoutStore.saveCalls.isEmpty())

        loadoutStore.saveResult = AppResult.Err(AppError.Unknown("IOException"))
        viewModel.saveLoadout(Loadout(listOf(EditTool.CONTRAST)))
        assertTrue(state.loadoutSaveFailed)
        assertTrue(state.showLoadout)
        assertEquals(listOf(EditTool.FADE, EditTool.EXPOSURE), state.toolsToShow)

        loadoutStore.saveResult = AppResult.Ok(Unit)
        viewModel.saveLoadout(Loadout(listOf(EditTool.CONTRAST)))
        assertFalse(state.loadoutSaveFailed)
        assertFalse(state.showLoadout)
        assertEquals(listOf(EditTool.CONTRAST), state.toolsToShow)
        // 失敗の記録は保存の部品が行う（この画面は記録し直さない）
        assertTrue(analytics.errors.isEmpty())
    }

    @Test
    fun `「次へ」と戻るで編集の内容と履歴を保ち、キャプションと公開範囲は元に戻すの対象にしない`() {
        viewModel.onPhotosPicked(uris(2))
        viewModel.showPhoto(1)
        viewModel.selectFilter(FilterId.DRAMA)
        viewModel.onSliderChange(EditTool.CONTRAST, 25)
        viewModel.onSliderFinished()
        val photos = state.photos

        viewModel.goToInfo()
        assertEquals(ComposeStep.INFO, state.step)
        assertEquals(photos, state.photos)
        viewModel.onCaptionChange("夕焼け")
        viewModel.selectVisibility(Visibility.PRIVATE)

        viewModel.backToEditing()
        assertEquals(ComposeStep.EDITING, state.step)
        assertEquals(photos, state.photos)
        assertEquals(1, state.currentIndex)

        // 元に戻すのはスライダーの 1 手だけで、キャプションと公開範囲は変わらない（要件 6.11）
        viewModel.undo()
        assertEquals(PhotoEdit(filter = FilterId.DRAMA), state.photos[1].edit)
        assertEquals("夕焼け", state.caption)
        assertEquals(Visibility.PRIVATE, state.visibility)
    }

    // ── 写真の写し・途中の保存・作り直し（Kiro android-edit-tools 18.3） ──

    /** 大文字の UUID（途中の印の形：design.md:981）。 */
    private val upperUuid = Regex("[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}")

    private fun summary(id: String) =
        LocalDraftSummary(DraftId(id), savedAtEpochMillis = 1L, photoCount = 1, thumbnailUri = null, isBroken = false)

    @Test
    fun `写真を選ぶと、確かめてから今の利用者のフォルダへ写し、新しい大文字の印で編集と履歴を空から始める`() {
        signIn()
        val picked = uris(3)
        probe.unreadable += picked[1]
        viewModel.onPhotosPicked(picked)

        // 読めた写真だけを、読めた写真を詰めた並びの番号で写す
        assertEquals(
            listOf<Pair<Uid, List<PickedPhoto>>>(uid to listOf(PickedPhoto(picked[0], 0), PickedPhoto(picked[2], 1))),
            importer.calls,
        )
        assertEquals(listOf(copied(picked[0], 0), copied(picked[2], 1)), state.photos.map { it.photo })
        assertTrue(state.photos.all { it.edit == PhotoEdit.NONE && it.history == EditHistory.EMPTY })
        val first = writtenSession()
        assertTrue(upperUuid.matches(first.sessionId), "印が大文字の UUID でない: ${first.sessionId}")
        assertEquals(listOf("session/photo-0", "session/photo-1"), first.photos.map { it.file })

        // 選び直すと、新しい印で編集と履歴を空から始める（要件 6.10）
        viewModel.selectFilter(FilterId.VIVID)
        viewModel.onPhotosPicked(uris(1, prefix = "q"))
        assertEquals(listOf(PhotoEdit.NONE), state.photos.map { it.edit })
        assertFalse(state.canUndo)
        val second = writtenSession()
        assertTrue(upperUuid.matches(second.sessionId))
        assertNotEquals(first.sessionId, second.sessionId)
    }

    @Test
    fun `確かめと写しの間は読み込み中で、編集の操作と「次へ」を受け付けない`() {
        signIn()
        viewModel.onPhotosPicked(uris(1))
        viewModel.selectFilter(FilterId.SOFT)
        val gate = CompletableDeferred<Unit>()
        importer.gate = gate

        viewModel.onPhotosPicked(uris(1, prefix = "b"))
        assertTrue(state.isChecking)
        val before = state.photos
        viewModel.selectFilter(FilterId.VIVID)
        viewModel.undo()
        viewModel.onSliderChange(EditTool.EXPOSURE, 30)
        viewModel.openTool(EditTool.CROP_AND_ROTATE)
        viewModel.goToInfo()
        assertEquals(before, state.photos)
        assertNull(state.cropSession)
        assertNull(state.sliderStart)
        assertEquals(ComposeStep.EDITING, state.step)

        gate.complete(Unit)
        assertFalse(state.isChecking)
        assertEquals(listOf(copied(uris(1, prefix = "b")[0], 0)), state.photos.map { it.photo })
    }

    @Test
    fun `途中は変わってから待ちの後に書き、スライダーを動かしている間は書かない`() {
        signIn()
        val vm = newViewModel(handle = SavedStateHandle(), saveDelayMillis = 0)
        vm.onPhotosPicked(uris(1))
        assertEquals(1, saveCount())

        vm.onSliderChange(EditTool.EXPOSURE, 20)
        vm.onSliderChange(EditTool.EXPOSURE, 40)
        vm.onStop()
        assertEquals(1, saveCount(), "スライダーを動かしている間に書いた")

        vm.onSliderFinished()
        assertEquals(2, saveCount())
        val written = sessionStore.calls.filterIsInstance<FakeEditSessionStore.Call.Save>().last()
        assertEquals(uid, written.uid)
        assertEquals(40, written.document.photos.single().edit.tools[EditTool.EXPOSURE])

        vm.onCaptionChange("夕焼け")
        assertEquals(3, saveCount())
        assertEquals("夕焼け", sessionStore.calls.filterIsInstance<FakeEditSessionStore.Call.Save>().last().document.caption)
        vm.goToInfo()
        assertEquals(4, saveCount())
        assertTrue(sessionStore.calls.filterIsInstance<FakeEditSessionStore.Call.Save>().last().document.enteredInfo)
    }

    @Test
    fun `onStopでは待ちの途中でもすぐ書く`() {
        signIn()
        viewModel.onPhotosPicked(uris(1))
        viewModel.selectFilter(FilterId.CLEAR)
        // 待ちは終わらない（Long.MAX_VALUE）ので、まだ書いていない
        assertEquals(0, saveCount())

        viewModel.onStop()
        assertEquals(1, saveCount())
        val written = sessionStore.calls.filterIsInstance<FakeEditSessionStore.Call.Save>().single().document
        assertEquals(FilterId.CLEAR, written.photos.single().edit.filter)
    }

    @Test
    fun `作り直されたとき、途中があれば今の利用者の途中を読み戻し、投稿情報の段から続ける（履歴は空）`() {
        signIn()
        viewModel.onPhotosPicked(uris(2))
        viewModel.selectFilter(FilterId.VIVID)
        viewModel.goToInfo()
        viewModel.onCaptionChange("夕焼け")
        val saved = writtenSession()
        sessionStore.loadResults[uid] = SessionLoad.Restored(saved, state.photos.map { it.photo })
        val callsBefore = sessionCalls().size

        val recreated = recreated()
        val restored = recreated.state.value

        assertEquals(listOf<FakeEditSessionStore.Call>(FakeEditSessionStore.Call.Load(uid)), sessionCalls().drop(callsBefore))
        assertEquals(ComposeStep.INFO, restored.step)
        assertEquals(state.photos.map { it.photo }, restored.photos.map { it.photo })
        assertEquals(listOf<FilterId?>(FilterId.VIVID, null), restored.photos.map { it.edit.filter })
        assertTrue(restored.photos.all { it.history == EditHistory.EMPTY })
        assertEquals("夕焼け", restored.caption)
        assertFalse(restored.sessionUnreadable)
        // 作り直した後も、同じ印の途中として書き続ける
        assertEquals(saved.sessionId, writtenSession(recreated).sessionId)
    }

    @Test
    fun `作り直されたとき、途中を読めなければ案内を出して写真の選択の段にし、案内はOKで消す`() {
        signIn()
        viewModel.onPhotosPicked(uris(1))
        listOf<SessionLoad>(SessionLoad.Unreadable, SessionLoad.None).forEach { load ->
            sessionStore.loadResults[uid] = load
            val recreated = recreated()
            val restored = recreated.state.value
            assertEquals(ComposeStep.SELECTING, restored.step, "$load")
            assertEquals(emptyList(), restored.photos, "$load")
            assertTrue(restored.sessionUnreadable, "$load")
            // 選び直せる（要件 12.3）。案内は OK で消す
            recreated.dismissNotice()
            assertFalse(recreated.state.value.sessionUnreadable, "$load")
        }
    }

    @Test
    fun `作り直されたとき、別の利用者の途中は読まない（今の利用者のフォルダだけを読む）`() {
        signIn()
        viewModel.onPhotosPicked(uris(1))
        sessionStore.loadResults[uid] = SessionLoad.Restored(writtenSession(), state.photos.map { it.photo })
        val callsBefore = sessionCalls().size

        signedIn = otherUid
        val restored = recreated().state.value

        assertEquals(listOf<FakeEditSessionStore.Call>(FakeEditSessionStore.Call.Load(otherUid)), sessionCalls().drop(callsBefore))
        assertEquals(emptyList(), restored.photos)
        assertTrue(restored.sessionUnreadable)
    }

    @Test
    fun `初めて開いたときは前の画面が残した途中を消し、今の利用者の下書きの件数を読む`() {
        signIn()
        draftStore.summaries[uid] = listOf(summary("D1"), summary("D2"))
        val vm = newViewModel(handle = SavedStateHandle())

        assertEquals(listOf<FakeEditSessionStore.Call>(FakeEditSessionStore.Call.Clear(uid)), sessionCalls())
        assertEquals(2, vm.state.value.draftCount)
    }

    @Test
    fun `下書きの件数を読み終えた印は、読んだ後と読まない時（ログインしていない）に立ち、写真の選択の段に戻っても残る`() {
        // 初めの値は「まだ読んでいない」（この間の件数 0 を「0 件」と読ませない：利用者の判断 U7）
        assertFalse(PostComposerUiState().draftCountLoaded)
        // ログインしていない時は件数を読まないが、印は立てる（立てないと、画面が写真選択画面を自動で開けない）
        assertTrue(state.draftCountLoaded)
        assertEquals(0, state.draftCount)

        signIn()
        draftStore.summaries[uid] = listOf(summary("D1"))
        val vm = newViewModel(handle = SavedStateHandle())
        assertTrue(vm.state.value.draftCountLoaded)
        assertEquals(1, vm.state.value.draftCount)

        // 写真の選択の段に戻ると状態を作り直すが、印は残す
        vm.onPhotosPicked(uris(1))
        assertEquals(ComposeStep.EDITING, vm.state.value.step)
        vm.requestLeave()
        assertEquals(ComposeStep.SELECTING, vm.state.value.step)
        assertTrue(vm.state.value.draftCountLoaded)
    }

    @Test
    fun `アップロード中に開いた画面は、残っていた途中を消さない（保存中なら消す）`() {
        signIn()
        publisher.state.value = PublishState.Uploading(done = 0, total = 2)
        newViewModel(handle = SavedStateHandle())
        assertTrue(sessionCalls().isEmpty(), "アップロード中に途中を消した: ${sessionCalls()}")

        // 保存中は写真を読まないので、設計どおり消す（上の確かめが空振りでないことも、ここで見る）
        publisher.state.value = PublishState.Saving
        newViewModel(handle = SavedStateHandle())
        assertEquals(listOf<FakeEditSessionStore.Call>(FakeEditSessionStore.Call.Clear(uid)), sessionCalls())
    }

    @Test
    fun `アップロード中は写真を選んでも、確かめも写しも始めない（保存中なら選べる）`() {
        signIn()
        publisher.state.value = PublishState.Uploading(done = 1, total = 2)
        viewModel.onPhotosPicked(uris(2))

        assertTrue(importer.calls.isEmpty(), "アップロード中に写した")
        assertTrue(probe.probed.isEmpty())
        assertFalse(state.isChecking)
        assertEquals(ComposeStep.SELECTING, state.step)

        publisher.state.value = PublishState.Saving
        viewModel.onPhotosPicked(uris(1))
        assertEquals(1, importer.calls.size)
        assertEquals(ComposeStep.EDITING, state.step)
    }

    @Test
    fun `破棄すると今の利用者の途中を丸ごと消して写真の選択の段に戻り、作り直しても途中を読まない`() {
        signIn()
        viewModel.onPhotosPicked(uris(1))
        viewModel.selectFilter(FilterId.VIVID)
        viewModel.requestLeave()
        viewModel.answerLeave(LeaveChoice.DISCARD)

        assertEquals(listOf<FakeEditSessionStore.Call>(FakeEditSessionStore.Call.Clear(uid)), sessionCalls())
        assertEquals(ComposeStep.SELECTING, state.step)
        assertNull(state.leaveQuestion)
        // 途中があることの印も消えるので、作り直した画面は読まない（初めて開いたときと同じく残りを消す）
        recreated()
        assertFalse(sessionCalls().any { it is FakeEditSessionStore.Call.Load })
    }

    // ── 離れるときの確かめ・下書き・投稿の後始末（Kiro android-edit-tools 18.4） ──

    @Test
    fun `離れるときは、変更があるときだけ確かめを出し、変更が無ければそのまま写真の選択の段に戻る`() {
        viewModel.onPhotosPicked(uris(1))
        viewModel.requestLeave()
        assertNull(state.leaveQuestion, "変更が無いのに確かめを出した")
        assertEquals(ComposeStep.SELECTING, state.step)

        viewModel.onPhotosPicked(uris(1, prefix = "q"))
        viewModel.selectFilter(FilterId.VIVID)
        viewModel.requestLeave()
        assertEquals(LeaveQuestion.DISCARD_OR_DRAFT, state.leaveQuestion)
        assertEquals(ComposeStep.EDITING, state.step)
        // 編集を続ける：何も失わない
        viewModel.answerLeave(LeaveChoice.CONTINUE)
        assertNull(state.leaveQuestion)
        assertEquals(listOf<FilterId?>(FilterId.VIVID), filters())

        // 全部元に戻すと変更なし（履歴が残っているだけ）。キャプションだけでも変更あり（設計への問い 17）
        viewModel.undo()
        viewModel.requestLeave()
        assertEquals(ComposeStep.SELECTING, state.step)
        viewModel.onPhotosPicked(uris(1, prefix = "r"))
        viewModel.goToInfo()
        viewModel.onCaptionChange("夕焼け")
        viewModel.backToEditing()
        viewModel.requestLeave()
        assertEquals(LeaveQuestion.DISCARD_OR_DRAFT, state.leaveQuestion)
    }

    @Test
    fun `選び直しは、どれかの写真に編集があるときだけ確かめ、選び直すと編集と履歴を空にする`() {
        viewModel.onPhotosPicked(uris(2))
        viewModel.requestRepick()
        assertNull(state.leaveQuestion)

        viewModel.showPhoto(1)
        viewModel.selectFilter(FilterId.SOFT)
        viewModel.requestRepick()
        assertEquals(LeaveQuestion.REPICK, state.leaveQuestion)
        // やめる：何も失わない
        viewModel.answerLeave(LeaveChoice.CONTINUE)
        assertNull(state.leaveQuestion)
        assertEquals(listOf<FilterId?>(null, FilterId.SOFT), filters())

        // 選び直す：確かめを閉じ、届いた写真で編集と履歴を空から始める（要件 6.10）
        viewModel.requestRepick()
        viewModel.answerLeave(LeaveChoice.DISCARD)
        assertNull(state.leaveQuestion)
        assertEquals(ComposeStep.EDITING, state.step)
        viewModel.onPhotosPicked(uris(2, prefix = "q"))
        assertEquals(listOf(PhotoEdit.NONE, PhotoEdit.NONE), state.photos.map { it.edit })
        assertTrue(state.photos.all { it.history == EditHistory.EMPTY })
        assertEquals(0, state.currentIndex)
    }

    /** ログインして下書きを開き、1 枚目を編集して投稿情報の段に進む。戻り値は、その編集の途中の印。 */
    private fun openDraftAndEnterInfo(): String {
        signIn()
        prepareDraft()
        viewModel.openDraft(draft1)
        viewModel.selectFilter(FilterId.COOL)
        viewModel.goToInfo()
        return writtenSession().sessionId
    }

    @Test
    fun `投稿が成功したら、始めた時の途中を印つきで消し、開いていた下書きを消し、履歴を空にする`() {
        val sessionId = openDraftAndEnterInfo()
        val sessionBefore = sessionCalls().size
        val draftsBefore = draftStore.calls.size

        viewModel.publish()

        assertTrue(state.published)
        assertEquals(
            listOf<FakeEditSessionStore.Call>(FakeEditSessionStore.Call.ClearSession(uid, sessionId)),
            sessionCalls().drop(sessionBefore),
        )
        assertEquals(
            listOf<FakeLocalDraftRepository.Call>(FakeLocalDraftRepository.Call.Delete(uid, draft1)),
            draftStore.calls.drop(draftsBefore),
        )
        assertTrue(state.photos.all { it.history == EditHistory.EMPTY })
        assertFalse(state.canUndo)
    }

    @Test
    fun `投稿に失敗したら、途中も下書きも消さず、履歴も残す`() {
        openDraftAndEnterInfo()
        val sessionBefore = sessionCalls().size
        val draftsBefore = draftStore.calls.size
        publisher.result = AppResult.Err(AppError.Network)

        viewModel.publish()

        assertEquals(AppError.Network, state.publishError)
        assertTrue(sessionCalls().drop(sessionBefore).isEmpty(), "失敗で途中を消した: ${sessionCalls().drop(sessionBefore)}")
        assertTrue(draftStore.calls.drop(draftsBefore).none { it is FakeLocalDraftRepository.Call.Delete }, "失敗で下書きを消した")
        assertTrue(state.canUndo)
    }

    @Test
    fun `保存中に画面を開き直して別の写真を選び、その後に前の投稿が成功しても、新しい編集の途中は消さない`() {
        signIn()
        viewModel.onPhotosPicked(uris(1))
        viewModel.goToInfo()
        val firstId = writtenSession().sessionId
        val gate = CompletableDeferred<AppResult<PostId>>()
        publisher.gate = gate
        viewModel.publish()
        publisher.state.value = PublishState.Saving

        // 保存中は離れてよい。閉じて、新しい投稿の画面（戻る履歴の新しい 1 枚）を開き、別の写真を選ぶ
        val second = newViewModel(handle = SavedStateHandle())
        second.onPhotosPicked(uris(1, prefix = "n"))
        val secondId = writtenSession(second).sessionId
        assertNotEquals(firstId, secondId)
        val before = sessionCalls().size

        publisher.state.value = PublishState.Succeeded(PostId("P1"))
        gate.complete(AppResult.Ok(PostId("P1")))

        assertTrue(state.published)
        // 前の投稿の後始末は、控えた前の印でだけ消す（丸ごと消す clear を呼ばない＝新しい印の途中は残る：design.md:989）
        assertEquals(
            listOf<FakeEditSessionStore.Call>(FakeEditSessionStore.Call.ClearSession(uid, firstId)),
            sessionCalls().drop(before),
        )
    }

    @Test
    fun `後始末のuidは投稿を始めた時の値で、途中でログアウトしても同じuidで消す`() {
        assertCleanupUsesUidAtStart(changeTo = null)
    }

    @Test
    fun `後始末のuidは投稿を始めた時の値で、途中で別の人に替わっても前の人のuidで消す`() {
        assertCleanupUsesUidAtStart(changeTo = otherUid)
    }

    /** 下書きから始めた投稿の途中で、今の利用者を [changeTo] に変えてから成功させ、後始末が始めた時の uid だけを使うことを見る。 */
    private fun assertCleanupUsesUidAtStart(changeTo: Uid?) {
        val sessionId = openDraftAndEnterInfo()
        val gate = CompletableDeferred<AppResult<PostId>>()
        publisher.gate = gate
        viewModel.publish()
        val sessionBefore = sessionCalls().size
        val draftsBefore = draftStore.calls.size

        signedIn = changeTo
        gate.complete(AppResult.Ok(PostId("P1")))

        assertTrue(state.published)
        assertEquals(
            listOf<FakeEditSessionStore.Call>(FakeEditSessionStore.Call.ClearSession(uid, sessionId)),
            sessionCalls().drop(sessionBefore),
        )
        assertEquals(
            listOf<FakeLocalDraftRepository.Call>(FakeLocalDraftRepository.Call.Delete(uid, draft1)),
            draftStore.calls.drop(draftsBefore),
        )
    }

    @Test
    fun `進行中の投稿がある間は下書きを開かず、一覧は見られる`() {
        signIn()
        prepareDraft()
        draftStore.summaries[uid] = listOf(summary(draft1.value))
        listOf<PublishState>(PublishState.Uploading(done = 0, total = 1), PublishState.Saving).forEach { progress ->
            publisher.state.value = progress
            viewModel.openDrafts()
            assertTrue(state.showDrafts, "$progress")
            assertEquals(listOf(summary(draft1.value)), state.drafts, "$progress")
            viewModel.openDraft(draft1)
            assertTrue(draftStore.calls.none { it is FakeLocalDraftRepository.Call.Open }, "$progress の間に下書きを開いた")
            assertFalse(state.isOpeningDraft, "$progress")
        }

        publisher.state.value = PublishState.Idle
        viewModel.openDraft(draft1)
        assertEquals(
            listOf<FakeLocalDraftRepository.Call>(FakeLocalDraftRepository.Call.Open(uid, draft1)),
            draftStore.calls.filterIsInstance<FakeLocalDraftRepository.Call.Open>(),
        )
    }

    @Test
    fun `下書きを開いている間は読み込み中で、開くと写真・編集・入力を戻し、新しい印で編集の段から始めて「編集」を送る`() {
        signIn()
        val photos = prepareDraft()
        val gate = CompletableDeferred<Unit>()
        draftStore.openGate = gate
        viewModel.onScreenShown()

        viewModel.openDraft(draft1)
        assertTrue(state.isOpeningDraft)
        assertEquals(ComposeStep.SELECTING, state.step)

        gate.complete(Unit)
        assertFalse(state.isOpeningDraft)
        assertEquals(ComposeStep.EDITING, state.step)
        assertEquals(photos, state.photos.map { it.photo })
        assertEquals(listOf(PhotoEdit(filter = FilterId.VINTAGE), PhotoEdit.NONE), state.photos.map { it.edit })
        assertTrue(state.photos.all { it.history == EditHistory.EMPTY })
        assertEquals("下書きの文", state.caption)
        assertEquals(Visibility.FOLLOWERS, state.visibility)
        assertEquals(draft1, state.draftId)
        assertEquals(listOf(ScreenName.POST, ScreenName.EDIT), analytics.screens)
        // 開いた時の途中の文書は印が空なので、新しい印で書き直す（下書きの ID つき・写真は下書きのフォルダを指す）
        val written = writtenSession()
        assertTrue(upperUuid.matches(written.sessionId), "印が大文字の UUID でない: ${written.sessionId}")
        assertEquals(draft1.value, written.draftId)
        assertEquals(listOf("drafts/DRAFT-1/photo-0", "drafts/DRAFT-1/photo-1"), written.photos.map { it.file })
    }

    @Test
    fun `読めない下書きは案内を出して写真の選択の段のままにし、案内はOKで消す`() {
        signIn()
        viewModel.openDraft(DraftId("BROKEN"))

        assertEquals(DraftNotice.DRAFT_BROKEN, state.draftNotice)
        assertFalse(state.isOpeningDraft)
        assertEquals(ComposeStep.SELECTING, state.step)
        viewModel.dismissNotice()
        assertNull(state.draftNotice)
    }

    @Test
    fun `下書きに保存すると、1枚目の写真とその編集で見本を作り、保存できたら途中を消して画面を閉じる`() {
        signIn()
        val picked = uris(2)
        viewModel.onPhotosPicked(picked)
        viewModel.selectFilter(FilterId.WARM)
        viewModel.goToInfo()
        viewModel.onCaptionChange("あとで投稿")
        viewModel.selectVisibility(Visibility.PRIVATE)
        viewModel.backToEditing()
        val sessionBefore = sessionCalls().size

        viewModel.requestLeave()
        viewModel.answerLeave(LeaveChoice.SAVE_DRAFT)

        assertEquals(
            listOf<FakeEditPreviewRenderer.Call>(
                FakeEditPreviewRenderer.Call.DraftThumbnail(
                    copied(picked[0], 0).toPickedPhoto(0),
                    PhotoEdit(filter = FilterId.WARM),
                    EditPreviewRenderer.DRAFT_THUMBNAIL_EDGE,
                ),
            ),
            renderer.calls.filterIsInstance<FakeEditPreviewRenderer.Call.DraftThumbnail>(),
        )
        val saved = draftStore.calls.filterIsInstance<FakeLocalDraftRepository.Call.Save>().single()
        assertEquals(uid, saved.uid)
        assertContentEquals(FakeEditPreviewRenderer.THUMBNAIL_JPEG, saved.thumbnailJpeg)
        assertNull(saved.document.draftId)
        assertEquals("あとで投稿", saved.document.caption)
        assertEquals(Visibility.PRIVATE.raw, saved.document.visibilityRaw)
        assertFalse(saved.document.enteredInfo)
        assertEquals(listOf("session/photo-0", "session/photo-1"), saved.document.photos.map { it.file })
        assertEquals(listOf(PhotoEdit(filter = FilterId.WARM), PhotoEdit.NONE), saved.document.photos.map { it.edit })
        // 新しい下書きを保存できた後に途中を消すのはこの画面（design.md:942）。保存できたら画面を閉じる
        assertEquals(listOf<FakeEditSessionStore.Call>(FakeEditSessionStore.Call.Clear(uid)), sessionCalls().drop(sessionBefore))
        assertTrue(state.draftSaved)
        assertFalse(state.isSavingDraft)
        assertNull(state.leaveQuestion)
    }

    @Test
    fun `下書きが上限か保存に失敗したら案内を出し、編集の状態を変えず、途中も消さない`() {
        signIn()
        viewModel.onPhotosPicked(uris(1))
        viewModel.selectFilter(FilterId.PASTEL)
        val photos = state.photos
        listOf<Pair<DraftSaveResult, DraftNotice>>(
            DraftSaveResult.LimitReached to DraftNotice.LIMIT_REACHED,
            DraftSaveResult.Failed(AppError.Unknown("IOException")) to DraftNotice.SAVE_FAILED,
        ).forEach { (result, notice) ->
            draftStore.saveResult = result
            val gate = CompletableDeferred<Unit>()
            draftStore.saveGate = gate
            viewModel.requestLeave()
            viewModel.answerLeave(LeaveChoice.SAVE_DRAFT)
            assertTrue(state.isSavingDraft, "$result")
            gate.complete(Unit)

            assertEquals(notice, state.draftNotice, "$result")
            assertFalse(state.isSavingDraft, "$result")
            assertFalse(state.draftSaved, "$result")
            assertNull(state.leaveQuestion, "$result")
            assertEquals(photos, state.photos, "$result")
            assertEquals(ComposeStep.EDITING, state.step, "$result")
            viewModel.dismissNotice()
        }
        assertTrue(sessionCalls().isEmpty(), "保存できなかったのに途中を消した: ${sessionCalls()}")
    }

    @Test
    fun `写せなかった写真がある編集は、下書きを保存せずに保存の失敗を出し、途中も書かない`() {
        // ログインしているが、写しを作れなかった（偽物の既定＝元の URI のまま・relativeFile は null）
        signedIn = uid
        viewModel.onPhotosPicked(uris(1))
        viewModel.selectFilter(FilterId.VIVID)
        viewModel.saveDraft()

        assertEquals(DraftNotice.SAVE_FAILED, state.draftNotice)
        assertTrue(draftStore.calls.none { it is FakeLocalDraftRepository.Call.Save })
        assertFalse(state.draftSaved)
        viewModel.onStop()
        assertEquals(0, saveCount())
    }

    // ── 下書きの保存と、投稿・編集・入力の重なり（問い 34・利用者の決定 2026-11-13）──

    /** 下書きの保存を、失敗の結果で途中に止める。戻り値を完了させると、保存の失敗が戻る（画面は閉じず、編集に戻れる）。 */
    private fun holdDraftSaveThenFail(): CompletableDeferred<Unit> {
        draftStore.saveResult = DraftSaveResult.Failed(AppError.Unknown("IOException"))
        val gate = CompletableDeferred<Unit>()
        draftStore.saveGate = gate
        return gate
    }

    private fun draftSaveCount(): Int = draftStore.calls.count { it is FakeLocalDraftRepository.Call.Save }

    @Test
    fun `この画面の投稿の途中は、確かめのダイアログからも直にも下書きに保存せず、投稿が失敗で戻れば保存できる`() {
        // ログインして写しを作れる形にする（そうでないと「保存の失敗」の分岐に入り、止めが無くても保存が呼ばれない）
        signIn()
        val gate = publishAndHoldWhileSaving()
        viewModel.backToEditing()
        assertTrue(state.isPublishing)

        // 変更（フィルター）があるので確かめが出る。「下書きに保存」を選んでも、直に呼んでも保存しない
        viewModel.requestLeave()
        assertEquals(LeaveQuestion.DISCARD_OR_DRAFT, state.leaveQuestion)
        viewModel.answerLeave(LeaveChoice.SAVE_DRAFT)
        viewModel.saveDraft()

        assertEquals(0, draftSaveCount(), "この画面の投稿の途中に下書きを保存した")
        assertTrue(renderer.calls.none { it is FakeEditPreviewRenderer.Call.DraftThumbnail }, "この画面の投稿の途中に下書きの見本を作った")
        assertFalse(state.isSavingDraft)
        assertFalse(state.draftSaved)
        // 案内は出さず、確かめも出たまま（押せない形で見せるのは画面）
        assertNull(state.draftNotice)
        assertEquals(LeaveQuestion.DISCARD_OR_DRAFT, state.leaveQuestion)

        // 投稿が失敗で戻れば、同じ確かめから保存できる
        publisher.state.value = PublishState.Failed(AppError.PermissionDenied)
        gate.complete(AppResult.Err(AppError.PermissionDenied))
        assertFalse(state.isPublishing)
        viewModel.answerLeave(LeaveChoice.SAVE_DRAFT)
        assertEquals(1, draftSaveCount())
        assertTrue(state.draftSaved)
    }

    @Test
    fun `下書きを保存している間は、編集の操作と写真の選び直しを受け付けず、保存に失敗した後は受け付ける`() {
        signIn()
        viewModel.onPhotosPicked(uris(2))
        viewModel.selectFilter(FilterId.VIVID)
        viewModel.selectFilter(FilterId.SOFT)
        viewModel.undo()
        // 元に戻す・やり直しのどちらも効く状態にしてから保存する
        assertTrue(state.canUndo)
        assertTrue(state.canRedo)
        val gate = holdDraftSaveThenFail()
        viewModel.saveDraft()
        assertTrue(state.isSavingDraft)
        val before = state.photos
        val importsBefore = importer.calls.size

        viewModel.selectFilter(FilterId.MONOCHROME)
        assertEquals(before, state.photos, "下書きの保存中にフィルターの選択が効いた")
        viewModel.onSliderChange(EditTool.EXPOSURE, 50)
        assertEquals(before, state.photos, "下書きの保存中にスライダーが効いた")
        assertNull(state.sliderStart)
        viewModel.undo()
        assertEquals(before, state.photos, "下書きの保存中に元に戻すが効いた")
        viewModel.redo()
        assertEquals(before, state.photos, "下書きの保存中にやり直しが効いた")
        viewModel.openTool(EditTool.EXPOSURE)
        assertNull(state.openTool, "下書きの保存中にツールが開いた")
        viewModel.onPhotosPicked(uris(1, prefix = "q"))
        assertEquals(before, state.photos, "下書きの保存中に写真の選び直しが効いた")
        assertFalse(state.isChecking, "下書きの保存中に写真の確かめを始めた")
        assertEquals(importsBefore, importer.calls.size, "下書きの保存中に写真を写した")
        // 保存する文書は、押した時の内容
        val saved = draftStore.calls.filterIsInstance<FakeLocalDraftRepository.Call.Save>().single()
        assertEquals(before.map { it.edit }, saved.document.photos.map { it.edit })

        // 保存に失敗して編集に戻ったら、どれも受け付ける（止めすぎない）
        gate.complete(Unit)
        assertFalse(state.isSavingDraft)
        assertEquals(DraftNotice.SAVE_FAILED, state.draftNotice)
        viewModel.dismissNotice()
        viewModel.redo()
        assertEquals(FilterId.SOFT, filters()[0])
        viewModel.undo()
        assertEquals(FilterId.VIVID, filters()[0])
        viewModel.selectFilter(FilterId.MONOCHROME)
        assertEquals(FilterId.MONOCHROME, filters()[0])
        viewModel.openTool(EditTool.EXPOSURE)
        assertEquals(EditTool.EXPOSURE, state.openTool)
        viewModel.onSliderChange(EditTool.EXPOSURE, 50)
        viewModel.onSliderFinished()
        assertEquals(50, state.photos[0].edit.tools[EditTool.EXPOSURE])
        viewModel.onPhotosPicked(uris(1, prefix = "q"))
        assertEquals(1, state.photos.size)
    }

    @Test
    fun `下書きを保存している間は、トリミング・回転を確定できず、保存に失敗した後は確定できる`() {
        signIn()
        viewModel.onPhotosPicked(uris(1))
        viewModel.openTool(EditTool.CROP_AND_ROTATE)
        viewModel.rotateRight()
        val gate = holdDraftSaveThenFail()
        // 画面からは届かない重なり（トリミング・回転の画面の間は「下書きに保存」を押せない）。ViewModel の止めを直に見る
        viewModel.saveDraft()
        assertTrue(state.isSavingDraft)
        val before = state.photos

        viewModel.confirmCrop()
        assertEquals(before, state.photos, "下書きの保存中にトリミング・回転を確定した")
        assertNotNull(state.cropSession)

        gate.complete(Unit)
        viewModel.dismissNotice()
        viewModel.confirmCrop()
        assertNull(state.cropSession)
        assertTrue(before != state.photos, "保存に失敗した後もトリミング・回転を確定できない")
    }

    @Test
    fun `下書きを保存している間は、キャプションと公開範囲の入力を受け付けず、投稿もできず、保存に失敗した後はできる`() {
        signIn()
        enterInfo()
        viewModel.onCaptionChange("保存する文")
        viewModel.selectVisibility(Visibility.FOLLOWERS)
        assertTrue(state.canPublish)
        val gate = holdDraftSaveThenFail()
        viewModel.saveDraft()
        assertTrue(state.isSavingDraft)

        viewModel.onCaptionChange("後から打った文")
        assertEquals("保存する文", state.caption, "下書きの保存中にキャプションの入力が効いた")
        viewModel.selectVisibility(Visibility.PRIVATE)
        assertEquals(Visibility.FOLLOWERS, state.visibility, "下書きの保存中に公開範囲の選択が効いた")
        // 保存が終わると編集の途中を消して画面を閉じるので、その間は投稿を始めない
        assertFalse(state.canPublish, "下書きの保存中に投稿ボタンを押せる")
        viewModel.publish()
        assertTrue(publisher.drafts.isEmpty(), "下書きの保存中に投稿を始めた")
        assertFalse(state.isPublishing)

        // 保存に失敗して戻ったら、どれも受け付ける（止めすぎない）
        gate.complete(Unit)
        assertFalse(state.isSavingDraft)
        viewModel.dismissNotice()
        viewModel.onCaptionChange("後から打った文")
        assertEquals("後から打った文", state.caption)
        viewModel.selectVisibility(Visibility.PRIVATE)
        assertEquals(Visibility.PRIVATE, state.visibility)
        assertTrue(state.canPublish)
        viewModel.publish()
        assertEquals(1, publisher.drafts.size)
    }

    // ── 下書きの保存中は離れさせない（タスク 20.6 の②・利用者の決定 2026-11-14）──

    @Test
    fun `下書きを保存している間は、変更が無くてもキャンセルで写真の選択の段に戻らず、保存に失敗した後は戻れる`() {
        // ログインして写しを作れる形にする（そうでないと「保存の失敗」の分岐に入り、保存中にならない）
        signIn()
        viewModel.onPhotosPicked(uris(1))
        val gate = holdDraftSaveThenFail()
        viewModel.saveDraft()
        assertTrue(state.isSavingDraft)

        // 変更が無いので、止めが無ければ確かめずに写真の選択の段へ戻る（そこから写真選択画面を開けてしまう：20.3 の気づきの 3）
        viewModel.requestLeave()
        assertEquals(ComposeStep.EDITING, state.step, "下書きの保存中に写真の選択の段へ戻った")
        assertTrue(state.isSavingDraft, "写真の選択の段へ戻って、保存中の印が消えた")
        assertEquals(1, state.photos.size)

        // 保存に失敗して戻ったら、離れられる（止めすぎない）
        gate.complete(Unit)
        assertFalse(state.isSavingDraft)
        viewModel.dismissNotice()
        viewModel.requestLeave()
        assertEquals(ComposeStep.SELECTING, state.step)
    }

    @Test
    fun `下書きを保存している間は、投稿情報の段から編集の段へ戻らず、保存に失敗した後は戻れる`() {
        signIn()
        enterInfo()
        val gate = holdDraftSaveThenFail()
        viewModel.saveDraft()
        assertTrue(state.isSavingDraft)

        viewModel.backToEditing()
        assertEquals(ComposeStep.INFO, state.step, "下書きの保存中に編集の段へ戻った")

        gate.complete(Unit)
        viewModel.dismissNotice()
        viewModel.backToEditing()
        assertEquals(ComposeStep.EDITING, state.step)
    }

    @Test
    fun `下書きを保存している間は、確かめのダイアログの破棄を受け付けず、保存に失敗した後は破棄できる`() {
        signIn()
        viewModel.onPhotosPicked(uris(1))
        viewModel.selectFilter(FilterId.VIVID)
        // 変更があるので確かめが出る。「下書きに保存」を選ぶと、確かめを出したまま保存中になる
        viewModel.requestLeave()
        val gate = holdDraftSaveThenFail()
        viewModel.answerLeave(LeaveChoice.SAVE_DRAFT)
        assertTrue(state.isSavingDraft)
        assertEquals(LeaveQuestion.DISCARD_OR_DRAFT, state.leaveQuestion)
        val clearsBefore = sessionCalls().count { it is FakeEditSessionStore.Call.Clear }

        viewModel.answerLeave(LeaveChoice.DISCARD)
        assertEquals(ComposeStep.EDITING, state.step, "下書きの保存中に破棄して写真の選択の段へ戻った")
        assertEquals(clearsBefore, sessionCalls().count { it is FakeEditSessionStore.Call.Clear }, "下書きの保存中に編集の途中を消した")

        // 保存に失敗して戻ったら、同じ道で破棄できる
        gate.complete(Unit)
        viewModel.dismissNotice()
        viewModel.requestLeave()
        viewModel.answerLeave(LeaveChoice.DISCARD)
        assertEquals(ComposeStep.SELECTING, state.step)
        assertEquals(clearsBefore + 1, sessionCalls().count { it is FakeEditSessionStore.Call.Clear })
    }

    @Test
    fun `下書きの一覧は今の利用者の分だけを読んで件数を持ち、削除すると読み直す`() {
        signIn()
        draftStore.summaries[uid] = listOf(summary("D2"), summary("D1"))
        draftStore.summaries[otherUid] = listOf(summary("X1"))
        val vm = newViewModel(handle = SavedStateHandle())
        assertEquals(2, vm.state.value.draftCount)

        vm.openDrafts()
        assertTrue(vm.state.value.showDrafts)
        assertEquals(listOf(summary("D2"), summary("D1")), vm.state.value.drafts)

        draftStore.summaries[uid] = listOf(summary("D2"))
        vm.deleteDraft(DraftId("D1"))
        assertTrue(draftStore.calls.contains(FakeLocalDraftRepository.Call.Delete(uid, DraftId("D1"))))
        assertEquals(listOf(summary("D2")), vm.state.value.drafts)
        assertEquals(1, vm.state.value.draftCount)
        assertTrue(draftStore.calls.filterIsInstance<FakeLocalDraftRepository.Call.ListDrafts>().all { it.uid == uid })

        vm.dismissSheet()
        assertFalse(vm.state.value.showDrafts)
    }

    @Test
    fun `アップロード中は下書きを削除しない（保存中なら削除できる）`() {
        signIn()
        draftStore.summaries[uid] = listOf(summary("D1"))
        // アップロード中：開いた下書きから始めた投稿は写真を下書きのフォルダから読むので、消さない
        publisher.state.value = PublishState.Uploading(done = 1, total = 2)
        viewModel.deleteDraft(DraftId("D1"))
        assertTrue(draftStore.calls.none { it is FakeLocalDraftRepository.Call.Delete }, "アップロード中に下書きを消した")

        // 保存中：写真はもう送り終えているので、消してよい
        publisher.state.value = PublishState.Saving
        viewModel.deleteDraft(DraftId("D1"))
        assertTrue(draftStore.calls.contains(FakeLocalDraftRepository.Call.Delete(uid, DraftId("D1"))))
    }

    @Test
    fun `投稿には1枚目を写した時に読んだ撮影日時を渡す`() {
        val capturedAt = CapturedAt(Instant.parse("2026-11-01T06:30:00Z"), CapturedAtSource.EXIF)
        signIn(capturedAt = capturedAt)
        viewModel.onPhotosPicked(uris(2))
        viewModel.goToInfo()
        // 途中の文書にも残す（作り直した画面からの投稿でも同じ値になる）
        val written = writtenSession()
        assertEquals(capturedAt.instant.toEpochMilli(), written.photos[0].capturedAtEpochMillis)
        assertEquals(CapturedAtSource.EXIF.raw, written.photos[0].capturedAtSourceRaw)
        assertNull(written.photos[1].capturedAtEpochMillis)

        viewModel.publish()

        assertEquals(capturedAt, publisher.drafts.single().firstPhotoCapturedAt)
    }

    @Test
    fun `画面名は今と同じ決まりで送り、編集・下書き・投稿で新しいイベントを送らない`() {
        signIn()
        prepareDraft()
        viewModel.onScreenShown()
        viewModel.onPhotosPicked(uris(2))
        viewModel.showPhoto(1)
        viewModel.selectFilter(FilterId.CLEAR)
        viewModel.onSliderChange(EditTool.SATURATION, 20)
        viewModel.onSliderFinished()
        viewModel.openTool(EditTool.CROP_AND_ROTATE)
        viewModel.rotateLeft()
        viewModel.confirmCrop()
        viewModel.undo()
        viewModel.redo()
        viewModel.openLoadout()
        viewModel.saveLoadout(Loadout(listOf(EditTool.EXPOSURE)))
        viewModel.goToInfo()
        viewModel.backToEditing()
        viewModel.requestLeave()
        viewModel.answerLeave(LeaveChoice.DISCARD)
        viewModel.openDrafts()
        viewModel.openDraft(draft1)
        viewModel.goToInfo()
        viewModel.publish()

        assertTrue(state.published)
        // 「投稿」は 1 回、「編集」は写真の選択の段から編集の段に入るたび（写真を選んだ時と、下書きを開いた時）
        assertEquals(listOf(ScreenName.POST, ScreenName.EDIT, ScreenName.EDIT), analytics.screens)
        assertTrue(events.isEmpty(), "新しいイベントを送った: $events")
    }

    // ── 画面の書き方（ソースの検査。レビュー R05・R18・Q07）──

    private val screenSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/compose/PostComposerScreen.kt")
    private val appSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/root/SoramoyouApp.kt")

    private fun screen(): String {
        assertTrue(screenSource.isFile, "PostComposerScreen.kt が見つからない: ${screenSource.absolutePath}")
        return screenSource.readText()
    }

    /**
     * コメントを除いた画面の源（Kiro android-edit-tools I2 で足した確かめが使う。説明のコメントに同じ書き方があっても、
     * コードから消えたら赤になるように）。除き方は PostPublishedDialogSourceTest と同じ（文字列の中の 2 つの斜線も消し、
     * 入れ子のブロックコメントは扱わない）。
     */
    private fun screenCode(): String = withoutComments(screen())

    /** コメントを除いた SoramoyouApp.kt（画面の引数に ViewModel の関数をつないでいるかを見る）。 */
    private fun appCode(): String {
        assertTrue(appSource.isFile, "SoramoyouApp.kt が見つからない: ${appSource.absolutePath}")
        return withoutComments(appSource.readText())
    }

    /** ブロックコメント（KDoc を含む）を先に、行コメントを後に消す（PostPublishedDialogSourceTest と同じ順）。 */
    private fun withoutComments(source: String): String =
        source.replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), "").replace(Regex("""//[^\n]*"""), "")

    /** [source] のうち、[marker] の後に最初に現れる `{` から、対応する `}` までの塊（AccountDeletionScreenLayoutTest の同名の補助と同じ）。 */
    private fun blockAfter(source: String, marker: String): String {
        val markerAt = source.indexOf(marker)
        check(markerAt >= 0) { "$marker が見つからない" }
        val begin = source.indexOf('{', markerAt)
        check(begin >= 0) { "$marker の後に { が無い" }
        var depth = 0
        for (i in begin until source.length) {
            when (source[i]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return source.substring(begin, i + 1)
            }
        }
        error("$marker の後の { に対応する } が無い")
    }

    /** [source] のうち、[head]（`(` で終わる呼び出しの始まり）の `(` から、対応する `)` までの引数の並び（Kiro android-edit-tools I2）。 */
    private fun argumentsAfter(source: String, head: String): String {
        val headAt = source.indexOf(head)
        check(headAt >= 0 && head.endsWith('(')) { "$head が見つからない" }
        val begin = headAt + head.length - 1
        var depth = 0
        for (i in begin until source.length) {
            when (source[i]) {
                '(' -> depth++
                ')' -> if (--depth == 0) return source.substring(begin, i + 1)
            }
        }
        error("$head の ( に対応する ) が無い")
    }

    @Test
    fun `画面の投稿ボタンはオフラインの間は押せない`() {
        assertTrue(
            "Button(onClick = onPublish, enabled = state.canPublish && isOnline," in screen(),
            "投稿ボタンが接続の有無を見ていない",
        )
    }

    @Test
    fun `画面はアップロード中にオフラインになったら、接続できないことを出す`() {
        val progress = blockAfter(screen(), "private fun PublishProgressContent(")
        val uploading = blockAfter(progress, "is PublishProgress.Uploading ->")

        assertTrue(
            "if (!isOnline) Status(stringResource(R.string.offline_title))" in uploading,
            "アップロード中のオフラインの案内が無い: $uploading",
        )
    }

    @Test
    fun `画面は進行中の投稿が無い間にオフラインなら、投稿できない理由を出す`() {
        val progress = blockAfter(screen(), "private fun PublishProgressContent(")

        assertTrue(
            "null -> if (!isOnline) Status(stringResource(R.string.offline_title))" in progress,
            "投稿していない間のオフラインの案内が無い: $progress",
        )
    }

    @Test
    fun `画面は投稿の失敗を、段によらず「エラー」のダイアログで出し、OKとダイアログの外でだけ消す`() {
        val source = screen()
        val body = blockAfter(source, "fun PostComposerScreen(")
        val marker = "state.publishError?.let { error ->"
        val at = body.indexOf(marker)

        assertTrue(at >= 0, "投稿の失敗を出していない")
        // 画面の関数の直下に置く（段ごとの分岐や中身の Column の中に入れない）＝どの段でも出る。
        // body は関数の本体の { から始まるので、直下なら marker の手前で閉じていない { は 1 つ
        val depth = body.substring(0, at).count { it == '{' } - body.substring(0, at).count { it == '}' }
        assertEquals(1, depth, "投稿の失敗のダイアログが画面の関数の直下に無い（段や中身の中にある）")
        val dialog = blockAfter(body.substring(at), marker)
        listOf(
            "AlertDialog(",
            "onDismissRequest = onDismissPublishError,",
            "title = { Text(stringResource(R.string.compose_publish_failed_title)) },",
            // 文言は postErrorText で決め、値（何枚目の写真か）も入れる（Kiro android-edit-tools I2。下の確かめも見る）
            "val text = postErrorText(error)",
            "text = { Text(stringResource(text.res, *text.args.toTypedArray())) },",
            "confirmButton = { TextButton(onClick = onDismissPublishError) { Text(stringResource(R.string.action_ok)) } },",
        ).forEach { assertTrue(it in dialog, "投稿の失敗のダイアログに「$it」が無い: $dialog") }
        // 失敗を出すのはこのダイアログだけ（画面の中の文言は、見せる前に選び直しで消えていた。レビュー Q07）
        assertEquals(1, source.split("state.publishError").size - 1, "投稿の失敗を出す所がダイアログの 1 か所でない")
    }

    // ── Kiro android-edit-tools I2〔19.1〕で足した、画面の源の確かめ（どれもコメントを除いた源を見る）──

    @Test
    fun `画面は投稿の失敗の文言を postErrorText で決め、何枚目の写真かの値も入れて出す`() {
        val code = screenCode()

        assertTrue("val text = postErrorText(error)" in code, "投稿の失敗の文言を postErrorText で決めていない")
        assertTrue(
            "stringResource(text.res, *text.args.toTypedArray())" in code,
            "投稿の失敗の文言に、postErrorText の値（何枚目の写真か）を入れていない",
        )
        // 値を持たない前の引き方に戻すと、変換に失敗した写真が何枚目かが出ない（design.md:894）
        assertFalse("postErrorMessageRes" in code, "投稿の失敗の文言を、値を持たない前の引き方で出している")
    }

    @Test
    fun `画面は止まった（裏に回った）ときに、ViewModel に編集の途中をすぐ書かせる`() {
        val body = blockAfter(screenCode(), "fun PostComposerScreen(")

        // 待ちの 0.5 秒の間に裏でプロセスが落ちると、最後の編集を失う（design.md:984）
        assertTrue(
            "LifecycleEventEffect(Lifecycle.Event.ON_STOP) { onStop() }" in body,
            "画面が止まったときに onStop を呼んでいない",
        )
        assertTrue("onStop = viewModel::onStop," in appCode(), "SoramoyouApp が画面の onStop に ViewModel の onStop をつないでいない")
    }

    @Test
    fun `画面は下書きの件数を読み終えてから、写真選択画面を自動で開くかを1回だけ決める（利用者の判断U7）`() {
        val body = blockAfter(screenCode(), "fun PostComposerScreen(")
        val decide = blockAfter(body, "LaunchedEffect(state.draftCountLoaded)")

        listOf(
            // 読み終える前の 0 件は「まだ読んでいない」なので決めない。決めたら、開かなくても印を立てる
            "if (state.draftCountLoaded && !pickerOpened)",
            "pickerOpened = true",
            // 下書きが無く、作り直しで途中を読み戻してもいない（写真が無い）ときだけ開く
            "if (state.draftCount == 0 && state.photos.isEmpty()) launchPicker()",
        ).forEach { assertTrue(it in decide, "自動で開く判断に「$it」が無い: $decide") }
        // 画面を開いたらすぐ開く形（件数より先に開いてしまう）に戻っていない
        assertFalse("launchPicker()" in blockAfter(body, "LaunchedEffect(Unit)"), "画面を開いた時に、下書きの件数を待たずに写真選択画面を開いている")
    }

    @Test
    fun `画面は何も選ばずに写真選択画面を閉じても、下書きがあるか件数をまだ読んでいなければ閉じない（利用者の判断U7）`() {
        assertTrue(
            "if (shouldCloseAfterPicker(picked, state) && state.draftCountLoaded && state.draftCount == 0) onClose() " +
                "else onPhotosPicked(picked)" in screenCode(),
            "何も選ばずに閉じたときに、下書きの有無を見ずに画面を閉じている",
        )
    }

    @Test
    fun `画面は選び直しの確かめが出なかったときと、確かめで選び直すを選んだときだけ写真選択画面を開く`() {
        val code = screenCode()

        assertTrue(
            "val repick: () -> Unit = { if (onRequestRepick() == null) launchPicker() }" in code,
            "確かめが出なかったときに、そのまま写真選択画面を開いていない",
        )
        assertTrue(
            "if (question == LeaveQuestion.REPICK && choice == LeaveChoice.DISCARD) launchPicker()" in code,
            "選び直しの確かめで「選び直す」を選んだ後に、写真選択画面を開いていない",
        )
        // 確かめは、呼んだ直後の ViewModel の状態から読む（画面の引数の状態は、次の描き直しまで古い）
        assertTrue(
            "onRequestRepick = { viewModel.requestRepick() viewModel.state.value.leaveQuestion }," in appCode().replace(Regex("""\s+"""), " "),
            "SoramoyouApp が、選び直しの確かめを呼んだ直後の状態から返していない",
        )
    }

    @Test
    fun `画面は写真を確かめている間とトリミング・回転の画面の間は、編集の操作と次へを無効にする`() {
        val code = screenCode()

        assertTrue(
            "TextButton(onClick = onGoToInfo, enabled = !state.isChecking && state.cropSession == null)" in code,
            "「次へ」が、確かめている間かトリミング・回転の画面の間も押せる（要件 1.8・design.md:731）",
        )
        val editing = blockAfter(code, "private fun EditingContent(")
        assertTrue("val locked = state.isChecking || cropSession != null" in editing, "編集の操作を止める条件が無い: $editing")
        assertTrue("enabled = !locked," in argumentsAfter(editing, "EditToolPanel("), "ツールの部品が、止める間も押せる")
        // フィルターの選択肢は無効の形を持たないので、止める間は出さない
        assertTrue("FilterOptions(" in blockAfter(editing, "if (!locked)"), "フィルターの選択肢を、止める間も出している")
    }

    @Test
    fun `画面は下書きに保存できたら閉じる`() {
        assertTrue(
            "LaunchedEffect(state.draftSaved) { if (state.draftSaved) onClose() }" in screenCode(),
            "下書きに保存できても画面を閉じない（design.md「下書きに保存」）",
        )
    }

    // ── 問い 34（利用者の決定 2026-11-13）で足した、画面の源の確かめ（どれもコメントを除いた源を見る）──

    @Test
    fun `画面は下書きを保存している間、編集の操作・入力・写真の選び直しを無効にする`() {
        val code = screenCode()
        val editing = blockAfter(code, "private fun EditingContent(")

        // 行の終わりまで見る（後ろの条件が消えても、前の部分の一致で緑にならないように）
        assertTrue(
            "val locked = state.isChecking || cropSession != null || state.isSavingDraft\n" in editing,
            "編集の操作を止める条件に、下書きの保存中が無い: $editing",
        )
        assertTrue(
            "onClick = onRepick, enabled = cropSession == null && state.progress !is PublishProgress.Uploading && !state.isSavingDraft," in
                editing.replace(Regex("""\s+"""), " "),
            "写真の選び直しが、下書きの保存中も押せる: $editing",
        )
        val info = blockAfter(code, "private fun InfoContent(")
        assertTrue(
            "val editable = !state.isPublishing && !state.published && !state.isSavingDraft\n" in info,
            "投稿情報の段の入力を止める条件に、下書きの保存中が無い: $info",
        )
    }

    @Test
    fun `画面はこの画面の投稿の途中は、確かめの「下書きに保存」を押せなくする`() {
        assertTrue(
            "canSaveDraft = !state.isPublishing," in argumentsAfter(screenCode(), "LeaveDialog("),
            "確かめのダイアログに、この画面の投稿の途中を渡していない",
        )
    }

    @Test
    fun `画面は進行中の投稿がある間は、下書きの一覧の行を押せなくする`() {
        assertTrue(
            "openEnabled = state.progress == null," in argumentsAfter(screenCode(), "DraftListSheet("),
            "下書きの一覧に、進行中の投稿があることを渡していない",
        )
    }
}

/**
 * 投稿の公開の偽物。[state] は共有の進み具合（テストが直接動かす）。受け取った下書きを [drafts] に順に残す。
 * [gate] があれば、それが完了するまで戻らず、その結果を返す。無ければ [result] をすぐ返す。
 */
private class FakePostPublisher : PostPublisher {
    override val state = MutableStateFlow<PublishState>(PublishState.Idle)
    val drafts = mutableListOf<PostDraft>()
    var gate: CompletableDeferred<AppResult<PostId>>? = null
    var result: AppResult<PostId> = AppResult.Ok(PostId("P1"))

    override suspend fun publish(draft: PostDraft): AppResult<PostId> {
        drafts += draft
        return gate?.await() ?: result
    }
}

/**
 * 読めるかの確認の偽物。[unreadable] の URI は読めないとし、確かめた写真を [probed] に順に残す。
 * [gates] に入れた URI は、その CompletableDeferred が完了するまで確認の途中で止まる。
 */
private class FakePhotoProbe : PhotoProbe {
    val unreadable = mutableSetOf<String>()
    val probed = mutableListOf<PickedPhoto>()
    val gates = mutableMapOf<String, CompletableDeferred<Unit>>()

    override suspend fun probe(photo: PickedPhoto): AppResult<Unit> {
        probed += photo
        gates[photo.uri]?.await()
        return if (photo.uri in unreadable) AppResult.Err(AppError.ImageUnreadable(photo.index)) else AppResult.Ok(Unit)
    }
}
