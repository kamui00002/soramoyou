// ⭐️ トリミング・回転の部品（Kiro android-edit-tools タスク 9・部品 U3・design.md:1000・要件 4.2〜4.5・4.8・13.2・13.4〜13.7）
package com.yoshidometoru.soramoyou.feature.compose

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.edit.CropMath
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.data.image.PreviewImage
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/*
 * トリミング・回転の画面の部品（部品 U3）。PostComposerScreen の編集の段が、トリミング・回転を開いている間（cropSession が null でない間）、プレビューの代わりに呼ぶ。
 *
 * 中身（design.md:1000）：
 * - 全体の絵の上に、切り抜く範囲の枠（4 隅の取っ手・中を引いての移動・3 分割の線）を描く。範囲の外は暗い幕で覆う（iOS CropOverlayView と同じ見た目）
 * - 左右の 90° 回転のボタン、確定・キャンセルのボタン
 * - 辺ごとの「内側へ」「外側へ」のボタン（1 回で 5%。刻みは CropMath.nudged の既定の step が持つ）。取っ手を引けない人
 *   （TalkBack だけで操作する人など）も、範囲を変えられる（要件 13.2）
 * - 縦横比の固定・90° より細かい傾き・反転の操作は置かない（要件 4.8 の確定＝D-4・利用者の判断 U3）
 *
 * 決まり：
 * - 状態と操作は引数で受ける（画面の状態を持つ役を参照しない）。範囲の計算の式は持たない。指の動きを「回転後の絵に対する割合」に
 *   直して [CropPanel] の onDrag で呼ぶ側へ知らせるだけで、範囲を内側に限る・各辺を 0.15 以上に保つのは CropMath（呼ぶ側の先）が受け持つ
 * - 色は MaterialTheme.colorScheme だけを使う。幕の暗さと 3 分割の線の薄さは、DrawScope の描く関数の alpha の引数で渡す
 *   （色の写しは作らない。ScreenStyleSourceTest の決まり）。押せる所は 48dp 以上（Material 3 のボタンは押せる範囲を 48dp に広げる）
 * - 高さを固定しない（文字 200% でもボタンの文字は折り返して伸びる）。中に縦の送りを持たないので、呼ぶ側は縦に送れる列の中に置く
 *   （今の投稿の画面の編集の段は、縦に送れる列の中にある）
 *
 * ■ 指の座標から「絵の中の割合」への直し方（いちばん間違えやすい所なので 1 か所にまとめた）
 * 1. 絵を描く矩形（[CropImageFrame]）は [fitCropImageFrame] の 1 か所だけで計算する。描く側（Canvas の drawImage・枠・幕）と、
 *    取っ手の当たりと指の割合の計算（pointerInput）は、どちらもこの同じ値を使う。値は整数の px に丸めてあるので、
 *    描いた絵と当たりの矩形が半端な px でずれない
 * 2. 矩形は、部品の大きさ（onSizeChanged で受け取る）から四方に [HANDLE_TOUCH_HALF]（24dp）を引いた中に、絵の縦横比を保って
 *    収める（letterbox）。四方を空けるのは、範囲が全体（FULL）のときに 4 隅の取っ手の 48dp の当たりが部品の外へはみ出さないため
 * 3. 指の位置 (px) を割合にするのは「(px − 矩形の左) ÷ 矩形の幅」「(py − 矩形の上) ÷ 矩形の高さ」。受け取る絵は
 *    回転まで済んだ全体の絵（design.md:731）なので、この割合はそのまま「回転後の絵に対する割合」である（部品の中で回転を扱わない）
 *
 * ■ onDrag に渡す dx・dy の意味（呼ぶ側の ViewModel の onCropDrag が合わせる約束）
 * - dx・dy は「前に知らせた時からの差分」で、回転後の絵の幅・高さに対する割合（右・下が正）。指を置いた時からの累計ではない
 * - ViewModel の公開の関数 onCropDrag(handle, dx, dy) は start も引き始め・引き終わりも受け取らないので、この形にした
 * - **呼ぶ側の約束**：届いたその時の範囲（cropSession.pending.crop）を start にし、dx・dy を丸めず・捨てず・まとめずにそのまま
 *   EditingState.dragCrop（→ CropMath.dragged(start, handle, dx, dy)）へ渡す。この約束が崩れると、枠が指からずれる
 * - 差分は「指が求める取っ手の位置 − 範囲の写しの取っ手の位置」で出す（取っ手の位置は、4 隅ならその角、MOVE なら左上の角）。
 *   指を置いた時に、指と取っ手の位置のずれ（つかんだ所）を控え、指が動くたびに「指の割合 − つかんだずれ」を求める位置にする。
 *   こうすると、CropMath が範囲を内側に止めたり 0.15 で止めたりした後も、枠が指から離れていかない（指が戻るまで枠は止まったまま。
 *   iOS の、指を置いた時からの累計で計算する動きと同じ見え方）。生の指の移動量を足していく形だと、止められた分だけ枠が指からずれる
 * - 範囲の写し：指を置いた時に、受け取った [CropPanel] の crop を写し、知らせた差分ごとに CropMath.dragged で進める（呼ぶ側が
 *   上の約束どおりに計算した結果と同じになる）。受け取った crop は作り直しの後でしか新しくならないので、それを基準にすると、
 *   呼ぶ側の状態が届くのが 1 回でも遅れたときに差分が二重に効いて枠が指より先へ行く。写しを基準にすれば、届くのが遅れてもずれない。
 *   部品は写しを呼ぶ側へ渡さない（呼ぶ側が受け取るのは差分だけ）。範囲の計算そのものは CropMath が持ち、部品は式を持たない
 * - 指を置いただけ（動かさない・少しだけ動かす）では知らせない。端末の「動かしたと見なす距離」（touchSlop）を超えてから知らせる
 *
 * ■ 取っ手の当たり（指を置いた時の位置で決める）
 * - 4 隅のどれかの角から縦横とも [HANDLE_TOUCH_HALF] 以内なら、その角（いちばん近い角）。当たりは角を中心にした 48dp の四角
 * - そうでなく、範囲の中なら MOVE（範囲を大きさを変えずに動かす）
 * - どちらでもなければ何もしない（指の動きを使わないので、外側の縦の送りがそのまま効く）。当たったときだけ指の動きを使い切る
 * - 範囲がとても小さいと（1 辺が 48dp より小さいと）、中の全部が角の当たりになり、MOVE をつかめない。そのときは辺のボタンで動かせる
 */

