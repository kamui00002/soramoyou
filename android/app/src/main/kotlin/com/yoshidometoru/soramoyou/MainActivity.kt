// ⭐️ アプリの唯一の Activity：Compose の画面の根を載せる（タスク 8.3）。システムバーを透明にし、アイコンの明暗を端末の設定から選ぶ（android-ui-ios-parity タスク 6.2）
package com.yoshidometoru.soramoyou

import android.content.res.Configuration
import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.yoshidometoru.soramoyou.feature.root.SoramoyouApp
import com.yoshidometoru.soramoyou.platform.UmpConsentGateway
import com.yoshidometoru.soramoyou.ui.theme.SoramoyouTheme

/**
 * 単一 Activity（設計書「採用するパターン」）。依存は [SoramoyouApplication.container] から受け取る。
 * 画面の切り替えは Compose の中（SoramoyouApp）で行い、Activity は増やさない。
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // システムバー（上のステータスバーと下のナビゲーションバー）を透明にし、画面を窓いっぱい（バーの後ろまで）に描く
        // （android-ui-ios-parity タスク 6.2・要件 1.6）。空の背景がバーの後ろまで続き、境に帯が出ないようにするため、
        // 両方のバーに、端末のダークの設定から選んだ透明の指定（[systemBarStyleFor]）を渡す。バーのアイコンの明暗も、この指定で決まる（要件 8.1・8.2）。
        // 引数なしの呼び出しにすると、両方のバーが自動の指定（auto）になる。自動の指定は、API 29 以上の 3 ボタンの端末で
        // ナビゲーションバーの膜（アイコンを読みやすくするための半透明の帯）を強制するので、空の上に帯が出てしまう（設計書 R1）。
        // ダークの設定を切り替えると、マニフェストに configChanges が無いので Activity が作り直され、onCreate からやり直す。
        // そのため指定もそのたびに選び直され、背景とバーが新しい設定に揃う（要件 1.3）。
        // 将来 configChanges に uiMode を足すと、この選び直しが起きなくなるので、そのときは設計書「起動とダークの切り替え」を見直す
        val isDark = isNightMode(resources.configuration.uiMode)
        enableEdgeToEdge(
            statusBarStyle = systemBarStyleFor(isDark),
            navigationBarStyle = systemBarStyleFor(isDark),
        )
        val container = (application as SoramoyouApplication).container
        // 同意の取得と広告 SDK の初期化を始める（タスク 32.1）。UMP は同意のフォームを Activity の上に出すので、ここから呼ぶ。
        // 回転などで作り直されて 2 回目以降に呼ばれても、AdsController は取得中・初期化中・準備完了などなら何もしない。
        // 前回が「広告を要求してよいと答えなかった」で終わったときだけ、ここで渡すこの Activity の窓口で、同意の情報の更新からやり直す（レビュー R22）
        container.adsController.start(UmpConsentGateway(this))
        setContent {
            SoramoyouTheme {
                SoramoyouApp(container)
            }
        }
    }
}

/**
 * 端末のダークの設定が「夜」か（android-ui-ios-parity タスク 6.2・要件 1.3・8.1・8.2）。[uiMode] は `Configuration.uiMode` の値で、
 * 端末の種類の印（ふつうの端末・車・テレビなど）と夜の印を、1 つの数のビットにまとめて持つ。
 *
 * 夜の印（[Configuration.UI_MODE_NIGHT_MASK] で取り出したビット）だけを見て、[Configuration.UI_MODE_NIGHT_YES] のときに夜とする。
 * 種類の印がどう立っていても、夜の印だけで決まる。夜の印が「未定（UNDEFINED）」のときはライトとして扱う。
 * この読み方は Compose の isSystemInDarkTheme と同じ（`uiMode` と夜の印のマスクの論理積が夜の値と等しいか）なので、
 * システムバーの明暗と、SoramoyouTheme が選ぶ配色の明暗が食い違わない。
 *
 * Activity から切り離した純関数にしたのは、JVM の単体テスト（SystemBarsSetupTest）で確かめるため。
 * `Configuration` の定数はコンパイル時に数へ置き換わるので、Android の本体が無い JVM でも動く。
 */
internal fun isNightMode(uiMode: Int): Boolean =
    (uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES

/**
 * システムバーの指定を、明暗から選ぶ（android-ui-ios-parity タスク 6.2・要件 1.6・8.1・8.2）。
 *
 * - ダーク（[isDark] が true）：ダーク用の指定に透明を渡す。背景が暗いので、バーのアイコンは明るい色になる
 * - ライト：ライト用の指定に、膜の色を 2 つとも透明で渡す。背景が明るいので、バーのアイコンは暗い色になる
 *   （ライト用の 2 つ目の色は、API 26 未満の端末でアイコンを暗くできないときの膜の色。minSdk は 26 なので使われないが、透明にそろえる）
 *
 * ライト用・ダーク用の指定は、API 29 以上でナビゲーションバーの膜を強制しない（自動の指定（auto）だけが強制する・設計書 R1）。
 * 膜の色も渡した透明になるので、空がバーの後ろまで切れ目なく見える。どちらの指定も膜の色に透明だけを渡し、ほかの色は使わない。
 *
 * 式本体（等号の後に if を書く形）でなく、波括弧の本体で書く。SystemBarsSetupTest が、この関数の本体を波括弧の対応で切り出し、
 * isDark のときの分かれ道でダーク用を選んでいること（向きの取り違えが無いこと）を、ソースの文字列で確かめるため。
 */
internal fun systemBarStyleFor(isDark: Boolean): SystemBarStyle {
    return if (isDark) {
        SystemBarStyle.dark(Color.TRANSPARENT)
    } else {
        SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
    }
}
