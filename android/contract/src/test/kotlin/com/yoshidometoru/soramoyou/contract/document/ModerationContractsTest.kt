// ⭐️ 通報・ブロックの書き込みの契約（REPORT_CREATE・USER_BLOCKED_IDS）と組み立ての単体テスト（タスク 28・要件 11.2〜11.5）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.model.ReportReason
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 通報は「投稿 ID・通報した人・通報された投稿者・理由・サーバー時刻の作成日時」の 5 項目だけを `reports` に自動 ID で作る
 * （firestore.rules:367-378、FirestoreService.swift:1143-1155）。ブロックは自分の `users/{uid}.blockedUserIds` への
 * 1 要素の追加か削除だけ（FirestoreService.swift:1174-1193。`updatedAt` も書かない）。
 *
 * 陽性対照（先に赤を確かめたもの）：2 要素以上を一度に追加・削除するブロック、`updatedAt` など他のキーを同時に書くブロック、
 * 5 つ以外のキーを含む通報、他人の uid の通報者、5 種に無い理由が違反になること。
 */
class ModerationContractsTest {

    private val uid = Uid("USER-UID-1")
    private val ownerUid = Uid("OWNER-UID-2")
    private val postId = PostId("POST-ID-1")

    /** 通報の書き込み先。自動 ID なので書き込む前は ID が分からない（契約は ID を縛らない）。仮の値を入れる。 */
    private val reportTarget = WriteTarget(documentId = "AUTO-REPORT-ID", authUid = uid)

    /** ブロックの書き込み先は自分の `users/{uid}`。 */
    private val userTarget = WriteTarget(documentId = uid.value, authUid = uid)

    private fun validateReport(doc: FsDocument): List<Violation> =
        AllowListShapeValidator.validate(ShapeContracts.REPORT_CREATE, doc, reportTarget)

    private fun validateBlock(doc: FsDocument): List<Violation> =
        AllowListShapeValidator.validate(ShapeContracts.USER_BLOCKED_IDS, doc, userTarget)

    private val validReport: FsDocument = mapOf(
        "postId" to FsValue.Str(postId.value),
        "reporterId" to FsValue.Str(uid.value),
        "reportedUserId" to FsValue.Str(ownerUid.value),
        "reason" to FsValue.Str("spam"),
        "createdAt" to FsValue.ServerTime,
    )

    @Test
    fun `契約のIDは操作ごとに正しい`() {
        assertEquals(ContractId.REPORT_CREATE, ShapeContracts.REPORT_CREATE.id)
        assertEquals(ContractId.USER_BLOCKED_IDS, ShapeContracts.USER_BLOCKED_IDS.id)
    }

    // ---- 通報（REPORT_CREATE） ----

    @Test
    fun `組み立てた通報は5項目だけで、作成日時はサーバー時刻である`() {
        val doc = DocumentBuilders.reportCreate(postId, uid, ownerUid, ReportReason.SPAM)
        assertEquals(validReport, doc)
        assertEquals(emptyList(), validateReport(doc))
    }

    @Test
    fun `5種の理由はどれも組み立てた通報が契約に合格し、理由はrawで書かれる`() {
        ReportReason.entries.forEach { reason ->
            val doc = DocumentBuilders.reportCreate(postId, uid, ownerUid, reason)
            assertEquals(FsValue.Str(reason.raw), doc["reason"], reason.name)
            assertEquals(emptyList(), validateReport(doc), reason.name)
        }
    }

    @Test
    fun `陽性対照：5項目以外のキーを含む通報は違反になる`() {
        // 通報に本文や連絡先を足したくなったときに、契約へ足すまで止まる側に倒す
        val extras = listOf(
            "updatedAt" to FsValue.Time(Instant.parse("2026-10-13T01:02:03Z")),
            "details" to FsValue.Str("説明"),
            "reporterEmail" to FsValue.Str("a@example.com"),
            "status" to FsValue.Str("open"),
        )
        extras.forEach { (key, value) ->
            assertEquals(
                listOf("UnexpectedKey" to key),
                shapeOf(validateReport(validReport + (key to value))),
                key,
            )
        }
    }

    @Test
    fun `5項目のどれかが欠けると違反になる`() {
        listOf("postId", "reporterId", "reportedUserId", "reason", "createdAt").forEach { key ->
            assertEquals(listOf("MissingKey" to key), shapeOf(validateReport(validReport - key)), key)
        }
    }

    @Test
    fun `他人のuidを通報者にした通報は違反になる`() {
        assertEquals(
            listOf("OutOfRange" to "reporterId"),
            shapeOf(validateReport(validReport + ("reporterId" to FsValue.Str("OTHER-UID")))),
        )
    }

    @Test
    fun `5種に無い理由は違反になる（大文字小文字・前後の空白・空文字を直さない）`() {
        listOf("violence", "Spam", "SPAM", " spam", "spam ", "").forEach { reason ->
            assertEquals(
                listOf("OutOfRange" to "reason"),
                shapeOf(validateReport(validReport + ("reason" to FsValue.Str(reason)))),
                "「$reason」",
            )
        }
    }

    @Test
    fun `理由が文字列でない通報は種類の違反になる`() {
        assertEquals(
            listOf("WrongKind" to "reason"),
            shapeOf(validateReport(validReport + ("reason" to FsValue.Int64(1L)))),
        )
    }

