// ⭐️ マイルストーンごとの書き込みの可否を、ビルド時の設定だけで決めるゲート（タスク 6.1・要件 2.2）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.BuildConfig
import com.yoshidometoru.soramoyou.contract.WriteCapability
import java.util.Collections
import java.util.EnumSet

/**
 * ビルドのマイルストーン（設計書「マイルストーンと有効化の範囲」）。宣言の順は M1 → M6 の進む順で、比較（`>=`）に使う。
 * gradle.properties の `soramoyou.milestone` を、:app のビルドが `BuildConfig.WRITE_MILESTONE` に焼き込む。
 * 名前は gradle.properties に書く値と同じ（app/build.gradle.kts が M1〜M6 以外の値ではビルドを止める）。
 */
enum class Milestone { M1, M2, M3, M4, M5, M6 }

/**
 * マイルストーン [milestone] で有効な書き込みの集合（設計書「マイルストーンと有効化の範囲」の表）。返す集合は変更できない。
 *
 * - M1 は空集合（ログインとフィードの読み取りだけ。本番への書き込みゼロ）
 * - 前のマイルストーンの集合に足していくだけで、外すことはない。M6（公開）は M5 と同じ
 * - 自分の投稿の削除（[WriteCapability.POST_DELETE]）は、未決事項 Q8 を「MVP に含める」と決めた設計書 :51 に従い M4 に入れる
 */
fun writeCapabilitiesOf(milestone: Milestone): Set<WriteCapability> {
    val enabled = EnumSet.noneOf(WriteCapability::class.java)
    // M2：新規登録・匿名でのアカウント作成、欠けた公開プロフィールの補完、プロフィール編集
    if (milestone >= Milestone.M2) {
        enabled += listOf(WriteCapability.ACCOUNT_CREATE, WriteCapability.ACCOUNT_REPAIR, WriteCapability.PROFILE_EDIT)
    }
    // M3：いいね
    if (milestone >= Milestone.M3) {
        enabled += WriteCapability.LIKE
    }
    // M4：投稿と投稿数の数え直し、自分の投稿の削除
    if (milestone >= Milestone.M4) {
        enabled += listOf(WriteCapability.POST_CREATE, WriteCapability.POSTS_COUNT_SYNC, WriteCapability.POST_DELETE)
    }
    // M5：通報・ブロック・フィードバック・退会
    if (milestone >= Milestone.M5) {
        enabled += listOf(
            WriteCapability.REPORT,
            WriteCapability.BLOCK,
            WriteCapability.FEEDBACK,
            WriteCapability.ACCOUNT_DELETE,
        )
    }
    // EnumSet のままだと、受け取った側が add で可否を書き換えられる。変更できない包みで返す
    return Collections.unmodifiableSet(enabled)
}

/**
 * 書き込みの可否を答えるゲート（設計書の部品 WriteGate）。可否を書き換える操作は持たない。
 *
 * - 書き込みの入口（FirestoreWriteGateway・StorageGateway。タスク 6.2・6.3）は、全ての呼び出しの先頭でこれに照会する
 * - 書き込みを伴う画面の導線（新規登録・匿名・プロフィール編集・いいね・投稿・設定内の操作）も、同じ [isEnabled] で表示を切り替える
 *
 * アプリが使う実装は [BuildConfigWriteGate] だけで、AppContainer の `writeGate` から受け取る。
 */
interface WriteGate {

    /** 有効な書き込みの集合。変更できない集合を返す。 */
    val enabled: Set<WriteCapability>

    /** [capability] の書き込みが有効か。[enabled] に含まれるかどうかと同じ。 */
    fun isEnabled(capability: WriteCapability): Boolean = capability in enabled
}

/**
 * アプリが使う [WriteGate]。可否は `BuildConfig.WRITE_MILESTONE`（ビルド時に焼き込んだ定数）だけで決まり、実行時には変わらない。
 *
 * マイルストーンを受け取る口（コンストラクタ・setter）を持たない `object` にしてあるので、デバッグメニューなどから
 * 別のマイルストーンの可否を作る経路が無い（タスク 6.1「実行時に可否を変える経路を作らない」）。
 */
object BuildConfigWriteGate : WriteGate {

    /**
     * このビルドのマイルストーン。`BuildConfig.WRITE_MILESTONE` が [Milestone] の名前でなければ、最初に使ったときに例外で止まる
     * （黙って可否を決めない。ふつうは app/build.gradle.kts の検査で、ビルドの時点で止まる）。
     */
    val milestone: Milestone = Milestone.valueOf(BuildConfig.WRITE_MILESTONE)

    override val enabled: Set<WriteCapability> = writeCapabilitiesOf(milestone)
}
