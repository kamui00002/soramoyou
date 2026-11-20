// ⭐️ プロフィール編集の画面の状態の単体テスト（タスク 16.3・要件 10.6・10.8・10.10・16.2）
package com.yoshidometoru.soramoyou.feature.profile

import androidx.lifecycle.SavedStateHandle
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.data.model.OwnProfile
import com.yoshidometoru.soramoyou.data.repository.ProfileEdit
import com.yoshidometoru.soramoyou.data.repository.ProfileSaveStage
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.afterProcessDeath
import com.yoshidometoru.soramoyou.feature.immediateScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 偽物の取得・保存は、テストが結果を渡すまで待つ。スコープは Unconfined なので、結果を渡すとその場で続きが進む。
 * いまのプロフィールは [FakeProfileRepository.ownFlows] の監視に流して渡す（`subscriptionCount` で、読んだ後に監視をやめたかを見る）。
 */
class ProfileEditViewModelTest {

    private val repository = FakeProfileRepository()
    private val editor = FakeProfileEditor()
    private val analytics = RecordingFeatureAnalytics()
    private val online = MutableStateFlow(true)
    private val savedState = SavedStateHandle()

    private fun viewModel(savedState: SavedStateHandle = this.savedState) =
        ProfileEditViewModel(repository, editor, analytics, online, savedState, immediateScope())

    /** 作って、いまのプロフィールとして [profile] を届けた ViewModel。 */
    private fun loaded(profile: OwnProfile = ownProfile()): ProfileEditViewModel {
        val vm = viewModel()
        repository.emitOwn(AppResult.Ok(profile))
        return vm
    }

    // ── 読み込み（要件 16.2）──

    @Test
    fun `作った時点で自分のユーザー文書を読み始め、読み込み中で、保存できない`() {
        val vm = viewModel()

        assertEquals(1, repository.ownFlows.size)
        assertEquals(ProfileEditLoad.Loading, vm.state.value.load)
        assertFalse(vm.state.value.canSave)
    }

    @Test
    fun `届いたプロフィールで入力欄を埋め、最初の1回で監視をやめる（入力中に別端末の更新で欄を上書きしない）`() {
        val vm = loaded(ownProfile(name = "そら", bio = "空が好き"))

        val state = vm.state.value
        assertEquals(ProfileEditLoad.Ready, state.load)
        assertEquals("そら", state.displayName)
        assertEquals("空が好き", state.bio)
        assertEquals("https://example.com/me.jpg", state.currentPhotoUrl)
        assertEquals(0, repository.ownFlows.single().subscriptionCount.value)
    }

    @Test
    fun `表示名・自己紹介が無いプロフィールは空の入力欄にする`() {
        val vm = loaded(ownProfile(name = null, bio = null))

        assertEquals("", vm.state.value.displayName)
        assertEquals("", vm.state.value.bio)
    }

    @Test
    fun `空白だけの表示名は読んだまま入力欄に出す（保存で比べる元と同じ値にする）`() {
        val vm = loaded(ownProfile(name = "　", bio = " "))

        assertEquals("　", vm.state.value.displayName)
        assertEquals(" ", vm.state.value.bio)
    }

    @Test
    fun `読み込みに失敗したら記録して失敗にし、再試行で読み直す`() {
        val vm = viewModel()
        repository.emitOwn(AppResult.Err(AppError.Network))

        assertEquals(ProfileEditLoad.Failed(AppError.Network, failedWhileOffline = false), vm.state.value.load)
        assertEquals(listOf<Pair<AppError, String>>(AppError.Network to "ProfileEditViewModel.load"), analytics.errors)

        vm.retryLoad()
        assertEquals(2, repository.ownFlows.size)
        assertEquals(ProfileEditLoad.Loading, vm.state.value.load)
        repository.emitOwn(AppResult.Ok(ownProfile(name = "そら")))
        assertEquals(ProfileEditLoad.Ready, vm.state.value.load)
        assertEquals("そら", vm.state.value.displayName)
    }