/**
 * トリミング・回転の画面の部品。
 *
 * @param image 回転まで済ませた全体の絵（`cropSession.pending.quarterTurns` で読み直して色を掛けた絵：design.md:731）。
 *   まだ描けていなければ null。null の間は絵と枠を描かず、取っ手も効かない（辺・回転・確定・キャンセルのボタンは押せる）
 * @param crop 切り抜く範囲（`cropSession.pending.crop`）。回転後の絵に対する割合（左上が原点・0〜1）
 * @param onDrag 取っ手か枠の中を引いたとき。引数は (取っ手, dx, dy)。dx・dy は前に知らせた時からの差分で、回転後の絵の幅・高さに
 *   対する割合（右・下が正）。呼ぶ側は今の範囲を start にして EditingState.dragCrop へ渡す（上の説明を参照）
 * @param onNudge 辺のボタンを押したとき。引数は (辺, 内側へなら true・外側へなら false)。1 回で 5% 動かすのは呼ぶ側の先の CropMath.nudged
 * @param onRotateLeft 「左に90°回す」を押したとき（反時計回りに 90°）
 * @param onRotateRight 「右に90°回す」を押したとき（時計回りに 90°）
 * @param onConfirm 「確定」を押したとき
 * @param onCancel 「キャンセル」を押したとき（呼ぶ側が始める前の範囲と向きに戻す：要件 4.5）
 * @param modifier 配置の調整（高さを固定しない）
 */
