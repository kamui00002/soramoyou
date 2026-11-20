// ⭐️ アカウント文書の作成・補完の単体テストで共有する部品（タスク 14.2・14.3）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.AllowListShapeValidator
import com.yoshidometoru.soramoyou.data.remote.write.DefaultFirestoreWriteGateway
import com.yoshidometoru.soramoyou.data.remote.write.FakeFirestoreWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.data.remote.write.FixedWriteGate
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics

/**
 * 全ての書き込みが有効な状態。製品の WriteGate は M1 で全て無効になるので（単体テストは prodDebug で走る）、
 * 書き込みが有効な状態は [FixedWriteGate]（可否を自由に決められる偽物）で作る。
 * 可否そのものを確かめるテスト以外は、これを使う（可否の取り違えで、無関係なテストまで赤になるのを避ける）。
 */
internal val ALL_WRITES_ENABLED: Set<WriteCapability> = WriteCapability.entries.toSet()

/**
 * 本物の書き込みの入口（可否 → 形の検証 → 実行 → 記録）を、偽物の継ぎ目の上に組む。
 * 形の検証は本物の契約・本物の検証器なので、契約に合わない文書を作ると [com.yoshidometoru.soramoyou.contract.AppError.ShapeViolation] になる。
 * [analytics] は入口と、それを呼ぶ部品とで共有する（入口が記録したものと、呼び出し側が記録したものを 1 か所で見るため）。
 *
 * @param signedInUid 入口が書き手として見る uid。null なら未ログイン（入口が PermissionDenied で断る）。
 */
internal fun realWriteGateway(
    client: FakeFirestoreWriteClient,
    analytics: RecordingAnalytics,
    enabled: Set<WriteCapability> = ALL_WRITES_ENABLED,
    signedInUid: Uid? = Uid("UID-1"),
): FirestoreWriteGateway =
    DefaultFirestoreWriteGateway(FixedWriteGate(enabled), AllowListShapeValidator, client, analytics) { signedInUid }
