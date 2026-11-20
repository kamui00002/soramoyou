// ⭐️ 編集ツールの装備の画面（使うツールを選び、並びを変える）（Kiro android-edit-tools タスク 10・部品U4・design.md:1002）
package com.yoshidometoru.soramoyou.feature.compose

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.edit.EditTool

/**
 * 編集ツールの装備の画面（下から出るシート）。使うツールをチェックで選び、並び順を変える。
 *
 * この部品は状態を持たない。状態と操作は全部引数で受け取り、画面の側が編集の状態と結びつける。
 * PostComposerScreen の LoadoutSheetHost が、並べ替えとチェックの途中を持って呼ぶ。
 *
 * 並べ替えの操作は 2 通り：
 * - 行の左端の「≡」を縦に引く（目の見える人向け。長押しは要らず、触って動かせばよい）
 * - 行ごとの「上へ」「下へ」のボタン（TalkBack・スイッチ操作でも並べ替えられる。要件 7.7）
 *
 * 引数：
 * - [tools] 画面に出すツールの全部を、今の並び順で渡す。選ばれていないツールも含める（外すと下に残り、またチェックできる）
 * - [checked] [tools] のうち、使う（チェックが入っている）ツール
 * - [onToggle] 行のチェックを切り替えたとき。押されたツールを渡す
 * - [onMove] 並べ替え。[tools] の中でそのツールを `offset` 個だけ動かす（-1 は上へ・+1 は下へ）。
 *   端を越える動きは、この部品が呼ばない
 * - [onSave] 保存を押したとき。1 個も選ばれていない間は、保存のボタンが押せず、呼ばれない（要件 7.5）。
 *   保存して使う装備は `Loadout(tools.filter { it in checked })`（画面の側が作る）
 * - [onDismiss] 閉じたとき（外を押す・下へ払う・キャンセル・戻る操作）
 * - [isSaving] 保存の最中。true の間は保存のボタンを押せない
 * - [saveFailed] 保存に失敗した。true の間は loadout_save_failed を出す（直したあとは false に戻す）
 * - [modifier] シートに渡す修飾子（既定は何もしない）
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LoadoutSheet(
    tools: List<EditTool>,
    checked: Set<EditTool>,
    onToggle: (EditTool) -> Unit,
    onMove: (tool: EditTool, offset: Int) -> Unit,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
    isSaving: Boolean = false,
    saveFailed: Boolean = false,
    modifier: Modifier = Modifier,
) {
    // 一覧が長くなっても全部見えるよう、部分的に開いた状態を飛ばして最初から広げる
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        modifier = modifier,
    ) {
        LoadoutSheetContent(
            tools = tools,
            checked = checked,
            onToggle = onToggle,
            onMove = onMove,
            onSave = onSave,
            onDismiss = onDismiss,
            isSaving = isSaving,
            saveFailed = saveFailed,
        )
    }
}

/**
 * [LoadoutSheet] の中身（見出し・説明・一覧・メッセージ・ボタン）。引数の意味は [LoadoutSheet] と同じ。
 * シートの外に置いても使えるよう分けてある（テストや確認用）。
 */