@Composable
fun CropPanel(
    image: PreviewImage?,
    crop: NormalizedRect,
    onDrag: (CropMath.Handle, Double, Double) -> Unit,
    onNudge: (CropMath.Edge, Boolean) -> Unit,
    onRotateLeft: () -> Unit,
    onRotateRight: () -> Unit,
    onConfirm: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
    ) {
        // 確定・キャンセルは上に置く（今の投稿の画面の上の段と同じく、左にキャンセル・右に進む側）。
        // 下に置くと、文字 200% で辺のボタン 8 個の下まで送らないと届かない
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = onCancel) {
                Text(text = stringResource(R.string.crop_cancel), textAlign = TextAlign.Center)
            }
            Button(onClick = onConfirm) {
                Text(text = stringResource(R.string.crop_confirm), textAlign = TextAlign.Center)
            }
        }

        CropFrameArea(image = image, crop = crop, onDrag = onDrag)

        // 左右の 90° 回転。アイコンの部品がこのアプリに無いので文字のボタンにする（読み上げも文字のまま：要件 13.4）
        ButtonPair(
            firstText = stringResource(R.string.crop_rotate_left),
            onFirst = onRotateLeft,
            secondText = stringResource(R.string.crop_rotate_right),
            onSecond = onRotateRight,
        )

        // 辺ごとの「内側へ」「外側へ」。文言は「左の辺を内側へ」のように辺の名前を含むので、TalkBack でもどの辺かが分かる
        CropMath.Edge.entries.forEach { edge ->
            val name = edgeName(edge)
            ButtonPair(
                firstText = stringResource(R.string.crop_edge_in, name),
                onFirst = { onNudge(edge, true) },
                secondText = stringResource(R.string.crop_edge_out, name),
                onSecond = { onNudge(edge, false) },
            )
        }
    }
}

/** 取っ手の当たりの半分の大きさ（角を中心にした 48dp の四角）。絵を描く矩形の四方の空きにも使う */
private val HANDLE_TOUCH_HALF = 24.dp

/** 取っ手の丸の半径（iOS の取っ手の丸は直径 14pt：CropOverlayView.swift の handleSize − 8） */
private val HANDLE_RADIUS = 7.dp

/** 範囲の外の幕の暗さ（iOS と同じ 0.55：CropOverlayView.swift の darkMask） */
private const val CURTAIN_ALPHA = 0.55f

/** 3 分割の線の薄さ（iOS と同じ 0.4：CropOverlayView.swift の gridLines） */
private const val GRID_ALPHA = 0.4f

/**
 * 絵を描く矩形（部品の中の px。整数に丸めてある）。描く側と当たりの側が同じ値を使う（[fitCropImageFrame] の 1 か所で作る）。
 * 名前に Crop を付けたのは、ファイルの中だけの型でも、同じパッケージのほかのファイルの同じ名前の型とぶつかるため。
 */
private class CropImageFrame(val left: Int, val top: Int, val width: Int, val height: Int) {
    /** 割合 [fraction]（0〜1 の外は端に寄せる）の横の位置（px）。描くときと当たりの判定に使う */
    fun xOf(fraction: Double): Float = left + (fraction.coerceIn(0.0, 1.0) * width).toFloat()

    /** 割合 [fraction]（0〜1 の外は端に寄せる）の縦の位置（px） */
    fun yOf(fraction: Double): Float = top + (fraction.coerceIn(0.0, 1.0) * height).toFloat()

    /** 横の位置 [px] を、絵の幅に対する割合にする（絵の外なら 0〜1 の外の値のまま。内側に限るのは CropMath） */
    fun fractionX(px: Float): Double = (px - left).toDouble() / width

    /** 縦の位置 [px] を、絵の高さに対する割合にする */
    fun fractionY(px: Float): Double = (px - top).toDouble() / height
}

/**
 * 部品の大きさ [area] の四方から [insetPx] を引いた中に、幅 [imageWidth]・高さ [imageHeight] の絵を縦横比を保って収めた矩形
 * （余った方向は真ん中に寄せる letterbox）。大きさが足りないか絵の大きさが 0 なら null。
 */