    @Test
    fun `ユーザー文書が無いときは保存できないので失敗にする（記録はしない：補完を待つ普通の状態）`() {
        val vm = viewModel()
        repository.emitOwn(AppResult.Err(AppError.NotFound))

        assertEquals(ProfileEditLoad.Failed(AppError.NotFound, failedWhileOffline = false), vm.state.value.load)
        assertTrue(analytics.errors.isEmpty())
    }

    @Test
    fun `オフラインで失敗したらそのことを残す`() {
        online.value = false
        val vm = viewModel()
        repository.emitOwn(AppResult.Err(AppError.Network))

        assertEquals(ProfileEditLoad.Failed(AppError.Network, failedWhileOffline = true), vm.state.value.load)
    }

    @Test
    fun `読み込めているときの再試行は何もしない`() {
        val vm = loaded()

        vm.retryLoad()

        assertEquals(1, repository.ownFlows.size)
    }

    // ── 残りの文字数と上限（要件 10.10）──

    @Test
    fun `残りの文字数は見た目の1文字（書記素）で数える`() {
        val vm = loaded(ownProfile(name = null, bio = null))

        vm.onDisplayNameChange("👨‍👩‍👧空")
        vm.onBioChange("é")

        assertEquals(TextLimits.DISPLAY_NAME_MAX - 2, vm.state.value.displayNameRemaining)
        assertEquals(TextLimits.BIO_MAX - 1, vm.state.value.bioRemaining)
    }

    @Test
    fun `上限ちょうどは保存でき、1文字でも超えたら保存できない`() {
        val vm = loaded()

        vm.onDisplayNameChange("あ".repeat(TextLimits.DISPLAY_NAME_MAX))
        vm.onBioChange("い".repeat(TextLimits.BIO_MAX))
        assertTrue(vm.state.value.isWithinLimits)
        assertTrue(vm.state.value.canSave)

        vm.onDisplayNameChange("あ".repeat(TextLimits.DISPLAY_NAME_MAX + 1))
        assertFalse(vm.state.value.isWithinLimits)
        assertFalse(vm.state.value.canSave)
        assertEquals(-1, vm.state.value.displayNameRemaining)

        vm.onDisplayNameChange("あ")
        vm.onBioChange("い".repeat(TextLimits.BIO_MAX + 1))
        assertFalse(vm.state.value.canSave)
    }

    @Test
    fun `上限を超えているときの保存は何も呼ばない`() {
        val vm = loaded()
        vm.onBioChange("い".repeat(TextLimits.BIO_MAX + 1))

        vm.save()

        assertTrue(editor.saves.calls.isEmpty())
    }

    @Test
    fun `読んだときから上限を超えている表示名は、変えなければ赤くせず保存も止めない`() {
        // iOS より多く数える古い端末で、iOS で上限ちょうどにした表示名を読んだときの形（全体レビュー 4 回目 R21 の利用者の決定）
        val longName = "あ".repeat(TextLimits.DISPLAY_NAME_MAX + 1)
        val profile = ownProfile(name = longName)
        val vm = loaded(profile)

        assertEquals(-1, vm.state.value.displayNameRemaining)
        assertFalse(vm.state.value.displayNameOverLimit)
        assertTrue(vm.state.value.isWithinLimits)
        assertTrue(vm.state.value.canSave)

        vm.onBioChange("夕焼けも好き")
        vm.save()

        assertEquals(listOf(ProfileEdit(longName, "夕焼けも好き", null) to profile), editor.saves.calls)
    }

    @Test
    fun `読んだときから上限を超えている自己紹介も、変えなければ赤くせず保存も止めない`() {
        val vm = loaded(ownProfile(bio = "い".repeat(TextLimits.BIO_MAX + 1)))

        vm.onDisplayNameChange("くも")

        assertFalse(vm.state.value.bioOverLimit)
        assertTrue(vm.state.value.canSave)
    }