@Composable
fun LoadoutSheetContent(
    tools: List<EditTool>,
    checked: Set<EditTool>,
    onToggle: (EditTool) -> Unit,
    onMove: (tool: EditTool, offset: Int) -> Unit,
    onSave: () -> Unit,
    onDismiss: () -> Unit,
    isSaving: Boolean = false,
    saveFailed: Boolean = false,
    modifier: Modifier = Modifier,
) {
    // 引いている最中のツール・そこからの縦の移動量（px）・1 行の高さ（px）。ここだけが、この部品の持つ状態
    var draggingTool by remember { mutableStateOf<EditTool?>(null) }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    var rowHeightPx by remember { mutableFloatStateOf(0f) }

    // pointerInput の中は最初の引数を覚え続けるので、最新の値は rememberUpdatedState 越しに読む
    val latestTools by rememberUpdatedState(tools)
    val latestOnMove by rememberUpdatedState(onMove)

    val canSave = checked.isNotEmpty() && !isSaving

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp),
    ) {
        Text(
            text = stringResource(R.string.loadout_title),
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = stringResource(R.string.loadout_hint),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp, bottom = 8.dp),
        )

        // 一覧。高さは固定せず、足りなければ縦にスクロールする
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f, fill = false)
                .verticalScroll(rememberScrollState()),
        ) {
            tools.forEachIndexed { index, tool ->
                // 並べ替えで行の位置が変わっても、引いている最中の操作が途切れないよう、ツールを鍵にする
                key(tool) {
                    val isDragging = draggingTool == tool
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .fillMaxWidth()
                            .onSizeChanged { rowHeightPx = it.height.toFloat() }
                            .zIndex(if (isDragging) 1f else 0f)
                            .graphicsLayer { translationY = if (isDragging) dragOffset else 0f },
                    ) {
                        // 引く取っ手。ボタンが同じ操作を担うので、読み上げからは外す
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .widthIn(min = 48.dp)
                                .heightIn(min = 48.dp)
                                .clearAndSetSemantics {}
                                .pointerInput(tool) {
                                    detectDragGestures(
                                        onDragStart = {
                                            draggingTool = tool
                                            dragOffset = 0f
                                        },
                                        onDragEnd = {
                                            draggingTool = null
                                            dragOffset = 0f
                                        },
                                        onDragCancel = {
                                            draggingTool = null
                                            dragOffset = 0f
                                        },
                                        onDrag = { change, amount ->
                                            change.consume()
                                            dragOffset += amount.y
                                            // 1 行の半分を越えたら 1 つ動かし、動かした分だけ見た目の移動量を戻す
                                            val half = rowHeightPx / 2f
                                            val current = latestTools.indexOf(tool)
                                            if (rowHeightPx > 0f) {
                                                if (dragOffset > half && current < latestTools.lastIndex) {
                                                    latestOnMove(tool, 1)
                                                    dragOffset -= rowHeightPx
                                                } else if (dragOffset < -half && current > 0) {
                                                    latestOnMove(tool, -1)
                                                    dragOffset += rowHeightPx
                                                }
                                            }
                                        },
                                    )
                                },
                        ) {
                            Text(
                                text = "≡",
                                style = MaterialTheme.typography.titleLarge,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }

                        // チェックと名前。行の全体を 1 つのチェックとして押せる
                        val isChecked = tool in checked
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .weight(1f)
                                .heightIn(min = 48.dp)
                                .toggleable(
                                    value = isChecked,
                                    role = Role.Checkbox,
                                    onValueChange = { onToggle(tool) },
                                ),
                        ) {
                            // 押す先は行全体なので、チェック自身は操作を持たない
                            Checkbox(checked = isChecked, onCheckedChange = null)
                            Text(
                                text = tool.displayName,
                                style = MaterialTheme.typography.bodyLarge,
                                color = MaterialTheme.colorScheme.onSurface,
                                modifier = Modifier.padding(start = 12.dp),
                            )
                        }

                        // 上へ・下へ。見える字は記号 1 つで、読み上げる文は「<ツール名>を上へ」
                        val upDescription = stringResource(R.string.loadout_move_up, tool.displayName)
                        val downDescription = stringResource(R.string.loadout_move_down, tool.displayName)
                        TextButton(
                            onClick = { onMove(tool, -1) },
                            enabled = index > 0,
                            modifier = Modifier
                                .widthIn(min = 48.dp)
                                .heightIn(min = 48.dp)
                                .semantics { contentDescription = upDescription },
                        ) {
                            Text("▲")
                        }
                        TextButton(
                            onClick = { onMove(tool, 1) },
                            enabled = index < tools.lastIndex,
                            modifier = Modifier
                                .widthIn(min = 48.dp)
                                .heightIn(min = 48.dp)
                                .semantics { contentDescription = downDescription },
                        ) {
                            Text("▼")
                        }
                    }
                }
            }
        }

        // 1 個も選ばれていない間の案内（保存は押せない）。出た瞬間に読み上げる
        if (checked.isEmpty()) {
            Text(
                text = stringResource(R.string.loadout_need_one),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier
                    .padding(top = 8.dp)
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        // 保存に失敗したとき
        if (saveFailed) {
            Text(
                text = stringResource(R.string.loadout_save_failed),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier
                    .padding(top = 8.dp)
                    .semantics { liveRegion = LiveRegionMode.Polite },
            )
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 16.dp),
        ) {
            TextButton(
                onClick = onDismiss,
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Text(stringResource(R.string.action_cancel))
            }
            Button(
                onClick = onSave,
                enabled = canSave,
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Text(stringResource(R.string.action_save))
            }
        }
    }
}
