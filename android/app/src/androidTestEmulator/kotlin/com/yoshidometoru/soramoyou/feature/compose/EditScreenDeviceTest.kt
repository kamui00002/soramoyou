// ⭐️ 編集の部品の読み上げ・操作・押せる大きさ・選択の見え方を、端末で部品を組み立てて確かめる（Kiro android-edit-tools タスク 19.3・I2・要件 3.3・3.7・6.6・7.7・13.2〜13.5・13.8）
package com.yoshidometoru.soramoyou.feature.compose

import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeProvider
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertHasNoClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.assertValueEquals
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isToggleable
// v2 を使う（前例 FeedScreenStateDeviceTest と同じ。状態を変えた後は必ず assert か runOnIdle で画面と同期する）
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.edit.CropMath
import com.yoshidometoru.soramoyou.contract.edit.EditGeometry
import com.yoshidometoru.soramoyou.contract.edit.EditHistory
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.Loadout
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.data.edit.DraftId
import com.yoshidometoru.soramoyou.data.edit.LocalDraftSummary
import com.yoshidometoru.soramoyou.data.edit.WorkingPhoto
import com.yoshidometoru.soramoyou.data.image.PreviewImage
import com.yoshidometoru.soramoyou.ui.theme.SoramoyouTheme
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 編集の部品（EditToolPanel・CropPanel・LoadoutSheetContent・DraftListSheet・LeaveDialog・FilterOptions・EditedPhotoPreview）に
 * 状態を直接渡して端末で組み立て、TalkBack に読ませる情報（名前・値・役割・選択の状態）と操作、押せる大きさ（48dp 以上）を確かめる。
 *
 * - 見るのは「意味の情報」（文字・説明・役割・選択・押せるか・操作の関数）。色や太字そのものは見ない（色だけで伝えていないことは、
 *   選択・調整済みが意味の情報＝selected や文字として付いているかで確かめる：13.8・3.7）。
 * - 部品は状態を受け取って描くだけなので、ViewModel・Firebase・分析の窓口を作らない。PostComposerScreen も呼ばない。
 * - 文言は strings.xml から読む（端末の言語に左右されない）。ツールとフィルターの表示名は :contract の displayName から読む。
 * - 押せる大きさは、touchBoundsInRoot（押せる範囲。Material のボタンが 48dp に広げた分を含む）を端末の密度で dp に直して見る。
 *   画面の外に出ている部品は範囲が切られるので、先に performScrollTo で見える所へ送る。
 * - 画面の外の部品を押す操作（performClick）も、先に performScrollTo で送ってから行う。
 *
 * 実行は
 * `./gradlew :app:connectedEmulatorDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.yoshidometoru.soramoyou.feature.compose.EditScreenDeviceTest`
 * （仮想端末が要る。終わると検証用のアプリ〔.emulator〕は端末から消える。本番用のアプリには触れない）。
 */
@RunWith(AndroidJUnit4::class)
class EditScreenDeviceTest {

    @get:Rule
    val rule = createComposeRule()

    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    /** 画面に出る文言（strings.xml の値） */
    private fun text(id: Int): String = context.getString(id)

    /** 引数つきの文言（strings.xml の値に引数を入れたもの） */
    private fun text(id: Int, vararg args: Any): String = context.getString(id, *args)

    /** 端末の密度。48dp を px に直すのに使う */
    private val density = context.resources.displayMetrics.density

    // ---- 共通の補助 ----