private fun fitCropImageFrame(area: IntSize, imageWidth: Int, imageHeight: Int, insetPx: Int): CropImageFrame? {
    val availableWidth = area.width - insetPx * 2
    val availableHeight = area.height - insetPx * 2
    if (availableWidth <= 0 || availableHeight <= 0 || imageWidth <= 0 || imageHeight <= 0) return null
    val scale = min(availableWidth.toDouble() / imageWidth, availableHeight.toDouble() / imageHeight)
    val width = (imageWidth * scale).roundToInt().coerceIn(1, availableWidth)
    val height = (imageHeight * scale).roundToInt().coerceIn(1, availableHeight)
    return CropImageFrame(left = (area.width - width) / 2, top = (area.height - height) / 2, width = width, height = height)
}

/**
 * 指を置いた位置 [position] が、どの取っ手に当たるか。4 隅の当たり（角を中心にした [touchHalf] の 2 倍の四角）を先に見て、
 * 重なるときはいちばん近い角。どの角でもなく範囲の中なら MOVE。どれでもなければ null。
 */
private fun handleAt(position: Offset, frame: CropImageFrame, crop: NormalizedRect, touchHalf: Float): CropMath.Handle? {
    val left = frame.xOf(crop.left)
    val top = frame.yOf(crop.top)
    val right = frame.xOf(crop.right)
    val bottom = frame.yOf(crop.bottom)
    val corners = listOf(
        CropMath.Handle.TOP_LEFT to Offset(left, top),
        CropMath.Handle.TOP_RIGHT to Offset(right, top),
        CropMath.Handle.BOTTOM_LEFT to Offset(left, bottom),
        CropMath.Handle.BOTTOM_RIGHT to Offset(right, bottom),
    )
    val corner = corners
        .filter { (_, point) -> abs(position.x - point.x) <= touchHalf && abs(position.y - point.y) <= touchHalf }
        .minByOrNull { (_, point) -> (position - point).getDistanceSquared() }
    if (corner != null) return corner.first
    return if (position.x in left..right && position.y in top..bottom) CropMath.Handle.MOVE else null
}

/** 取っ手 [handle] の位置（割合）。4 隅ならその角、MOVE なら左上の角。CropMath.dragged がその取っ手で動かす角と同じ */
private fun anchorOf(crop: NormalizedRect, handle: CropMath.Handle): Pair<Double, Double> = when (handle) {
    CropMath.Handle.TOP_LEFT, CropMath.Handle.MOVE -> crop.left to crop.top
    CropMath.Handle.TOP_RIGHT -> crop.right to crop.top
    CropMath.Handle.BOTTOM_LEFT -> crop.left to crop.bottom
    CropMath.Handle.BOTTOM_RIGHT -> crop.right to crop.bottom
}

/** 受け取った絵の画素（ARGB の整数の並び）を描ける形にする。画素の数が幅×高さに足りなければ null（描かない） */
private fun toImageBitmap(image: PreviewImage): ImageBitmap? {
    if (image.width <= 0 || image.height <= 0 || image.pixels.size < image.width * image.height) return null
    return Bitmap.createBitmap(image.pixels, image.width, image.height, Bitmap.Config.ARGB_8888).asImageBitmap()
}

/**
 * 絵と枠を描き、取っ手と枠の中の指の動きを受ける所。絵を描く矩形は [fitCropImageFrame] で 1 回だけ作り、描く側と指の側の両方が使う。
 * TalkBack には「切り抜く範囲」と読ませる（範囲を変える操作は辺のボタンでできる）。
 */