    @Test
    fun `上限を超えた値を変えたら赤くして保存を止め、読んだ値に戻せば止めない`() {
        val longName = "あ".repeat(TextLimits.DISPLAY_NAME_MAX + 1)
        val longBio = "い".repeat(TextLimits.BIO_MAX + 1)
        val vm = loaded(ownProfile(name = longName, bio = longBio))

        vm.onDisplayNameChange(longName + "あ")
        assertTrue(vm.state.value.displayNameOverLimit)
        assertFalse(vm.state.value.canSave)

        vm.onDisplayNameChange(longName)
        vm.onBioChange(longBio.drop(1) + "う")
        assertFalse(vm.state.value.displayNameOverLimit)
        assertTrue(vm.state.value.bioOverLimit)
        assertFalse(vm.state.value.canSave)

        vm.onBioChange(longBio)
        assertTrue(vm.state.value.canSave)
    }

    @Test
    fun `上限を超えた値を空にして消すのは止めない`() {
        val vm = loaded(ownProfile(name = "あ".repeat(TextLimits.DISPLAY_NAME_MAX + 1)))

        vm.onDisplayNameChange("")

        assertFalse(vm.state.value.displayNameOverLimit)
        assertTrue(vm.state.value.canSave)
    }

    // ── アイコン（要件 10.8）──

    @Test
    fun `写真を選んだら1枚目の写真として持つ。選ばずに閉じたら前の選択のまま`() {
        val vm = loaded()

        vm.onIconPicked("content://media/picker/1")
        assertEquals(PickedPhoto("content://media/picker/1", index = 0), vm.state.value.newIcon)

        vm.onIconPicked(null)
        assertEquals(PickedPhoto("content://media/picker/1", index = 0), vm.state.value.newIcon)
    }

    // ── 保存（要件 10.6・16.2）──

    @Test
    fun `保存は入力欄の値と選んだ写真を、読んだときのプロフィールと一緒に渡す`() {
        val profile = ownProfile(name = "そら", bio = "空が好き")
        val vm = loaded(profile)
        vm.onDisplayNameChange("くも")
        vm.onBioChange("")
        vm.onIconPicked("content://media/picker/2")

        vm.save()

        assertEquals(
            listOf(ProfileEdit("くも", "", PickedPhoto("content://media/picker/2", 0)) to profile),
            editor.saves.calls,
        )
    }

    @Test
    fun `保存中は読み込み中にして、もう一度押しても送らない`() {
        val vm = loaded()

        vm.save()
        assertTrue(vm.state.value.isSaving)
        assertFalse(vm.state.value.canSave)

        vm.save()
        assertEquals(1, editor.saves.calls.size)
    }

    @Test
    fun `保存できたら保存済みにする（画面が閉じる）`() {
        val vm = loaded()
        vm.save()

        editor.saves.completeLast(AppResult.Ok(Unit))

        assertFalse(vm.state.value.isSaving)
        assertTrue(vm.state.value.saved)
        assertNull(vm.state.value.error)
        assertFalse(vm.state.value.canSave)
    }

    @Test
    fun `保存に失敗したら理由を出し、選んだ写真は残して、もう一度保存できる（記録は保存の部品が済ませるので記録し直さない）`() {
        val vm = loaded()
        vm.onIconPicked("content://media/picker/3")
        vm.save()

        editor.saves.completeLast(AppResult.Err(AppError.ImageTooLarge(0, 6_000_000)))

        val state = vm.state.value
        assertFalse(state.isSaving)
        assertFalse(state.saved)
        assertEquals(AppError.ImageTooLarge(0, 6_000_000), state.error)
        assertEquals(PickedPhoto("content://media/picker/3", 0), state.newIcon)
        assertTrue(state.canSave)
        assertTrue(analytics.errors.isEmpty())
    }

    @Test
    fun `保存を押し直したら前の失敗の表示を消す`() {
        val vm = loaded()
        vm.save()
        editor.saves.completeLast(AppResult.Err(AppError.Network))

        vm.save()

        assertNull(vm.state.value.error)
        assertTrue(vm.state.value.isSaving)
    }

    @Test
    fun `入力を直したら前の失敗の表示を消す`() {
        val vm = loaded()
        vm.save()
        editor.saves.completeLast(AppResult.Err(AppError.Validation(ValidationReason.DISPLAY_NAME_TOO_LONG)))

        vm.onDisplayNameChange("そら2")

        assertNull(vm.state.value.error)
    }

    // ── オフライン（レビュー R09）──