    /** 本番と同じテーマで、縦に送れる列の中に部品を置く（画面の外に出る部品を performScrollTo で送れるようにする） */
    private fun showScrollable(content: @Composable () -> Unit) {
        rule.setContent {
            SoramoyouTheme {
                Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())) { content() }
            }
        }
    }

    /** 本番と同じテーマで、そのまま部品を置く（部品が自分で縦に送る・ダイアログ・シートのとき） */
    private fun show(content: @Composable () -> Unit) {
        rule.setContent { SoramoyouTheme { content() } }
    }

    /** 役割（ボタン・ラジオボタンなど）が [role] であること */
    private fun roleIs(role: Role): SemanticsMatcher = SemanticsMatcher.expectValue(SemanticsProperties.Role, role)

    /**
     * 押せる範囲が幅も高さも 48dp 以上であること（13.2）。[scroll] が真なら、先に見える所へ送る（範囲が画面の外で切られないように）。
     * 密度を掛けた px の丸めで 1px 足りないことがあるので、1px までは許す。
     */
    private fun SemanticsNodeInteraction.assertTouchTargetAtLeast48dp(label: String, scroll: Boolean = true): SemanticsNodeInteraction {
        if (scroll) performScrollTo()
        val bounds = fetchSemanticsNode().touchBoundsInRoot
        val minPx = 48f * density - 1f
        assertTrue(
            "$label の押せる範囲が 48dp 未満: 幅 ${bounds.width}px・高さ ${bounds.height}px（48dp = ${48f * density}px）",
            bounds.width >= minPx && bounds.height >= minPx,
        )
        return this
    }

    // ---- EditToolPanel の状態と、操作の記録 ----

    private var tools by mutableStateOf(Loadout.DEFAULT.tools)
    private var edit by mutableStateOf(PhotoEdit.NONE)
    private var history by mutableStateOf(EditHistory.EMPTY)
    private var openTool by mutableStateOf<EditTool?>(null)
    private var panelEnabled by mutableStateOf(true)

    private var undoCount = 0
    private var redoCount = 0
    private var loadoutOpenCount = 0
    private var sliderStartCount = 0
    private var sliderFinishCount = 0
    private val toolSelections = mutableListOf<EditTool?>()
    private val sliderChanges = mutableListOf<Pair<EditTool, Int>>()

    /** 履歴が 1 手だけある状態（元に戻すが押せる）。中身は何でもよい（部品は件数の有無だけを見る） */
    private val undoOnly = EditHistory(undo = listOf(PhotoEdit.NONE))

    /** やり直しだけが押せる状態 */
    private val redoOnly = EditHistory(redo = listOf(PhotoEdit.NONE))

    private fun exposureAt(value: Int): PhotoEdit = PhotoEdit.NONE.copy(tools = PhotoEdit.NONE.tools.with(EditTool.EXPOSURE, value))

    /** EditToolPanel に、上の状態を渡して出す。スライダーの変更は edit に反映する（実際の画面と同じく、値が変わると描き直される） */
    private fun showToolPanel() {
        showScrollable {
            EditToolPanel(
                tools = tools,
                edit = edit,
                history = history,
                openTool = openTool,
                onUndo = { undoCount++ },
                onRedo = { redoCount++ },
                onToolSelected = { toolSelections.add(it) },
                onSliderChange = { tool, value ->
                    sliderChanges.add(tool to value)
                    edit = edit.copy(tools = edit.tools.with(tool, value))
                },
                onSliderFinished = { sliderFinishCount++ },
                onOpenLoadout = { loadoutOpenCount++ },
                modifier = Modifier.fillMaxWidth(),
                enabled = panelEnabled,
                onSliderStart = { sliderStartCount++ },
            )
        }
    }

    /** 露出のスライダーの読み上げ（「露出、+25」の形）。数字は strings の形に値を入れたもの */
    private fun exposureSliderDescription(valueText: String): String =
        text(R.string.edit_slider_description, EditTool.EXPOSURE.displayName, valueText)

    /** TalkBack の「値を設定する」操作（SetProgress）を、目標の値 [target] で呼び、部品が返した成否を返す */
    private fun setProgressOnSlider(description: String, target: Float): Boolean {
        var result: Boolean? = null
        rule.onNodeWithContentDescription(description).performSemanticsAction(SemanticsActions.SetProgress) { result = it(target) }
        return result ?: error("SetProgress の結果が返らなかった")
    }

    // ================= EditToolPanel：スライダー =================

    @Test
    fun スライダーはツールの名前と今の値を読み上げ_値は状態の説明にも出る() {
        openTool = EditTool.EXPOSURE
        edit = exposureAt(25)
        showToolPanel()

        // 「露出、+25」と読む（13.3）。状態の説明にも値が入る
        rule.onNodeWithContentDescription(exposureSliderDescription("+25")).assertIsDisplayed().assertValueEquals("+25")

        // 負の値は「-10」の形（先頭の + を付けない）
        edit = exposureAt(-10)
        rule.onNodeWithContentDescription(exposureSliderDescription("-10")).assertValueEquals("-10")
    }

    @Test
    fun スライダーのTalkBack操作で値を上げると5増え_始まりと終わりを1回ずつ知らせる() {
        openTool = EditTool.EXPOSURE
        edit = exposureAt(25)
        showToolPanel()

        // 目標が今の値より上なら、向きだけを見て 5 だけ上げる（既定の幅の 1/20 ＝ 10 にならない：13.3）
        val handled = setProgressOnSlider(exposureSliderDescription("+25"), target = 100f)

        rule.runOnIdle {
            assertTrue("値が動いたので true を返す", handled)
            assertEquals("TalkBack の 1 回の操作で知らせる値", listOf(EditTool.EXPOSURE to 30), sliderChanges)
            assertEquals("触れた時の通知", 1, sliderStartCount)
            assertEquals("離した時の通知", 1, sliderFinishCount)
        }
        // 値が変わったので読み上げも「+30」に変わる
        rule.onNodeWithContentDescription(exposureSliderDescription("+30")).assertValueEquals("+30")
    }

    @Test
    fun スライダーのTalkBack操作で値を下げると5減る() {
        openTool = EditTool.EXPOSURE
        edit = exposureAt(25)
        showToolPanel()

        val handled = setProgressOnSlider(exposureSliderDescription("+25"), target = -100f)

        rule.runOnIdle {
            assertTrue("値が動いたので true を返す", handled)
            assertEquals(listOf(EditTool.EXPOSURE to 20), sliderChanges)
            assertEquals(1, sliderStartCount)
            assertEquals(1, sliderFinishCount)
        }
        rule.onNodeWithContentDescription(exposureSliderDescription("+20")).assertValueEquals("+20")
    }

    @Test
    fun スライダーのTalkBack操作は上限の100と下限のマイナス100で何も変えず_偽を返す() {
        openTool = EditTool.EXPOSURE
        edit = exposureAt(100)
        showToolPanel()

        // 上限でさらに上げる操作：動かせないので false で、値も通知も出ない
        val upAtMax = setProgressOnSlider(exposureSliderDescription("+100"), target = 1000f)
        rule.runOnIdle {
            assertEquals("上限で上げようとした結果", false, upAtMax)
            assertTrue("値の通知が出ない", sliderChanges.isEmpty())
            assertEquals(0, sliderStartCount)
            assertEquals(0, sliderFinishCount)
        }

        // 下限でさらに下げる操作も同じ
        edit = exposureAt(-100)
        val downAtMin = setProgressOnSlider(exposureSliderDescription("-100"), target = -1000f)
        rule.runOnIdle {
            assertEquals("下限で下げようとした結果", false, downAtMin)
            assertTrue("値の通知が出ない", sliderChanges.isEmpty())
        }
    }

    @Test
    fun スライダーのTalkBack操作は上限の手前では100で止める() {
        openTool = EditTool.EXPOSURE
        edit = exposureAt(98)
        showToolPanel()

        setProgressOnSlider(exposureSliderDescription("+98"), target = 1000f)

        // 98 + 5 は 103 だが、上限の 100 で止める
        rule.runOnIdle { assertEquals(listOf(EditTool.EXPOSURE to 100), sliderChanges) }
    }

    // ---- TalkBack が実際に通る道（端末の読み上げの窓口）で見る（タスク 20.6 の①） ----
    // 上のテストは、読み上げの文で外の箱を選んで箱の関数を直に呼ぶので、TalkBack が別の要素（中の Slider）を触っていても緑になる
    // （20.3 で、端末の TalkBack では 10 刻みで動き、掴む部品に読み上げの文が無いのを見た）。ここでは、Compose が TalkBack に渡す
    // 情報（AccessibilityNodeInfo）を端末の窓口から読み、TalkBack の音量キーと同じ操作（進める・戻す）をその窓口へ送る。

    /** 画面の中の意味の要素（まとめる前の木の全部）のうち、TalkBack に渡る情報を持つものを [block] に渡す（画面の糸の上で呼ぶ） */
    private fun <T> withAccessibilityInfos(block: (provider: AccessibilityNodeProvider, infos: Map<Int, AccessibilityNodeInfo>) -> T): T {
        val nodes = rule.onAllNodes(SemanticsMatcher("全部") { true }, useUnmergedTree = true).fetchSemanticsNodes()
        val view = (nodes.first().root as ViewRootForTest).view
        return rule.runOnUiThread {
            val provider = view.accessibilityNodeProvider ?: error("読み上げの窓口（AccessibilityNodeProvider）が無い")
            // 意味の要素の番号が、そのまま TalkBack に渡す要素の番号。TalkBack に渡らない要素（消した子孫）は null が返る
            val infos = nodes.mapNotNull { node -> provider.createAccessibilityNodeInfo(node.id)?.let { node.id to it } }.toMap()
            block(provider, infos)
        }
    }

    /**
     * TalkBack が「値を調整できる部品」として扱う要素（範囲の情報を持つか、値を設定する操作を持つもの）。
     * 進める・戻すの操作だけでは見分けない（横に送れるツールの並びも、その操作を持つ）
     */
    private fun AccessibilityNodeInfo.isAdjustable(): Boolean =
        rangeInfo != null || actionList.any { it.id == android.R.id.accessibilityActionSetProgress }

    @Test
    fun TalkBackに渡る調整できる部品は1つだけで_ツールの名前と値を持つ() {
        openTool = EditTool.EXPOSURE
        edit = exposureAt(25)
        showToolPanel()
        rule.onNodeWithContentDescription(exposureSliderDescription("+25")).performScrollTo()

        val adjustable = withAccessibilityInfos { _, infos ->
            infos.values.filter { it.isAdjustable() }.map { "${it.className}／${it.contentDescription}／${it.stateDescription}" }
        }

        // 2 つあると、TalkBack は読み上げの文を持たない方（中の Slider）にも止まり、そちらは 5 刻みの読み替えを通らない
        assertEquals(
            "TalkBack に渡る調整できる部品",
            listOf("android.widget.SeekBar／${exposureSliderDescription("+25")}／+25"),
            adjustable,
        )
    }

    @Test
    fun TalkBackの進める操作と戻す操作は_端末の窓口から送っても5ずつ動く() {
        openTool = EditTool.EXPOSURE
        edit = exposureAt(25)
        showToolPanel()
        rule.onNodeWithContentDescription(exposureSliderDescription("+25")).performScrollTo()

        // 調整できる部品の全部に「進める」を 1 回ずつ送る（TalkBack がどれに止まっても 5 だけ動くこと）
        val forwarded = withAccessibilityInfos { provider, infos ->
            infos.filterValues { it.isAdjustable() }.keys.map { id -> provider.performAction(id, AccessibilityNodeInfo.ACTION_SCROLL_FORWARD, null) }
        }
        rule.runOnIdle {
            assertTrue("進める操作を受けた部品が無い: $forwarded", forwarded.isNotEmpty() && forwarded.all { it })
            assertEquals("進める操作 1 回で知らせる値", listOf(EditTool.EXPOSURE to 30), sliderChanges)
        }

        sliderChanges.clear()
        val backed = withAccessibilityInfos { provider, infos ->
            infos.filterValues { it.isAdjustable() }.keys.map { id -> provider.performAction(id, AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD, null) }
        }
        rule.runOnIdle {
            assertTrue("戻す操作を受けた部品が無い: $backed", backed.isNotEmpty() && backed.all { it })
            assertEquals("戻す操作 1 回で知らせる値", listOf(EditTool.EXPOSURE to 25), sliderChanges)
        }
    }

    @Test
    fun スライダーの範囲の情報は_マイナス100から100を5刻みに分けた形で外の箱が持つ() {
        openTool = EditTool.EXPOSURE
        edit = exposureAt(25)
        showToolPanel()

        // 読み上げの文と値を設定する操作を持つ要素（外の箱）が、範囲の情報も持つ。刻みの数 39 ＝ 200 ÷ 5 − 1
        val node = rule.onNodeWithContentDescription(exposureSliderDescription("+25"))
            .assert(SemanticsMatcher.keyIsDefined(SemanticsActions.SetProgress))
            .fetchSemanticsNode()
        assertEquals(
            ProgressBarRangeInfo(current = 25f, range = -100f..100f, steps = 39),
            node.config.getOrNull(SemanticsProperties.ProgressBarRangeInfo),
        )
    }

    @Test
    fun ゼロに戻すは値があるときだけ押せ_押すと0にして1手として知らせる() {
        openTool = EditTool.EXPOSURE
        edit = exposureAt(0)
        showToolPanel()

        // 値が 0 の間は押せない
        rule.onNodeWithText(text(R.string.edit_slider_reset)).assertIsNotEnabled()

        edit = exposureAt(25)
        rule.onNodeWithText(text(R.string.edit_slider_reset)).assertIsEnabled().performClick()

        // 始まり→値（0）→終わりの 3 つで 1 手（スライダーの 1 回の操作と同じ）
        rule.runOnIdle {
            assertEquals(listOf(EditTool.EXPOSURE to 0), sliderChanges)
            assertEquals(1, sliderStartCount)
            assertEquals(1, sliderFinishCount)
        }
    }

    // ================= EditToolPanel：元に戻す・やり直し =================

    @Test
    fun 履歴が無いときは元に戻すもやり直しも押せず_押しても何も呼ばない() {
        history = EditHistory.EMPTY
        showToolPanel()

        rule.onNodeWithContentDescription(text(R.string.edit_undo)).assertIsNotEnabled().performClick()
        rule.onNodeWithContentDescription(text(R.string.edit_redo)).assertIsNotEnabled().performClick()

        rule.runOnIdle {
            assertEquals("押せない元に戻すで呼ばれた回数", 0, undoCount)
            assertEquals("押せないやり直しで呼ばれた回数", 0, redoCount)
        }
    }

    @Test
    fun 元に戻せる履歴だけがあるときは元に戻すだけが押せる() {
        history = undoOnly
        showToolPanel()

        rule.onNodeWithContentDescription(text(R.string.edit_redo)).assertIsNotEnabled()
        rule.onNodeWithContentDescription(text(R.string.edit_undo)).assertIsEnabled().performClick()

        rule.runOnIdle {
            assertEquals(1, undoCount)
            assertEquals(0, redoCount)
        }
    }

    @Test
    fun やり直せる履歴だけがあるときはやり直しだけが押せる() {
        history = redoOnly
        showToolPanel()

        rule.onNodeWithContentDescription(text(R.string.edit_undo)).assertIsNotEnabled()
        rule.onNodeWithContentDescription(text(R.string.edit_redo)).assertIsEnabled().performClick()

        rule.runOnIdle {
            assertEquals(0, undoCount)
            assertEquals(1, redoCount)
        }
    }

    @Test
    fun 元に戻すとやり直しは記号だけでも説明つきのボタンとして読まれる() {
        history = undoOnly
        showToolPanel()

        // 見える字は記号だけ。TalkBack には説明（contentDescription）とボタンの役割を読ませる（13.4）
        rule.onNodeWithContentDescription(text(R.string.edit_undo)).assertHasClickAction().assert(roleIs(Role.Button))
        rule.onNodeWithContentDescription(text(R.string.edit_redo)).assert(roleIs(Role.Button))
    }

    @Test
    fun 部品を無効にしている間は全ての操作が押せない() {
        // トリミング・回転の画面を開いている間の状態（design.md:731）。履歴もスライダーも開いていても全部無効
        history = EditHistory(undo = listOf(PhotoEdit.NONE), redo = listOf(PhotoEdit.NONE))
        openTool = EditTool.EXPOSURE
        edit = exposureAt(25)
        panelEnabled = false
        showToolPanel()

        rule.onNodeWithContentDescription(text(R.string.edit_undo)).assertIsNotEnabled()
        rule.onNodeWithContentDescription(text(R.string.edit_redo)).assertIsNotEnabled()
        rule.onNodeWithText(text(R.string.edit_loadout_open)).assertIsNotEnabled()
        rule.onNodeWithText(text(R.string.edit_slider_reset)).assertIsNotEnabled()
        rule.onNodeWithContentDescription(exposureSliderDescription("+25")).assertIsNotEnabled()
        tools.forEach { tool ->
            rule.onNodeWithText(tool.displayName).performScrollTo().assertIsNotEnabled()
        }
    }

    @Test
    fun ツールの並びを変えるボタンは押すと装備の画面を開く知らせを1回出す() {
        showToolPanel()

        rule.onNodeWithText(text(R.string.edit_loadout_open)).assertIsEnabled().performClick()

        rule.runOnIdle { assertEquals(1, loadoutOpenCount) }
    }

    // ================= EditToolPanel：ツールの並び（選択・調整済みの印） =================

    @Test
    fun 開いているツールは選択中の状態で読まれ_ほかのツールは選択中でない() {
        openTool = EditTool.EXPOSURE
        showToolPanel()

        // 選択中を色や枠だけでなく、選択の状態（selected）とラジオボタンの役割で伝える（13.8）
        rule.onNodeWithText(EditTool.EXPOSURE.displayName).assertIsSelected().assert(roleIs(Role.RadioButton))
        rule.onNodeWithText(EditTool.BRIGHTNESS.displayName).performScrollTo().assertIsNotSelected().assert(roleIs(Role.RadioButton))
    }

    @Test
    fun スライダーのツールは開いているものをもう一度押すと閉じる知らせになり_別のツールはそのツールを知らせる() {
        openTool = EditTool.EXPOSURE
        showToolPanel()

        rule.onNodeWithText(EditTool.EXPOSURE.displayName).performClick()
        rule.onNodeWithText(EditTool.BRIGHTNESS.displayName).performScrollTo().performClick()

        rule.runOnIdle { assertEquals(listOf<EditTool?>(null, EditTool.BRIGHTNESS), toolSelections) }
    }

    @Test
    fun 切り抜きのツールは押すとそのツールを知らせるだけでスライダーは出ない() {
        openTool = EditTool.CROP_AND_ROTATE
        showToolPanel()

        // 開いていても、押すたびにそのツールを渡す（閉じる null にしない）
        rule.onNodeWithText(EditTool.CROP_AND_ROTATE.displayName).performScrollTo().performClick()

        rule.runOnIdle { assertEquals(listOf<EditTool?>(EditTool.CROP_AND_ROTATE), toolSelections) }
        // 切り抜きのツールにはスライダーが無い（値を設定する操作を持つ要素が 0 個）
        rule.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsActions.SetProgress)).assertCountEquals(0)
    }

    @Test
    fun 調整済みのツールには点と調整済みの文字が付き_調整していないツールには付かない() {
        edit = exposureAt(25)
        showToolPanel()

        // 点と文字の両方（色だけで伝えない：3.7）。1 つのツールの要素の中に、名前に続けて読まれる
        rule.onNodeWithText(EditTool.EXPOSURE.displayName).assert(hasText("●")).assert(hasText(text(R.string.edit_tool_adjusted)))
        // 調整していないツールは名前だけ
        rule.onNodeWithText(EditTool.BRIGHTNESS.displayName).performScrollTo().assertTextEquals(EditTool.BRIGHTNESS.displayName)
        // 印が付くのは調整した 1 つだけ
        rule.onAllNodesWithText(text(R.string.edit_tool_adjusted)).assertCountEquals(1)
    }

    @Test
    fun 切り抜きか回転を掛けたときはトリミングと回転のツールに調整済みの印が付く() {
        edit = PhotoEdit.NONE.copy(geometry = EditGeometry(quarterTurns = 1))
        showToolPanel()

        rule.onNodeWithText(EditTool.CROP_AND_ROTATE.displayName).performScrollTo()
            .assert(hasText("●"))
            .assert(hasText(text(R.string.edit_tool_adjusted)))
        rule.onAllNodesWithText(text(R.string.edit_tool_adjusted)).assertCountEquals(1)
    }

    // ================= EditToolPanel：押せる大きさ =================

    @Test
    fun ツールの部品の押せる所は全て48dp以上() {
        openTool = EditTool.EXPOSURE
        edit = exposureAt(25)
        history = EditHistory(undo = listOf(PhotoEdit.NONE), redo = listOf(PhotoEdit.NONE))
        showToolPanel()

        rule.onNodeWithContentDescription(text(R.string.edit_undo)).assertTouchTargetAtLeast48dp("元に戻す")
        rule.onNodeWithContentDescription(text(R.string.edit_redo)).assertTouchTargetAtLeast48dp("やり直し")
        rule.onNodeWithText(text(R.string.edit_loadout_open)).assertTouchTargetAtLeast48dp("ツールの並びを変える")
        rule.onNodeWithText(text(R.string.edit_slider_reset)).assertTouchTargetAtLeast48dp("0に戻す")
        rule.onNodeWithContentDescription(exposureSliderDescription("+25")).assertTouchTargetAtLeast48dp("スライダー")
        tools.forEach { tool ->
            rule.onNodeWithText(tool.displayName).assertTouchTargetAtLeast48dp("ツール ${tool.displayName}")
        }
    }

    // ================= CropPanel =================

    private val cropEdges = listOf(
        CropMath.Edge.LEFT to R.string.crop_edge_left,
        CropMath.Edge.TOP to R.string.crop_edge_top,
        CropMath.Edge.RIGHT to R.string.crop_edge_right,
        CropMath.Edge.BOTTOM to R.string.crop_edge_bottom,
    )

    private val nudges = mutableListOf<Pair<CropMath.Edge, Boolean>>()
    private var rotateLeftCount = 0
    private var rotateRightCount = 0
    private var confirmCount = 0
    private var cancelCount = 0

    /** CropPanel を出す。絵は null（描かない）。辺・回転・確定・キャンセルのボタンは絵が無くても押せる */
    private fun showCropPanel() {
        showScrollable {
            CropPanel(
                image = null,
                crop = NormalizedRect.FULL,
                onDrag = { _, _, _ -> },
                onNudge = { edge, inward -> nudges.add(edge to inward) },
                onRotateLeft = { rotateLeftCount++ },
                onRotateRight = { rotateRightCount++ },
                onConfirm = { confirmCount++ },
                onCancel = { cancelCount++ },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }

    private fun edgeInText(nameId: Int): String = text(R.string.crop_edge_in, text(nameId))

    private fun edgeOutText(nameId: Int): String = text(R.string.crop_edge_out, text(nameId))

    @Test
    fun 切り抜きの辺のボタンは4つの辺それぞれに内側へと外側へがあり_押すとその辺と向きを知らせる() {
        showCropPanel()

        // 取っ手を引けない人向けの代わりの操作（13.2）。文言に辺の名前が入るので、TalkBack でもどの辺か分かる
        cropEdges.forEach { (_, nameId) ->
            rule.onNodeWithText(edgeInText(nameId)).performScrollTo().assertIsEnabled().performClick()
            rule.onNodeWithText(edgeOutText(nameId)).performScrollTo().assertIsEnabled().performClick()
        }

        val expected = cropEdges.flatMap { (edge, _) -> listOf(edge to true, edge to false) }
        rule.runOnIdle { assertEquals("押した順の（辺, 内側へか）", expected, nudges) }
    }

    @Test
    fun 回転と確定とキャンセルのボタンは押すとそれぞれの知らせを1回出す() {
        showCropPanel()

        rule.onNodeWithText(text(R.string.crop_rotate_left)).performScrollTo().performClick()
        rule.onNodeWithText(text(R.string.crop_rotate_right)).performScrollTo().performClick()
        rule.onNodeWithText(text(R.string.crop_confirm)).performScrollTo().performClick()
        rule.onNodeWithText(text(R.string.crop_cancel)).performScrollTo().performClick()

        rule.runOnIdle {
            assertEquals(1, rotateLeftCount)
            assertEquals(1, rotateRightCount)
            assertEquals(1, confirmCount)
            assertEquals(1, cancelCount)
        }
    }

    @Test
    fun 切り抜きの枠には切り抜く範囲という読み上げがある() {
        showCropPanel()

        rule.onNodeWithContentDescription(text(R.string.crop_frame_description)).performScrollTo().assertIsDisplayed()
    }

    @Test
    fun 切り抜きの部品の押せる所は全て48dp以上() {
        showCropPanel()

        listOf(R.string.crop_rotate_left, R.string.crop_rotate_right, R.string.crop_confirm, R.string.crop_cancel).forEach { id ->
            rule.onNodeWithText(text(id)).assertTouchTargetAtLeast48dp(text(id))
        }
        cropEdges.forEach { (_, nameId) ->
            rule.onNodeWithText(edgeInText(nameId)).assertTouchTargetAtLeast48dp(edgeInText(nameId))
            rule.onNodeWithText(edgeOutText(nameId)).assertTouchTargetAtLeast48dp(edgeOutText(nameId))
        }
    }

    // ================= LoadoutSheetContent（装備の画面の中身） =================

    private val moves = mutableListOf<Pair<EditTool, Int>>()
    private val toggles = mutableListOf<EditTool>()

    private fun showLoadout(checked: Set<EditTool>) {
        show {
            LoadoutSheetContent(
                tools = Loadout.DEFAULT.tools,
                checked = checked,
                onToggle = { toggles.add(it) },
                onMove = { tool, offset -> moves.add(tool to offset) },
                onSave = {},
                onDismiss = {},
            )
        }
    }

    private fun moveUpDescription(tool: EditTool) = text(R.string.loadout_move_up, tool.displayName)

    private fun moveDownDescription(tool: EditTool) = text(R.string.loadout_move_down, tool.displayName)

    @Test
    fun 装備の上へと下へのボタンはツール名つきで読まれ_端では押せず_押すと1つ動かす知らせを出す() {
        val all = Loadout.DEFAULT.tools
        showLoadout(checked = all.toSet())

        // 先頭は「上へ」が押せず、末尾は「下へ」が押せない
        rule.onNode(hasContentDescription(moveUpDescription(all.first()))).performScrollTo().assertIsNotEnabled()
        rule.onNode(hasContentDescription(moveDownDescription(all.last()))).performScrollTo().assertIsNotEnabled()
        // 真ん中は両方押せる。押すと（ツール, -1 か +1）を知らせる（7.7）
        val middle = all[1]
        rule.onNode(hasContentDescription(moveUpDescription(middle))).performScrollTo().assertIsEnabled().performClick()
        rule.onNode(hasContentDescription(moveDownDescription(middle))).performScrollTo().assertIsEnabled().performClick()

        rule.runOnIdle { assertEquals(listOf(middle to -1, middle to 1), moves) }
    }

    @Test
    fun 装備の引く取っ手の記号は読み上げに出ない() {
        showLoadout(checked = Loadout.DEFAULT.tools.toSet())

        // 同じ操作を上へ・下へのボタンが担うので、取っ手の「≡」は二重に読ませない
        rule.onNodeWithText("≡").assertDoesNotExist()
    }

    @Test
    fun 装備のチェックは入っているかどうかの状態で読まれ_押すとそのツールを知らせる() {
        showLoadout(checked = setOf(EditTool.EXPOSURE))

        rule.onNode(hasText(EditTool.EXPOSURE.displayName) and isToggleable()).assertIsOn()
        rule.onNode(hasText(EditTool.BRIGHTNESS.displayName) and isToggleable()).performScrollTo().assertIsOff().performClick()

        rule.runOnIdle { assertEquals(listOf(EditTool.BRIGHTNESS), toggles) }
    }

    @Test
    fun 装備の画面の押せる所は全て48dp以上() {
        showLoadout(checked = setOf(EditTool.EXPOSURE))

        Loadout.DEFAULT.tools.forEach { tool ->
            rule.onNode(hasContentDescription(moveUpDescription(tool))).assertTouchTargetAtLeast48dp("${tool.displayName}を上へ")
            rule.onNode(hasContentDescription(moveDownDescription(tool))).assertTouchTargetAtLeast48dp("${tool.displayName}を下へ")
            rule.onNode(hasText(tool.displayName) and isToggleable()).assertTouchTargetAtLeast48dp("${tool.displayName}のチェック")
        }
        // 下のキャンセル・保存は、一覧の外（縦に送る所の外）にあるので送らずに測る
        rule.onNodeWithText(text(R.string.action_cancel)).assertTouchTargetAtLeast48dp("キャンセル", scroll = false)
        rule.onNodeWithText(text(R.string.action_save)).assertTouchTargetAtLeast48dp("保存", scroll = false)
    }

    // ================= DraftListSheet（下書きの一覧） =================

    private val openedDrafts = mutableListOf<DraftId>()

    /** 保存の日時の表示。DraftListSheet の SAVED_AT_FORMAT（「年月日 時:分」・日本語の書式・端末の時間帯）と同じ形で作る */
    private fun savedAtText(epochMillis: Long): String =
        DateTimeFormatter.ofPattern("yyyy年M月d日 H:mm", Locale.JAPAN).format(Instant.ofEpochMilli(epochMillis).atZone(ZoneId.systemDefault()))

    private fun draftDescription(epochMillis: Long, photoCount: Int): String =
        text(R.string.drafts_item_description, savedAtText(epochMillis), photoCount)

    private val savedAtNewer = 1_700_000_000_000L
    private val savedAtOlder = 1_690_000_000_000L

    private fun draft(id: String, savedAt: Long, photoCount: Int, isBroken: Boolean = false) = LocalDraftSummary(
        id = DraftId(id),
        savedAtEpochMillis = savedAt,
        photoCount = photoCount,
        thumbnailUri = null,
        isBroken = isBroken,
    )

    private fun showDraftList(drafts: List<LocalDraftSummary>, isOpening: Boolean = false, openEnabled: Boolean = true) {
        show {
            DraftListSheet(
                drafts = drafts,
                isOpening = isOpening,
                onOpen = { openedDrafts.add(it) },
                onDelete = {},
                onDismiss = {},
                openEnabled = openEnabled,
            )
        }
    }

    @Test
    fun 開くのを止めている間は下書きの行は押せず_押しても開かず_削除は押せる() {
        // 進行中の投稿がある間の形（問い 34）。読み込み中ではないので、読み込み中の文言は出ない
        showDraftList(listOf(draft("d1", savedAtNewer, 3)), openEnabled = false)

        rule.onNodeWithText(text(R.string.drafts_loading)).assertDoesNotExist()
        rule.onNode(hasContentDescription(draftDescription(savedAtNewer, 3))).assertIsNotEnabled().performClick()
        rule.runOnIdle { assertTrue("止めている間に押しても開かない", openedDrafts.isEmpty()) }
        rule.onNodeWithText(text(R.string.action_delete)).assertIsEnabled().assertHasClickAction()
    }

    @Test
    fun 下書きの行は保存した日時と写真の枚数を1つの説明として読まれ_押すとその下書きを開く() {
        showDraftList(listOf(draft("d1", savedAtNewer, 3), draft("d2", savedAtOlder, 1)))

        // 「…に保存した下書き、写真3枚」（13.2）。行全体がボタンとして押せる
        val first = rule.onNode(hasContentDescription(draftDescription(savedAtNewer, 3)))
        first.assertIsDisplayed().assertHasClickAction().assert(roleIs(Role.Button))
        rule.onNode(hasContentDescription(draftDescription(savedAtOlder, 1))).assertHasClickAction()

        first.performClick()
        rule.runOnIdle { assertEquals(listOf(DraftId("d1")), openedDrafts) }
    }

    @Test
    fun 下書きを読み込んでいる間は読み込み中の文言を出し_行は押せない() {
        showDraftList(listOf(draft("d1", savedAtNewer, 3)), isOpening = true)

        rule.onNodeWithText(text(R.string.drafts_loading)).assertIsDisplayed()
        // 二重に開かないよう、読み込み中は行を押せない
        rule.onNode(hasContentDescription(draftDescription(savedAtNewer, 3))).assertIsNotEnabled().performClick()
        rule.runOnIdle { assertTrue("読み込み中に押しても開かない", openedDrafts.isEmpty()) }
    }

    @Test
    fun 読めない下書きは読み込めませんの文言と削除だけを出し_開く操作は付かない() {
        showDraftList(listOf(draft("broken", savedAtNewer, 2, isBroken = true)))

        // 開く操作が付かない（8.18）：文言の要素は押せず、行の説明（開く行の読み上げ）も出ない
        rule.onNodeWithText(text(R.string.drafts_broken)).assertIsDisplayed().assertHasNoClickAction()
        rule.onNode(hasContentDescription(draftDescription(savedAtNewer, 2))).assertDoesNotExist()
        // 削除のボタンは押せる
        rule.onNodeWithText(text(R.string.action_delete)).assertIsEnabled().assertHasClickAction()
    }

    @Test
    fun 下書きが0件のときは下書きはありませんを出す() {
        showDraftList(emptyList())

        rule.onNodeWithText(text(R.string.drafts_empty)).assertIsDisplayed()
    }

    @Test
    fun 下書きの一覧の押せる所は48dp以上() {
        showDraftList(listOf(draft("d1", savedAtNewer, 3), draft("broken", savedAtOlder, 2, isBroken = true)))

        // 一覧は LazyColumn で、performScrollTo の対象でない。行は 2 つだけで画面に収まるので送らずに測る
        rule.onNode(hasContentDescription(draftDescription(savedAtNewer, 3))).assertTouchTargetAtLeast48dp("下書きの行", scroll = false)
        rule.onAllNodesWithText(text(R.string.action_delete)).assertCountEquals(2)
        rule.onAllNodesWithText(text(R.string.action_delete))[0].assertTouchTargetAtLeast48dp("削除（1 つ目）", scroll = false)
        rule.onAllNodesWithText(text(R.string.action_delete))[1].assertTouchTargetAtLeast48dp("削除（2 つ目）", scroll = false)
    }

    // ================= LeaveDialog（編集をやめるときの確かめ） =================

    private val leaveChoices = mutableListOf<LeaveChoice>()

    private fun showLeaveDialog(isSavingDraft: Boolean = false, canSaveDraft: Boolean = true) {
        show {
            LeaveDialog(
                question = LeaveQuestion.DISCARD_OR_DRAFT,
                onChoice = { leaveChoices.add(it) },
                isSavingDraft = isSavingDraft,
                canSaveDraft = canSaveDraft,
            )
        }
    }

    @Test
    fun 下書きに保存を止めている間は保存だけが押せず_破棄と編集を続けるは押せる() {
        // この画面の投稿の途中の形（問い 34）
        showLeaveDialog(canSaveDraft = false)

        rule.onNodeWithText(text(R.string.edit_leave_save)).assertIsNotEnabled().performClick()
        rule.onNodeWithText(text(R.string.edit_leave_discard)).assertIsEnabled()
        rule.onNodeWithText(text(R.string.edit_leave_continue)).assertIsEnabled()
        rule.runOnIdle { assertTrue("止めている間に押しても保存を知らせない", leaveChoices.isEmpty()) }
    }

    @Test
    fun やめる確かめの3つのボタンは48dp以上で_押すとそれぞれの答えを知らせる() {
        showLeaveDialog()

        rule.onNodeWithText(text(R.string.edit_leave_title)).assertIsDisplayed()
        listOf(R.string.edit_leave_save, R.string.edit_leave_discard, R.string.edit_leave_continue).forEach { id ->
            rule.onNodeWithText(text(id)).assertTouchTargetAtLeast48dp(text(id), scroll = false)
        }
        rule.onNodeWithText(text(R.string.edit_leave_save)).performClick()
        rule.onNodeWithText(text(R.string.edit_leave_discard)).performClick()
        rule.onNodeWithText(text(R.string.edit_leave_continue)).performClick()

        rule.runOnIdle { assertEquals(listOf(LeaveChoice.SAVE_DRAFT, LeaveChoice.DISCARD, LeaveChoice.CONTINUE), leaveChoices) }
    }

    @Test
    fun 下書きを保存している間は保存と破棄が押せず_編集を続けるは押せる() {
        showLeaveDialog(isSavingDraft = true)

        rule.onNodeWithText(text(R.string.edit_leave_save)).assertIsNotEnabled()
        rule.onNodeWithText(text(R.string.edit_leave_discard)).assertIsNotEnabled()
        rule.onNodeWithText(text(R.string.edit_leave_continue)).assertIsEnabled()
    }

    // ================= FilterOptions（フィルターの選択） =================

    private val filterSelections = mutableListOf<FilterId?>()

    private fun showFilterOptions(selected: FilterId?) {
        showScrollable {
            FilterOptions(
                selected = selected,
                samples = List(FILTER_OPTIONS.size) { null },
                onSelect = { filterSelections.add(it) },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }

    private fun filterName(filter: FilterId?): String = filter?.displayName ?: text(R.string.compose_filter_none)

    @Test
    fun 選択中のフィルターは選択の状態とラジオボタンの役割で読まれ_ほかは選択中でない() {
        showFilterOptions(selected = FilterId.DRAMA)

        // 枠や太字といった見た目だけでなく、意味の情報としても選択中を伝える（13.8）
        rule.onNodeWithText(filterName(FilterId.DRAMA)).assertIsSelected().assert(roleIs(Role.RadioButton))
        FILTER_OPTIONS.filter { it != FilterId.DRAMA }.forEach { option ->
            rule.onNodeWithText(filterName(option)).performScrollTo().assertIsNotSelected()
        }
    }

    @Test
    fun フィルターを選ばないときは_なし_が選択中として読まれる() {
        showFilterOptions(selected = null)

        rule.onNodeWithText(text(R.string.compose_filter_none)).assertIsSelected()
        rule.onNodeWithText(filterName(FilterId.SOFT)).performScrollTo().assertIsNotSelected()
    }

    @Test
    fun フィルターを押すとそのフィルターを1つだけ知らせ_なしを押すとヌルを知らせる() {
        showFilterOptions(selected = FilterId.DRAMA)

        rule.onNodeWithText(filterName(FilterId.SOFT)).performScrollTo().performClick()
        rule.onNodeWithText(filterName(null)).performScrollTo().performClick()

        rule.runOnIdle { assertEquals(listOf<FilterId?>(FilterId.SOFT, null), filterSelections) }
    }

    @Test
    fun フィルターの選択肢の押せる所は全て48dp以上() {
        showFilterOptions(selected = null)

        FILTER_OPTIONS.forEach { option ->
            rule.onNodeWithText(filterName(option)).assertTouchTargetAtLeast48dp("フィルター ${filterName(option)}")
        }
    }

    // ================= EditedPhotoPreview =================

    @Test
    fun プレビューの写真は何枚目かを画像として読まれ_複数枚なら位置の表示が出る() {
        val photos = listOf(
            EditingPhoto(WorkingPhoto(uri = "file:///dummy-1.jpg", relativeFile = null, capturedAt = null)),
            EditingPhoto(WorkingPhoto(uri = "file:///dummy-2.jpg", relativeFile = null, capturedAt = null)),
        )
        showScrollable {
            EditedPhotoPreview(
                photos = photos,
                previews = emptyMap(),
                pagerState = rememberPagerState(pageCount = { photos.size }),
                modifier = Modifier.fillMaxWidth(),
            )
        }

        // 絵がまだ描けていなくても「1枚目の写真」と画像の役割で読ませる
        rule.onNodeWithContentDescription(text(R.string.compose_photo_description, 1)).assertIsDisplayed().assert(roleIs(Role.Image))
        rule.onNodeWithText(text(R.string.compose_page_indicator, 1, photos.size)).assertIsDisplayed()
    }

    // ---- 描けない写真の文言（タスク 20.6 の③） ----

    private var previewImages by mutableStateOf<Map<Int, PreviewImage>>(emptyMap())
    private var failedPreviews by mutableStateOf<Set<Int>>(emptySet())

    private fun showPreview() {
        val photos = listOf(
            EditingPhoto(WorkingPhoto(uri = "file:///dummy-1.jpg", relativeFile = null, capturedAt = null)),
            EditingPhoto(WorkingPhoto(uri = "file:///dummy-2.jpg", relativeFile = null, capturedAt = null)),
        )
        showScrollable {
            EditedPhotoPreview(
                photos = photos,
                previews = previewImages,
                pagerState = rememberPagerState(pageCount = { photos.size }),
                modifier = Modifier.fillMaxWidth(),
                failedPreviews = failedPreviews,
            )
        }
    }

    @Test
    fun 描けない印の付いた写真にだけ表示できなかった文言が出て_絵がまだ無いだけの写真には出ない() {
        showPreview()

        // 絵がまだ無いだけ（まだ描いていない）：文言は出さない（読み込みのたびに一瞬出るのを避ける）
        rule.onNodeWithContentDescription(text(R.string.compose_photo_description, 1)).assertIsDisplayed()
        rule.onAllNodesWithText(text(R.string.compose_preview_failed)).assertCountEquals(0)

        // 表示中の写真に、描けない印が付いた
        failedPreviews = setOf(0)
        rule.onNodeWithText(text(R.string.compose_preview_failed)).assertIsDisplayed()
        // 何枚目の写真かは、文言が出ていても読まれる
        rule.onNodeWithContentDescription(text(R.string.compose_photo_description, 1)).assertIsDisplayed().assert(roleIs(Role.Image))

        // 印が別の写真（表示していない 2 枚目）だけなら、表示中の写真には出ない
        failedPreviews = setOf(1)
        rule.onAllNodesWithText(text(R.string.compose_preview_failed)).assertCountEquals(0)
    }

    @Test
    fun 届いた絵を画像にできない写真にも表示できなかった文言が出て_描ける絵が届けば消える() {
        // 寸法が 0 の絵（画像にできない）
        previewImages = mapOf(0 to PreviewImage(IntArray(0), 0, 0))
        showPreview()
        rule.onNodeWithText(text(R.string.compose_preview_failed)).assertIsDisplayed()

        // 描ける絵（2×2 の灰色）が届いた
        previewImages = mapOf(0 to PreviewImage(IntArray(4) { 0xFF808080.toInt() }, 2, 2))
        rule.onAllNodesWithText(text(R.string.compose_preview_failed)).assertCountEquals(0)
    }
}