@Composable
private fun CropFrameArea(
    image: PreviewImage?,
    crop: NormalizedRect,
    onDrag: (CropMath.Handle, Double, Double) -> Unit,
) {
    val bitmap = remember(image) { image?.let(::toImageBitmap) }
    var area by remember { mutableStateOf(IntSize.Zero) }
    val insetPx = with(LocalDensity.current) { HANDLE_TOUCH_HALF.roundToPx() }
    val frame = remember(area, bitmap, insetPx) {
        bitmap?.let { fitCropImageFrame(area, it.width, it.height, insetPx) }
    }

    // 指の処理は作り直しのたびに始め直さない（範囲は引くたびに変わるので、鍵にすると引いている途中で指の処理が切れる）。
    // 今の範囲・矩形・知らせる先は、作り直しで更新される入れ物から読む
    val currentFrame by rememberUpdatedState(frame)
    val currentCrop by rememberUpdatedState(crop)
    val currentOnDrag by rememberUpdatedState(onDrag)

    val colors = MaterialTheme.colorScheme
    val frameDescription = stringResource(R.string.crop_frame_description)

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(1f)
            .clip(RoundedCornerShape(12.dp))
            .background(colors.surfaceVariant)
            .onSizeChanged { area = it }
            .semantics { contentDescription = frameDescription }
            .pointerInput(Unit) {
                val touchHalf = HANDLE_TOUCH_HALF.toPx()
                awaitEachGesture {
                    val down = awaitFirstDown()
                    // 指を置いた時の矩形と範囲で当たりを決める。絵がまだ無いか、どの取っ手にも当たらなければ何もしない（外側の送りに任せる）
                    val startFrame = currentFrame ?: return@awaitEachGesture
                    val startCrop = currentCrop
                    val handle = handleAt(down.position, startFrame, startCrop, touchHalf) ?: return@awaitEachGesture
                    // つかんだ所：指の割合と取っ手の位置のずれ。以後は「指の割合 − このずれ」を取っ手の求める位置にする
                    val (startAnchorX, startAnchorY) = anchorOf(startCrop, handle)
                    val grabX = startFrame.fractionX(down.position.x) - startAnchorX
                    val grabY = startFrame.fractionY(down.position.y) - startAnchorY
                    // 呼ぶ側が持つ範囲の写し。知らせた差分を、呼ぶ側と同じ CropMath.dragged で進める（呼ぶ側へ範囲を渡すためでなく、
                    // 呼ぶ側の範囲が作り直しで届くのを待たずに、次の差分の基準を正しくするため。上の説明を参照）
                    var shadow = startCrop
                    var dragging = false
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) break
                        if (!dragging && (change.position - down.position).getDistance() > viewConfiguration.touchSlop) {
                            dragging = true
                        }
                        if (dragging && change.positionChanged()) {
                            // 絵が入れ替わって矩形が変わった（回転の後の読み直しなど）ときは、今の矩形で割合にする
                            val nowFrame = currentFrame ?: break
                            val (anchorX, anchorY) = anchorOf(shadow, handle)
                            val dx = nowFrame.fractionX(change.position.x) - grabX - anchorX
                            val dy = nowFrame.fractionY(change.position.y) - grabY - anchorY
                            if (dx != 0.0 || dy != 0.0) {
                                currentOnDrag(handle, dx, dy)
                                shadow = CropMath.dragged(shadow, handle, dx, dy)
                            }
                        }
                        // 当たった指の動きは使い切る（外側の縦の送りに渡さない）
                        change.consume()
                    }
                }
            },
    ) {
        val nowFrame = frame ?: return@Canvas
        val nowBitmap = bitmap ?: return@Canvas
        drawImage(
            image = nowBitmap,
            srcOffset = IntOffset.Zero,
            srcSize = IntSize(nowBitmap.width, nowBitmap.height),
            dstOffset = IntOffset(nowFrame.left, nowFrame.top),
            dstSize = IntSize(nowFrame.width, nowFrame.height),
            filterQuality = FilterQuality.Medium,
        )
        drawCropOverlay(
            frame = nowFrame,
            crop = crop,
            curtain = colors.scrim,
            lineOuter = colors.primary,
            lineInner = colors.onPrimary,
        )
    }
}

/**
 * 枠の見た目（iOS CropOverlayView と同じ並び）：範囲の外の幕 → 3 分割の線 → 枠の線 → 4 隅の取っ手の丸。
 * 枠の線と取っ手は 2 色（太い [lineOuter] の上に細い [lineInner]）にして、明るい空にも暗い空にも埋もれないようにする。
 * 色はどれも MaterialTheme.colorScheme から受け取る（ダークテーマにも追従する：要件 13.7）。
 */