    @Test
    fun `空の投稿IDと空の投稿者IDの通報は違反になる`() {
        // 空文字は「値が無い」ことなので、運営が追えない通報を送らない
        assertEquals(
            listOf("OutOfRange" to "postId"),
            shapeOf(validateReport(validReport + ("postId" to FsValue.Str("")))),
        )
        assertEquals(
            listOf("OutOfRange" to "reportedUserId"),
            shapeOf(validateReport(validReport + ("reportedUserId" to FsValue.Str("")))),
        )
    }

    @Test
    fun `作成日時が端末の時刻だと違反になる（通報はサーバー時刻で書く）`() {
        assertEquals(
            listOf("WrongKind" to "createdAt"),
            shapeOf(validateReport(validReport + ("createdAt" to FsValue.Time(Instant.parse("2026-10-13T01:02:03Z"))))),
        )
    }

    @Test
    fun `通報の組み立ては渡された値をそのまま出し、空の投稿IDは直さずに契約が止める`() {
        val doc = DocumentBuilders.reportCreate(PostId(""), uid, ownerUid, ReportReason.OTHER)
        assertEquals(FsValue.Str(""), doc["postId"])
        assertEquals(listOf("OutOfRange" to "postId"), shapeOf(validateReport(doc)))
    }

    // ---- ブロック（USER_BLOCKED_IDS） ----

    @Test
    fun `ブロックは配列への1要素の追加で組み立てる`() {
        val doc = DocumentBuilders.blockedUserIds(BlockChange.Block(ownerUid))
        assertEquals(mapOf("blockedUserIds" to FsValue.ArrayUnion(listOf(ownerUid.value))), doc)
        assertEquals(emptyList(), validateBlock(doc))
    }

    @Test
    fun `ブロック解除は配列からの1要素の削除で組み立てる`() {
        val doc = DocumentBuilders.blockedUserIds(BlockChange.Unblock(ownerUid))
        assertEquals(mapOf("blockedUserIds" to FsValue.ArrayRemove(listOf(ownerUid.value))), doc)
        assertEquals(emptyList(), validateBlock(doc))
    }

    @Test
    fun `陽性対照：2要素以上を一度に追加するブロックは違反になる`() {
        assertEquals(
            listOf("OutOfRange" to "blockedUserIds"),
            shapeOf(validateBlock(mapOf("blockedUserIds" to FsValue.ArrayUnion(listOf("A", "B"))))),
        )
        assertEquals(
            listOf("OutOfRange" to "blockedUserIds"),
            shapeOf(validateBlock(mapOf("blockedUserIds" to FsValue.ArrayUnion(listOf("A", "B", "C"))))),
        )
    }

    @Test
    fun `陽性対照：2要素以上を一度に削除するブロック解除は違反になる`() {
        assertEquals(
            listOf("OutOfRange" to "blockedUserIds"),
            shapeOf(validateBlock(mapOf("blockedUserIds" to FsValue.ArrayRemove(listOf("A", "B"))))),
        )
    }

    @Test
    fun `要素が0個の追加と削除は違反になる`() {
        assertEquals(
            listOf("OutOfRange" to "blockedUserIds"),
            shapeOf(validateBlock(mapOf("blockedUserIds" to FsValue.ArrayUnion(emptyList())))),
        )
        assertEquals(
            listOf("OutOfRange" to "blockedUserIds"),
            shapeOf(validateBlock(mapOf("blockedUserIds" to FsValue.ArrayRemove(emptyList())))),
        )
    }

    @Test
    fun `陽性対照：ブロックと同時に他のキーを書くと違反になる（iOSは更新日時も書かない）`() {
        val block = DocumentBuilders.blockedUserIds(BlockChange.Block(ownerUid))
        listOf(
            "updatedAt" to FsValue.Time(Instant.parse("2026-10-13T01:02:03Z")),
            "fcmToken" to FsValue.Str("token"),
            "followersCount" to FsValue.Int64(1L),
            "email" to FsValue.Str("a@example.com"),
        ).forEach { (key, value) ->
            assertEquals(listOf("UnexpectedKey" to key), shapeOf(validateBlock(block + (key to value))), key)
        }
    }

    @Test
    fun `ブロックのキーが無い更新は違反になる`() {
        assertEquals(listOf("MissingKey" to "blockedUserIds"), shapeOf(validateBlock(emptyMap())))
    }

    @Test
    fun `ブロック中の一覧を値で上書きする書き方と、消す書き方は種類の違反になる`() {
        // 手元の古い一覧で、別の端末のブロックを消してしまうことを止める
        listOf(
            FsValue.StrList(listOf("A")),
            FsValue.DeleteField,
            FsValue.Str("A"),
            FsValue.Increment(1L),
        ).forEach { value ->
            assertEquals(
                listOf("WrongKind" to "blockedUserIds"),
                shapeOf(validateBlock(mapOf("blockedUserIds" to value))),
                value.toString(),
            )
        }
    }

    @Test
    fun `ブロックの違反の説明には、ブロックする相手のuidを入れない`() {
        val violations = validateBlock(mapOf("blockedUserIds" to FsValue.ArrayUnion(listOf("SECRET-UID-A", "SECRET-UID-B"))))
        val detail = (violations.single() as Violation.OutOfRange).detail
        assertTrue("SECRET" !in detail, detail)
    }
}