    @Test
    fun `オフラインの間は保存を押しても送らず、接続が戻れば送る`() {
        // オフラインで送ると users の書き込みが接続を待ち続け、理由の出ないまま読み込み中で止まる（兄弟の FeedbackViewModel と同じく入口で止める）
        val vm = loaded()
        online.value = false

        vm.save()
        assertTrue(editor.saves.calls.isEmpty())
        assertFalse(vm.state.value.isSaving)

        online.value = true
        vm.save()
        assertEquals(1, editor.saves.calls.size)
        assertTrue(vm.state.value.isSaving)
    }

    // ── 前に開いた画面で始めた保存（全体レビュー 4 回目 Q04）──

    @Test
    fun `前に開いた画面で始めた保存が走っている間は、保存を押せず押しても送らない。終われば押せる`() {
        // 保存中に「キャンセル」で閉じて開き直した画面。前の保存は取り消されずに走り続け、後から終わると、この画面で先に保存した値を
        // 古い値で上書きする。iOS の共有の ViewModel の isLoading と同じく、前の保存が終わるまで押させない
        editor.state.value = ProfileSaveStage.UPLOADING_ICON
        val vm = loaded()

        assertTrue(vm.state.value.isOthersSaving)
        assertFalse(vm.state.value.canSave)
        vm.save()
        assertTrue(editor.saves.calls.isEmpty())

        editor.state.value = ProfileSaveStage.SAVING
        assertTrue(vm.state.value.isOthersSaving)
        assertFalse(vm.state.value.canSave)

        editor.state.value = ProfileSaveStage.IDLE
        assertFalse(vm.state.value.isOthersSaving)
        assertTrue(vm.state.value.canSave)
        vm.save()
        assertEquals(1, editor.saves.calls.size)
    }

    @Test
    fun `自分の保存の間は、前に開いた画面の保存として扱わない`() {
        val vm = loaded()
        vm.save()
        // 自分の保存も部品の段を進める（偽物の save は段を変えないので、テストが入れる）。自分の保存の間は読み込み中を出しているので、
        // 前の保存の理由は出さない
        editor.state.value = ProfileSaveStage.SAVING

        assertTrue(vm.state.value.isSaving)
        assertFalse(vm.state.value.isOthersSaving)
    }

    @Test
    fun `読み込みが終わる前の保存は何も呼ばない`() {
        val vm = viewModel()

        vm.save()

        assertTrue(editor.saves.calls.isEmpty())
        assertIs<ProfileEditLoad.Loading>(vm.state.value.load)
    }

    // ── プロセスが落ちて作り直したとき（全体レビュー 4 回目 Q10）──

    @Test
    fun `プロセスが落ちて作り直しても、打った自己紹介を読み直した値より先に入れ、打っていない表示名は読み直した値にする`() {
        // 自己紹介を消してから写真選択画面を開き、その間に裏のアプリがメモリの不足で殺される。戻る履歴は戻り、ViewModel は作り直されて
        // 読み直す。残さないと、選んだアイコンだけが新しく、自己紹介は読み直した値に戻ったまま保存される
        loaded(ownProfile(name = "そら", bio = "空が好き")).onBioChange("")
        val recreated = viewModel(savedState.afterProcessDeath())
        // 写真選択画面で選んだ結果は、作り直した画面に届く（読み込みの前でも後でも newIcon は残る）
        recreated.onIconPicked("content://media/picker/9")
        // その間に、別の端末で表示名が変わっていた
        val fresh = ownProfile(name = "そら2", bio = "空が好き")
        repository.emitOwn(AppResult.Ok(fresh))

        val restored = recreated.state.value
        assertEquals(ProfileEditLoad.Ready, restored.load)
        assertEquals("", restored.bio, "打って空にした自己紹介が、読み直した値に戻った")
        // 前に読んだ古い値を残すと、別の端末の更新を保存で上書きする
        assertEquals("そら2", restored.displayName)
        assertEquals("https://example.com/me.jpg", restored.currentPhotoUrl)

        recreated.save()
        assertEquals(listOf(ProfileEdit("そら2", "", PickedPhoto("content://media/picker/9", 0)) to fresh), editor.saves.calls)
    }
}
