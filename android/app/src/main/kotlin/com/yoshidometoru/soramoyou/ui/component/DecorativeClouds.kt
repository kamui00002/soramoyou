// ⭐️ ログインと新規登録の背景に重ねる装飾の雲の置き場と形（窓の大きさから雲の矩形を求めて重なる雲を除き、iOS の CloudShape の形で描く）（android-ui-ios-parity タスク 8.1・8.2・要件 2.3・2.4・3.2・6.1・7.3）
package com.yoshidometoru.soramoyou.ui.component

import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpRect
import com.yoshidometoru.soramoyou.ui.theme.CloudAnchor
import com.yoshidometoru.soramoyou.ui.theme.CloudSpec

/*
 * 「空と雲」の背景（BackdropKind.SKY_WITH_CLOUDS）で、空の上に重ねる装飾の雲。
 * 雲の大きさ・位置・濃さは、色の一式（SkyPalette.clouds）が iOS の SkyBackgroundView の cloudsLayer を写して持つ。
 * このファイルは、その値と窓の大きさから、雲を置く矩形を求め（cloudRects・タスク 8.1）、
 * 残った雲を iOS の CloudShape の形で描く（prepareClouds と drawClouds・タスク 8.2）。
 * 描くのは背景（SkyBackdrop）の描く処理の中で、空のグラデーションと無地の層の間に描く。
 *
 * 置き場の計算は描画から切り離した純関数なので、窓の大きさを総当たりで変える単体テスト（BackdropTest）から直接呼べる。
 * ui の下の固定の大きさの検査（FixedHeightInUiTest）と、色の値を作る書き方の検査（ScreenStyleSourceTest・タスク 10.3）は、
 * このファイルのコメントも文字列として読む。
 */

/**
 * 窓の大きさ（[width]×[height]）から、[clouds] の各雲を置く矩形を求める。前の雲に重なる雲は除く。
 * 返す一覧の並びは [clouds] の並びのままで、除いた雲は一覧に入らない。[clouds] が空なら空の一覧を返す。
 *
 * 位置は iOS の式を、雲を揺らすずらし（cloudOffset）を 0 とした静止の形で写す（要件 2.4）:
 * - iOS の雲は、窓いっぱいの GeometryReader の中の ZStack に並ぶ。ZStack は、いちばん大きい子の大きさになるので、
 *   箱の幅は雲の幅の最大、箱の高さは雲の高さの最大とする（今の 4 つでは 200×80）。
 * - 雲は、その箱の中で真ん中に揃ってから、iOS の offset の分だけずれる。
 *   左 =（箱の幅 − 雲の幅）÷ 2 + 横のずらし、上 =（箱の高さ − 雲の高さ）÷ 2 + 縦のずらし、右 = 左 + 雲の幅、下 = 上 + 雲の高さ。
 * - 横のずらしは、[CloudAnchor.START] なら offsetX、[CloudAnchor.END] なら窓の幅 + offsetX（iOS の「幅 − 80」は、END と −80）。
 *   縦のずらしは、topFraction × 窓の高さ。
 *
 * 重なる雲を除く理由（要件 3.2）:
 * - iOS の位置のままだと、窓の高さが約 281dp（281.25dp）未満のとき（画面の分割など）、雲1（上部の左）と雲3（中央）が重なる。
 *   雲1の下端は 75 + 0.08 × 高さ、雲3の上端は 7.5 + 0.32 × 高さ（どちらも dp）で、高さが 281.25dp 未満だと雲3の上端が雲1の下端より上に来る。
 *   横は、窓の幅に依らず雲1（−30〜150）と雲3（30〜190）が交わるので、縦が食い込めばそのまま重なる。
 * - 雲が重なった所は白が 2 枚分の濃さになり、ダークの雲だけの上でもアクセントの文字が 3.89、エラーの文字が 4.14 になって 4.5 を割る。
 *   SkyContrastTest の雲の層（と雲の上の入力欄の層）は、雲 1 つ分の濃さで確かめているので、雲が重なるとその表の前提が崩れる。
 * - そこで、雲を並びの順に見て、すでに残した雲のどれとも重ならない雲だけを残す（iOS の並びで先の雲を残す）。
 *   比べる相手は残した雲だけで、除いた雲に重なっても除かない。
 *
 * 単位は Dp のまま計算する（窓の大きさを px に直さない。描く部品が、そのときの密度で px に直す）。
 *
 * @param clouds 雲の一式（色の一式の clouds。iOS の並びの 4 つ）
 * @param width 窓の幅
 * @param height 窓の高さ
 * @return 残した雲と、その矩形の組の一覧（[clouds] の並びのまま）
 */
internal fun cloudRects(clouds: List<CloudSpec>, width: Dp, height: Dp): List<Pair<CloudSpec, DpRect>> {
    // 雲が無ければ、箱の大きさ（最大）を取る前に返す（空の一覧の最大は取れない）
    if (clouds.isEmpty()) return emptyList()

    // iOS の ZStack の箱。いちばん大きい雲の大きさになる（幅と高さは別々に最大を取る）
    val boxWidth = clouds.maxOf { it.width }
    val boxHeight = clouds.maxOf { it.height }

    // 残した雲と、その矩形。並びの順に足していくので、返す一覧の並びは入力の並びのままになる
    val kept = mutableListOf<Pair<CloudSpec, DpRect>>()
    for (cloud in clouds) {
        // 横のずらし。START は窓の左端から、END は窓の右端から測る（iOS の offset の横）
        val dx = when (cloud.anchor) {
            CloudAnchor.START -> cloud.offsetX
            CloudAnchor.END -> width + cloud.offsetX
        }
        // 箱の中で真ん中に置いた位置に、iOS の offset を足す（縦のずらしは窓の高さに対する割合）
        val left = (boxWidth - cloud.width) / 2 + dx
        val top = (boxHeight - cloud.height) / 2 + height * cloud.topFraction
        val rect = DpRect(left = left, top = top, right = left + cloud.width, bottom = top + cloud.height)

        // すでに残した雲のどれとも重ならない雲だけを残す（陽性対照で、この 1 行だけを「無条件に残す」へ差し替える）
        if (kept.none { (_, other) -> rect.overlaps(other) }) kept += cloud to rect
    }
    return kept
}

