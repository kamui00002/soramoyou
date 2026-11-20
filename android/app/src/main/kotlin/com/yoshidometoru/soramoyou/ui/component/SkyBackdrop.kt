// ⭐️ 窓全体に敷く背景（空のグラデーション・雲・無地の層）（android-ui-ios-parity タスク 7.1・8.2・要件 1.1・1.2・1.7・1.9・2.3・2.4・6.1・7.3）
package com.yoshidometoru.soramoyou.ui.component

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Brush
import com.yoshidometoru.soramoyou.ui.theme.LocalSkyPalette

/*
 * アプリのいちばん外側（SoramoyouApp の透明な Scaffold の後ろ）に、窓いっぱい・システムバーの後ろまで 1 枚だけ敷く背景。
 * 画面ごとに背景を持たせず外側に 1 枚だけ置くので、縦に送っても背景は動かず途切れない（要件 1.7）。
 * どの種類を出すかは、feature/root の判定（タスク 7.2 の backdropOf）が根の画面と今の行き先から決めて渡す。
 *
 * 層の重ね方（下から）:
 * 1. 空のグラデーション。種類に依らず、いつもいちばん下に不透明に描く
 * 2. 雲の層。「空と雲」のときだけ、装飾の雲（DecorativeClouds.kt）を空の上に描く（タスク 8.2）
 * 3. 無地の層。Material 3 の背景の色（colorScheme.background）で窓全体を塗る
 *
 * 空がいつも下に不透明にあるので、雲と無地の層の濃さを 0 と 1 の間で変えている途中でも、その下に見えるのは空だけで、
 * ウィンドウの色（themes.xml の単色）やその先の黒が透けて見えることは無い。
 *
 * 背景は、端末の時刻・時間帯・投稿の内容では変えない（どれも読まない）。変わるのは、渡された種類と、
 * 端末のライトとダークの設定（色の一式と Material 3 の配色の両方が、SoramoyouTheme から配られる）だけである。
 */

/**
 * 背景の種類。どの種類でも空のグラデーションは描き、その上に重ねる層だけが変わる。
 *
 * - [SKY]：空のグラデーションだけ。読み込み中と、ログイン後のほとんどの画面。
 * - [SKY_WITH_CLOUDS]：空と雲。ログインと新規登録。空の上に、色の一式の雲のうち互いに重ならずに残った雲を、動かさずに描く（要件 2.3・2.4）。
 * - [PLAIN]：無地。投稿の作成。空の上を Material 3 の背景の色で窓全体ごと塗りつぶす（要件 1.9）。
 */
enum class BackdropKind { SKY, SKY_WITH_CLOUDS, PLAIN }

/**
 * 背景の層の濃さを変える時間（ミリ秒）。NavHost の既定の切り替え（700 ミリ秒のフェード。設計書の R7）と同じ長さにして、
 * 行き先が切り替わるのと同じ速さで背景も替わるようにする。
 * 0.7 秒の間、前の画面と次の画面が重なって見えるので、背景だけが先にぱっと替わると、前の画面が違う背景の上に一瞬だけ載って見える。
 */
const val BACKDROP_FADE_MILLIS: Int = 700

/**
 * 窓全体に、[kind] の背景を描く。呼び出し側は、窓いっぱいに広がる場所（いちばん外側の Box の中など）に置く。
 *
 * 作りの決まり:
 * - 意味の節を作らない（要件 6.1）。描く部品は中身の無い Spacer で、semantics を付けず、文字や画像も置かない。
 *   描くのは drawWithCache の中だけなので、TalkBack のフォーカスがこの背景に止まらない（飾りを読ませない）。
 * - 大きさを決め打ちしない（要件 7.3）。窓いっぱいに広げる修飾子（fillMaxSize）だけを付け、
 *   グラデーションの長さなどは描く処理の中で、そのときの描く面の大きさ（size）から求める。
 *   ui の下の固定の大きさの検査（FixedHeightInUiTest）は、このファイルのコメントも文字列として読む。
 * - 色は全て、色の一式（[LocalSkyPalette]）と Material 3 の配色（[MaterialTheme.colorScheme]）から読み、このファイルでは色の値を作らない。
 *   雲と無地の層の濃さは、色の値を作り替えずに、描く関数の alpha の引数として描くときに渡す（段階 3 のソースの検査が見る）。
 *
 * 濃さの値（アニメーションの今の値）は、描く処理（onDrawBehind）の中でだけ読む。0.7 秒の間、毎フレーム値が変わっても、
 * 読んでいるのが描く処理だけなので、組み立て直し（再構成）も描く準備の作り直しも起きず、描き直しだけで済む。
 *
 * @param kind 背景の種類（タスク 7.2 の判定が決める）
 * @param modifier 置き場所の修飾子。中で窓いっぱいに広げる修飾子を足す
 */
