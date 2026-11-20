// ⭐️ 編集を掛けた写真のプレビュー（Kiro android-edit-tools タスク 13・A3・design.md:906・997・要件 5.2・5.6・13.*）
package com.yoshidometoru.soramoyou.feature.compose

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.PagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.data.image.PreviewImage
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens
import kotlin.math.roundToInt

/*
 * 編集の段と投稿情報の段で、編集を掛けた写真を見せる部品（design.md:997）。PostComposerScreen が 2 つの段で呼ぶ
 * （画面をこの部品に替えたのは I2：タスク 19）。
 *
 * 決まり：
 * - 色を計算しない。受け取った絵（ViewModel が EditPreviewRenderer.render で色を掛けたもの）を、そのまま画像にして描く
 * - 写真ごとの編集の切り抜きの範囲だけを見せる（絵は回転まで済んだ全体の絵：design.md:906）。トリミング・回転の画面の間は
 *   全体を描く（[EditedPhotoPreview] の showWholeImage。枠は CropPanel が重ねる）
 * - 色は MaterialTheme.colorScheme だけを使う。高さを固定しない（プレビューの枠は幅に合わせた正方形）
 * - ViewModel を参照しない（状態と送りの位置は引数で受ける）
 */

/**
 * 編集を掛けた写真のプレビュー。左右に送って 1 枚ずつ見る。写真が 2 枚以上なら「1 / 3」のように今の位置を出す（今の文言の鍵）。
 * TalkBack には、絵が描けているかどうかに関わらず、どの写真も「%d枚目の写真」（今の文言の鍵）と読ませる（要件 13.*）。
 *
 * @param photos 編集の段の写真（並びと、写真ごとの編集の切り抜きの範囲を使う）
 * @param previews 写真の位置（0 始まり）→ 色を掛けた後の絵（回転まで済んだ全体の絵）。まだ描けていない写真は入っていない
 *   （そのページは背景の色だけを描く。描けない写真は [failedPreviews]）
 * @param pagerState 送りの位置。呼ぶ側が写真の数で作る
 * @param modifier 配置の調整（高さを固定しない）
 * @param showWholeImage true の間（トリミング・回転の画面の間）は、切り抜きを掛けずに全体を描く
 * @param failedPreviews 土台を読めなかった写真の位置（0 始まり）。そのページには「この写真を表示できませんでした」を出す
 *   （今の文言の鍵 compose_preview_failed）。絵が無いだけのページ（まだ描いていない・表示中の両隣より外）には出さない。
 *   絵は届いたのに画像にできない（寸法が 0・画素が足りない）ページにも同じ文言を出す
 */
@Composable
fun EditedPhotoPreview(
    photos: List<EditingPhoto>,
    previews: Map<Int, PreviewImage>,
    pagerState: PagerState,
    modifier: Modifier = Modifier,
    showWholeImage: Boolean = false,
    failedPreviews: Set<Int> = emptySet(),
) {
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        HorizontalPager(
            state = pagerState,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .clip(RoundedCornerShape(12.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant),
        ) { page ->
            // 利用者が選んだ写真そのものなので、飾りでなく中身として読ませる（絵がまだ無いページも同じに読む）
            val description = stringResource(R.string.compose_photo_description, page + 1)
            val crop = if (showWholeImage) NormalizedRect.FULL else photos.getOrNull(page)?.edit?.geometry?.crop ?: NormalizedRect.FULL
            val image = previews[page]
            val bitmap = remember(image) { image?.let(::previewImageBitmapOf) }
            val painter = remember(bitmap, crop) { bitmap?.let { croppedPainterOf(it, crop) } }
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .semantics {
                        contentDescription = description
                        role = Role.Image
                    },
                contentAlignment = Alignment.Center,
            ) {
                if (painter != null) {
                    // 読み上げは外側の箱が持つので、ここでは読ませない（二重に読まない）
                    Image(
                        painter = painter,
                        contentDescription = null,
                        contentScale = ContentScale.Fit,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else if (page in failedPreviews || image != null) {
                    // 描けない写真（土台を読めなかった・届いた絵を画像にできない）。背景の色だけでは理由が分からないので文言を出す。
                    // 絵がまだ無いだけのページには出さない（読み込みのたびに文言が一瞬出るのを避ける）。行数は絞らない（文字 200% で折り返す）
                    Text(
                        text = stringResource(R.string.compose_preview_failed),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(DesignTokens.Spacing.md),
                    )
                }
            }
        }
        if (photos.size > 1) {
            Text(
                text = stringResource(R.string.compose_page_indicator, pagerState.currentPage + 1, photos.size),
                style = MaterialTheme.typography.labelLarge,
                modifier = Modifier.padding(top = DesignTokens.Spacing.sm),
            )
        }
    }
}

/**
 * 受け取った絵の画素（不透明の ARGB・行優先）を、描ける画像にする。色は変えない。
 * 寸法が 0 か、画素の数が幅×高さに足りなければ null（描かない）。新しい形の FilterOptions の見本も、これで画像にする。
 */
internal fun previewImageBitmapOf(image: PreviewImage): ImageBitmap? {
    if (image.width <= 0 || image.height <= 0 || image.pixels.size < image.width * image.height) return null
    return Bitmap.createBitmap(image.pixels, image.width, image.height, Bitmap.Config.ARGB_8888).asImageBitmap()
}

/** [bitmap] のうち、[crop]（回転後の全体の絵に対する割合）の範囲だけを描く絵の具。範囲の決め方は [previewSourceRect]。 */
private fun croppedPainterOf(bitmap: ImageBitmap, crop: NormalizedRect): BitmapPainter {
    val (offset, size) = previewSourceRect(bitmap.width, bitmap.height, crop)
    return BitmapPainter(bitmap, offset, size, FilterQuality.Medium)
}

/**
 * 幅 [width]・高さ [height]（どちらも 1 以上）の絵の中の、[crop] の範囲の画素の左上と寸法。
 * 各辺は四捨五入し、必ず絵の内側・各辺 1 画素以上に収める（BitmapPainter は絵の外を指す範囲を受け付けないため）。
 * 範囲に数でない値（NaN）が入っていれば全体にする（壊れた値で画面を落とさない）。
 */
private fun previewSourceRect(width: Int, height: Int, crop: NormalizedRect): Pair<IntOffset, IntSize> {
    val safe = if (crop.left.isNaN() || crop.top.isNaN() || crop.right.isNaN() || crop.bottom.isNaN()) NormalizedRect.FULL else crop
    val left = (safe.left * width).roundToInt().coerceIn(0, width - 1)
    val top = (safe.top * height).roundToInt().coerceIn(0, height - 1)
    val right = (safe.right * width).roundToInt().coerceIn(left + 1, width)
    val bottom = (safe.bottom * height).roundToInt().coerceIn(top + 1, height)
    return IntOffset(left, top) to IntSize(right - left, bottom - top)
}
