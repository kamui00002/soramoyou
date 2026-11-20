// ⭐️ 外のブラウザでページを開く守りと、開けなかったときのアドレスの表示（設定と新規登録の法的情報のリンク。全体レビュー 4 回目 Q06）
package com.yoshidometoru.soramoyou.feature.settings

import android.content.ActivityNotFoundException
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import com.yoshidometoru.soramoyou.R

/**
 * [url] を外のブラウザで開く。開けたら true、開けるアプリが無くて開けなかったら false を返し、例外を外へ投げない。
 *
 * 開けるアプリが無いと、Compose の窓口は IllegalArgumentException（中身は ActivityNotFoundException）を投げる
 * （ui-android 1.12.1 のバイトコードで確かめた）。そのまま押した操作の中で投げるとアプリが落ちるので、ここで受け止める。
 * 受け止める例外は AccountDeletionScreen の受付ページと同じ 2 つ。退会の画面と違って失敗の記録は残さない。
 */
fun UriHandler.tryOpenUri(url: String): Boolean =
    try {
        openUri(url)
        true
    } catch (e: IllegalArgumentException) {
        false
    } catch (e: ActivityNotFoundException) {
        false
    }

/**
 * 開けなかったページの [url] を、書き写せるように選べる文字で出す。出たときに TalkBack が読み上げる。
 * AccountDeletionScreen の受付ページと同じ出し方・同じ文言（文言が同じことは ExternalPageOpenerTest が突き合わせる）。
 */
@Composable
fun UnopenedPageAddress(url: String) {
    SelectionContainer {
        Text(
            text = stringResource(R.string.external_page_open_failed, url),
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
}