private fun DrawScope.drawCropOverlay(
    frame: CropImageFrame,
    crop: NormalizedRect,
    curtain: Color,
    lineOuter: Color,
    lineInner: Color,
) {
    val imageLeft = frame.left.toFloat()
    val imageTop = frame.top.toFloat()
    val imageRight = (frame.left + frame.width).toFloat()
    val imageBottom = (frame.top + frame.height).toFloat()
    val left = frame.xOf(crop.left)
    val top = frame.yOf(crop.top)
    val right = frame.xOf(crop.right).coerceAtLeast(left)
    val bottom = frame.yOf(crop.bottom).coerceAtLeast(top)

    // 範囲の外の幕（絵の中だけ）。上・下は絵の幅いっぱい、左・右は範囲の高さの分
    drawRect(curtain, topLeft = Offset(imageLeft, imageTop), size = Size(imageRight - imageLeft, top - imageTop), alpha = CURTAIN_ALPHA)
    drawRect(curtain, topLeft = Offset(imageLeft, bottom), size = Size(imageRight - imageLeft, imageBottom - bottom), alpha = CURTAIN_ALPHA)
    drawRect(curtain, topLeft = Offset(imageLeft, top), size = Size(left - imageLeft, bottom - top), alpha = CURTAIN_ALPHA)
    drawRect(curtain, topLeft = Offset(right, top), size = Size(imageRight - right, bottom - top), alpha = CURTAIN_ALPHA)

    // 3 分割の線（縦 2 本・横 2 本）。構図の目安なので薄く
    val width = right - left
    val height = bottom - top
    val gridStroke = 1.dp.toPx()
    for (k in 1..2) {
        val x = left + width * k / 3f
        val y = top + height * k / 3f
        drawLine(lineInner, start = Offset(x, top), end = Offset(x, bottom), strokeWidth = gridStroke, alpha = GRID_ALPHA)
        drawLine(lineInner, start = Offset(left, y), end = Offset(right, y), strokeWidth = gridStroke, alpha = GRID_ALPHA)
    }

    // 枠の線（太い線の上に細い線）
    val cropTopLeft = Offset(left, top)
    val cropSize = Size(width, height)
    drawRect(lineOuter, topLeft = cropTopLeft, size = cropSize, style = Stroke(width = 3.dp.toPx()))
    drawRect(lineInner, topLeft = cropTopLeft, size = cropSize, style = Stroke(width = 1.5.dp.toPx()))

    // 4 隅の取っ手（丸）。押せる大きさは描いた丸でなく、当たりの 48dp の四角（handleAt）
    val radius = HANDLE_RADIUS.toPx()
    listOf(Offset(left, top), Offset(right, top), Offset(left, bottom), Offset(right, bottom)).forEach { center ->
        drawCircle(lineInner, radius = radius, center = center)
        drawCircle(lineOuter, radius = radius, center = center, style = Stroke(width = 1.5.dp.toPx()))
    }
}

/** 横に 2 つ並べる同じ幅の枠のボタン。文字は折り返して伸びる（高さを固定しない：要件 13.6） */
@Composable
private fun ButtonPair(firstText: String, onFirst: () -> Unit, secondText: String, onSecond: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
    ) {
        OutlinedButton(onClick = onFirst, modifier = Modifier.weight(1f)) {
            Text(text = firstText, textAlign = TextAlign.Center)
        }
        OutlinedButton(onClick = onSecond, modifier = Modifier.weight(1f)) {
            Text(text = secondText, textAlign = TextAlign.Center)
        }
    }
}

/** 辺の名前（「左の辺」など）。辺のボタンの文言に入れる */
@Composable
private fun edgeName(edge: CropMath.Edge): String = stringResource(
    when (edge) {
        CropMath.Edge.LEFT -> R.string.crop_edge_left
        CropMath.Edge.TOP -> R.string.crop_edge_top
        CropMath.Edge.RIGHT -> R.string.crop_edge_right
        CropMath.Edge.BOTTOM -> R.string.crop_edge_bottom
    },
)