/**
 * この矩形と [other] の内部が交わるか。4 つの比べが全て「より小さい」なので、辺が接するだけのときは重ならないとする。
 * 例えば幅 320dp の窓では、雲3（中央）の右と雲4（下部）の左がちょうど 190dp で接するが、これは重なりに数えない
 * （接するだけなら、白が 2 枚分の濃さになる所は無い）。
 */
private fun DpRect.overlaps(other: DpRect): Boolean =
    left < other.right && other.left < right && top < other.bottom && other.top < bottom

/**
 * 描く準備ができた雲 1 つ。窓の中の位置に置いた雲の形（px の [path]）と、白の不透明度（[alpha]・色の一式の雲の値）。
 */
internal class PreparedCloud(val path: Path, val alpha: Float)

/**
 * 描く準備。描く面の大きさ（[size]・px）から、[cloudRects] で残った雲だけを、窓の中の位置の形にする（要件 2.3・2.4・3.2）。
 * 大きさが変わったときだけ作り直せばよいので、背景の drawWithCache の準備の中で呼ぶ（毎フレームは呼ばない）。
 *
 * 大きさは決め打ちせず、そのときの描く面の大きさを dp に直して [cloudRects] に渡し、返った矩形を px に直して形を作る（要件 7.3）。
 *
 * @param clouds 雲の一式（色の一式の clouds）
 * @param size 描く面の大きさ（px）。背景は窓いっぱいに広がるので、窓の大きさになる
 * @return 残った雲の形と濃さ（[clouds] の並びのまま）
 */
internal fun Density.prepareClouds(clouds: List<CloudSpec>, size: Size): List<PreparedCloud> =
    cloudRects(clouds, size.width.toDp(), size.height.toDp()).map { (cloud, rect) ->
        PreparedCloud(path = cloudPath(rect.toRect()), alpha = cloud.alpha)
    }

/**
 * 準備した雲（[prepareClouds]）を描く。白を、雲ごとの不透明度に雲の層の濃さ（[layerAlpha]）を掛けた不透明度で塗る。
 *
 * 色の値は作らない（白の定数を、描くときの alpha の引数とともに渡すだけ）。雲の濃さの値は色の一式が持ち、
 * SkyContrastTest は雲 1 つ分の濃さ（白に色の一式の雲の値）の上で文字の比を確かめている。
 * 雲は互いに重ならない（[cloudRects] が除く）ので、どの点も雲 1 つ分の濃さを超えない。
 *
 * @param clouds 描く準備ができた雲
 * @param layerAlpha 雲の層の濃さ（0〜1）。背景の種類が「空と雲」のときに 1 になり、切り替えの 0.7 秒の間に変わる
 */
internal fun DrawScope.drawClouds(clouds: List<PreparedCloud>, layerAlpha: Float) {
    clouds.forEach { cloud ->
        drawPath(path = cloud.path, color = Color.White, alpha = cloud.alpha * layerAlpha)
    }
}

/**
 * 雲 1 つの形。iOS の `CloudShape`（SkyBackgroundView.swift）の 2 次ベジェを、同じ比のまま [rect] の中に写す。
 * 点と制御点は、どれも [rect] の幅と高さに対する割合（iOS と同じ数）で置く。左・上・右の丸みを 2 次ベジェ 2 本ずつで描き、
 * 底を直線で閉じる。点と制御点は、横が幅の 5〜95%、縦が高さの 10〜70% の間にあり、2 次ベジェはその内側を通るので、
 * 形は [rect] の中に収まる（雲どうしが重ならないことを、矩形で確かめてよい理由）。
 *
 * @param rect 雲を置く矩形（px）
 * @return 雲の形
 */
private fun cloudPath(rect: Rect): Path {
    // iOS の CloudShape の「幅 × 割合」「高さ × 割合」を、矩形の左上からの位置に直す
    fun x(fraction: Float): Float = rect.left + rect.width * fraction
    fun y(fraction: Float): Float = rect.top + rect.height * fraction

    return Path().apply {
        moveTo(x(0.2f), y(0.7f))
        // 左側の丸み（quadraticTo の引数は、制御点の x・y、着く点の x・y の順）
        quadraticTo(x(0.05f), y(0.7f), x(0.1f), y(0.5f))
        quadraticTo(x(0.05f), y(0.3f), x(0.25f), y(0.3f))
        // 上部の丸み
        quadraticTo(x(0.35f), y(0.1f), x(0.5f), y(0.15f))
        quadraticTo(x(0.65f), y(0.1f), x(0.75f), y(0.3f))
        // 右側の丸み
        quadraticTo(x(0.95f), y(0.3f), x(0.9f), y(0.5f))
        quadraticTo(x(0.95f), y(0.7f), x(0.8f), y(0.7f))
        // 底部
        lineTo(x(0.2f), y(0.7f))
        close()
    }
}