@Composable
fun SkyBackdrop(kind: BackdropKind, modifier: Modifier = Modifier) {
    // 空のグラデーションの 3 色（上→中→下）。ライトは昼の空、ダークは夜の空で、3 色とも不透明（DesignTokens.Colors の空の色）
    val skyColors = LocalSkyPalette.current.skyGradient
    // 装飾の雲の一式（大きさ・位置・濃さ）。ライトとダークで大きさと位置は同じで、濃さだけが違う
    val clouds = LocalSkyPalette.current.clouds
    // 無地の層の色。Material 3 の既定の不透明な背景の色のまま（面の役は付け替えない。設計書の「色の線引き」）
    val plainColor = MaterialTheme.colorScheme.background

    // 無地の層の濃さ。無地のときは 1（空を完全に隠す）、それ以外は 0（空がそのまま見える）で、その間を 0.7 秒かけて変える。
    // 動きの曲線は NavHost の既定のフェードと同じ tween の既定（FastOutSlowInEasing）にして、画面の切り替えと揃える。
    // State のまま持ち、値はここでは読まない（下の onDrawBehind の中で読む。読む場所が描く処理だけになるようにするため）。
    val plainAlpha = animateFloatAsState(
        targetValue = if (kind == BackdropKind.PLAIN) 1f else 0f,
        animationSpec = tween(durationMillis = BACKDROP_FADE_MILLIS),
        label = "plainBackdropAlpha",
    )

    // 雲の層の濃さ。空と雲のときは 1（色の一式の雲の濃さのまま）、それ以外は 0 で、無地の層と同じく 0.7 秒かけて変える。
    // ログインから先へ進むときは、前の画面と一緒に雲も薄れていく。値は無地の層と同じく、描く処理の中でだけ読む。
    val cloudsAlpha = animateFloatAsState(
        targetValue = if (kind == BackdropKind.SKY_WITH_CLOUDS) 1f else 0f,
        animationSpec = tween(durationMillis = BACKDROP_FADE_MILLIS),
        label = "cloudsBackdropAlpha",
    )

    Spacer(
        modifier = modifier
            .fillMaxSize()
            .drawWithCache {
                // 描く準備（大きさが変わったときだけ作り直す）。グラデーションの上端は描く面の上端、下端は描く面の下端で、
                // 3 色は上・真ん中・下に均等に置かれる（iOS の LinearGradient の上から下と同じ並び方）
                val skyBrush = Brush.verticalGradient(colors = skyColors, startY = 0f, endY = size.height)
                // 雲の形も、そのときの描く面の大きさ（窓の大きさ）から作る。互いに重なる雲は、ここで除かれる
                val preparedClouds = prepareClouds(clouds, size)
                onDrawBehind {
                    // 1. 空のグラデーション。種類に依らず、いつもいちばん下に、描く面の全体へ不透明に描く
                    drawRect(brush = skyBrush)
                    // 2. 雲の層。濃さが 0 のときは描かない（空と雲のとき以外は、切り替えの 0.7 秒が過ぎれば描かない）
                    val cloudLayer = cloudsAlpha.value
                    if (cloudLayer > 0f) {
                        drawClouds(preparedClouds, layerAlpha = cloudLayer)
                    }
                    // 3. 無地の層。濃さが 0 のときは描かない（見えない層を重ねる手間を省く）
                    val alpha = plainAlpha.value
                    if (alpha > 0f) {
                        drawRect(color = plainColor, alpha = alpha)
                    }
                }
            },
    )
}
