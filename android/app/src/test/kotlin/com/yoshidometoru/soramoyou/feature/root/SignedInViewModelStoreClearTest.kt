// ⭐️ ログイン中だけの ViewModelStoreOwner が store を clear したら、画面の ViewModel が session の監視を止めることの検査（レビュー R23）
package com.yoshidometoru.soramoyou.feature.root

import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.feature.RecordingFeatureAnalytics
import com.yoshidometoru.soramoyou.feature.immediateScope
import com.yoshidometoru.soramoyou.feature.profile.FakeAccountDocumentRepairer
import com.yoshidometoru.soramoyou.feature.profile.FakeProfileRepository
import com.yoshidometoru.soramoyou.feature.profile.FakeWriteGate
import com.yoshidometoru.soramoyou.feature.profile.ProfileViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * SoramoyouApp.kt の SignedInNavHost は、NavHost をログイン中だけの ViewModelStoreOwner の下に置き、ログアウトで合成から抜けたときに
 * その store を clear させる（置き方そのものは SignedInNavHostSourceTest で固定する）。ここでは、その先の鎖のうち
 * 「store が clear されたら、ViewModel に渡した scope が閉じて、session の監視が止まる」を、ProfileViewModel で確かめる。
 * 本番では画面ごとの store が親の store の子で、親の clear で子も clear される（その部分は Navigation の中なので、ここでは見ない）。
 *
 * 直す前は store が clear されなかったので、ログアウトしてログインし直すと、残った ProfileViewModel が session の変化で
 * 新しい uid の監視・補完・投稿の取得をもう 1 組始めていた（レビュー R23）。
 *
 * ⚠️ JVM の単体テストで ViewModelProvider・ViewModelStore を使うのは :app でここが初めて。android.jar の空の実装に当たって
 * 落ちるときは、このファイルだけを外せば、ほかの検査は残る（そのために SignedInNavHostSourceTest とは別のファイルにしている）。
 */
class SignedInViewModelStoreClearTest {

    private val repository = FakeProfileRepository()
    private val repairer = FakeAccountDocumentRepairer()
    private val session = MutableStateFlow<SessionState>(signedIn("me"))

    private fun signedIn(uid: String) = SessionState.SignedIn(Uid(uid), "$uid@example.com", isAnonymous = false)

    @Test
    fun `storeをclearした後は、ログアウトして別のユーザーでログインし直しても古いProfileViewModelが監視・補完・取得をもう1組始めない`() {
        val store = ViewModelStore()
        val factory = viewModelFactory {
            initializer {
                ProfileViewModel(
                    repository,
                    repairer,
                    FakeWriteGate(setOf(WriteCapability.ACCOUNT_REPAIR)),
                    RecordingFeatureAnalytics(),
                    MutableStateFlow(true),
                    session,
                    immediateScope(),
                )
            }
        }
        ViewModelProvider.create(store, factory)[ProfileViewModel::class]

        // 作った時点で、自分のユーザー文書の監視・補完・投稿の先頭の取得を 1 組ずつ始めている
        assertEquals(1, repository.ownFlows.size)
        assertEquals(1, repairer.calls)
        assertEquals(1, repository.ownPages.calls.size)
        val firstObservation = repository.ownFlows.single()
        assertEquals(1, firstObservation.subscriptionCount.value)

        // ログアウトで、ログイン中だけの owner がすること
        store.clear()

        assertEquals(0, firstObservation.subscriptionCount.value, "store を clear しても、ユーザー文書の監視が止まっていない")

        session.value = SessionState.SignedOut
        session.value = signedIn("other")

        assertEquals(1, repository.ownFlows.size, "clear した後のログインで、古い ViewModel が監視をもう 1 本張った")
        assertEquals(1, repairer.calls, "clear した後のログインで、古い ViewModel が補完をもう 1 回呼んだ")
        assertEquals(1, repository.ownPages.calls.size, "clear した後のログインで、古い ViewModel が投稿の取得をもう 1 回始めた")
    }
}
