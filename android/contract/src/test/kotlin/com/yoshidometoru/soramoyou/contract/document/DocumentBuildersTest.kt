// ⭐️ アカウント文書の組み立て（DocumentBuilders.userCreate・publicProfileCreate）の単体テスト（タスク 13.2・要件 2.10・3.1〜3.5）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.Uid
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * ビルダーの出力を、(1) 期待する文書そのものとの一致、(2) 本物の契約（[ShapeContracts]）への合格、の 2 つで確かめる。
 *
 * 陽性対照（先に赤を確かめたもの）：仮置きのビルダー（空のマップを返す）では、(1) の一致が落ちる。
 * 一方、(2) の「出力が契約に合格する」・「`fcmToken` が出ない」・「機密の項目が出ない」は、空のマップと空の契約では
 * 空振りで緑になる。これらの検出力は、ビルダーや契約を壊す改変（必須キーの欠落・`fcmToken` の追加・
 * メールアドレス無しでのキー出力）で確かめる（引き継ぎ文書に記録）。
 */
class DocumentBuildersTest {

    private val uid = Uid("USER-UID-1")
    private val now = Instant.parse("2026-10-05T01:02:03.456Z")
    private val userTarget = WriteTarget(documentId = uid.value, authUid = uid)
    private val profileTarget = WriteTarget(documentId = uid.value, authUid = uid)

    /** アイコン（`photoURL`）として契約を通る、本番の Storage のダウンロード URL の形の値（名前の `/` は `%2F` に符号化する）。 */
    private val iconUrl =
        "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/users%2FUSER-UID-1%2Fprofile%2Ficon.jpg?alt=media&token=abc-123"

    private fun validateUser(doc: FsDocument) = AllowListShapeValidator.validate(ShapeContracts.USER_CREATE, doc, userTarget)
    private fun validateProfile(doc: FsDocument) = AllowListShapeValidator.validate(ShapeContracts.PUBLIC_PROFILE_CREATE, doc, profileTarget)

    // ============================================================
    // userCreate
    // ============================================================

    @Test
    fun `userCreateはメールアドレスがあればiOSと同じ形の文書を作る`() {
        val doc = DocumentBuilders.userCreate(uid, "taro@example.com", now)
        // 要件 3.1〜3.3。キーも値の種類も、これで全部（User.swift:108-144）
        val expected: FsDocument = mapOf(
            "id" to FsValue.Str("USER-UID-1"),
            "createdAt" to FsValue.Time(now),
            "updatedAt" to FsValue.Time(now),
            "email" to FsValue.Str("taro@example.com"),
            "followersCount" to FsValue.Int64(0L),
            "followingCount" to FsValue.Int64(0L),
            "postsCount" to FsValue.Int64(0L),
            "notifyReactions" to FsValue.Bool(true),
            "notifyNewPostsFromFollowing" to FsValue.Bool(true),
            "notifyNewPostsFromEveryone" to FsValue.Bool(false),
        )
        assertEquals(expected, doc)
    }

    @Test
    fun `userCreateはメールアドレスが無いときemailのキー自体を出力しない`() {
        // 要件 3.3・3.5。匿名（採用する場合）の匿名アカウントなど、メールアドレスが無い入力
        val doc = DocumentBuilders.userCreate(uid, null, now)
        assertFalse("email" in doc.keys, "email のキーが出ている: ${doc.keys}")
        assertNull(doc["email"])
        // email 以外は、メールアドレスがあるときと同じ 9 キー
        assertEquals(
            setOf(
                "id", "createdAt", "updatedAt", "followersCount", "followingCount", "postsCount",
                "notifyReactions", "notifyNewPostsFromFollowing", "notifyNewPostsFromEveryone",
            ),
            doc.keys,
        )
    }

    @Test
    fun `userCreateのidはuidと同値で作成日時と更新日時は同じ端末時刻`() {
        val doc = DocumentBuilders.userCreate(uid, null, now)
        assertEquals(FsValue.Str(uid.value), doc["id"])
        assertEquals(FsValue.Time(now), doc["createdAt"])
        assertEquals(doc["createdAt"], doc["updatedAt"], "新規作成なので createdAt と updatedAt は同値（User.swift:109-110）")
        assertTrue(doc["createdAt"] is FsValue.Time, "QC：users は端末の時刻（サーバー時刻ではない）")

        val other = DocumentBuilders.userCreate(Uid("OTHER-UID-2"), null, now)
        assertEquals(FsValue.Str("OTHER-UID-2"), other["id"], "uid ごとに id が変わる")
    }

    @Test
    fun `userCreateのカウンタは整数の0で通知設定は既定値`() {
        val doc = DocumentBuilders.userCreate(uid, null, now)
        listOf("followersCount", "followingCount", "postsCount").forEach { key ->
            assertEquals(FsValue.Int64(0L), doc[key], "$key は Int64 の 0（小数・文字列・加算ではない）")
        }
        assertEquals(FsValue.Bool(true), doc["notifyReactions"])
        assertEquals(FsValue.Bool(true), doc["notifyNewPostsFromFollowing"])
        assertEquals(FsValue.Bool(false), doc["notifyNewPostsFromEveryone"])
    }

    @Test
    fun `userCreateはfcmTokenなど書かない項目を出力しない`() {
        // 要件 2.10。fcmToken は 1 ユーザー 1 トークン。Android が書くと iOS 端末への通知が途切れる
        listOf(true, false).forEach { hasEmail ->
            val doc = DocumentBuilders.userCreate(uid, if (hasEmail) "taro@example.com" else null, now)
            listOf(
                "fcmToken", "fcmTokenUpdatedAt", "customEditTools", "customEditToolsOrder", "followedTags",
                "iapAccountToken", "blockedUserIds", "displayName", "photoURL", "bio",
            ).forEach { key -> assertFalse(key in doc.keys, "出力に $key が含まれる") }
        }
    }

    @Test
    fun `userCreateの出力は全て契約USER_CREATEに合格する`() {
        val emails: List<String?> = listOf(null, "taro@example.com", "a".repeat(242) + "@example.com")
        emails.forEach { email ->
            val doc = DocumentBuilders.userCreate(uid, email, now)
            assertEquals(emptyList(), validateUser(doc), "email=${email?.length}文字")
        }
    }

    @Test
    fun `userCreateは空文字のメールアドレスを変換せず契約が止める`() {
        // 空→省略の変換はビルダーでしない（入力の検査は EmailValidator の責務）。通ってしまった場合は契約が弾く（fail-closed）
        val doc = DocumentBuilders.userCreate(uid, "", now)
        assertEquals(FsValue.Str(""), doc["email"])
        assertEquals(listOf<Violation>(Violation.OutOfRange("email", "length 0 not in 1..254")), validateUser(doc))
    }

    // ============================================================
    // publicProfileCreate
    // ============================================================

    @Test
    fun `publicProfileCreateは補完元が無ければ必須の6キーだけを作る`() {
        val doc = DocumentBuilders.publicProfileCreate(uid, null, now)
        // 要件 3.4。新規登録直後は表示名などの値が無いので、任意項目はキーごと無い（要件 3.5）
        val expected: FsDocument = mapOf(
            "id" to FsValue.Str("USER-UID-1"),
            "createdAt" to FsValue.Time(now),
            "updatedAt" to FsValue.Time(now),
            "followersCount" to FsValue.Int64(0L),
            "followingCount" to FsValue.Int64(0L),
            "postsCount" to FsValue.Int64(0L),
        )
        assertEquals(expected, doc)
    }

    @Test
    fun `publicProfileCreateのidはドキュメントIDと同値で作成日時と更新日時は同じ端末時刻`() {
        val doc = DocumentBuilders.publicProfileCreate(uid, null, now)
        assertEquals(FsValue.Str(uid.value), doc["id"])
        assertEquals(FsValue.Time(now), doc["createdAt"])
        assertEquals(doc["createdAt"], doc["updatedAt"])
    }

    @Test
    fun `publicProfileCreateは補完元の表示名とアイコンと自己紹介とカウンタを写す`() {
        // 要件 3.7 の補完。iOS の PublicProfile(from: user)（PublicProfile.swift:61-75）に相当する
        val source = UserProfileFields(
            displayName = "そら",
            photoUrl = "https://example.invalid/icon.jpg",
            bio = "空が好き",
            followersCount = 12L,
            followingCount = 34L,
            postsCount = 56L,
        )
        val doc = DocumentBuilders.publicProfileCreate(uid, source, now)
        val expected: FsDocument = mapOf(
            "id" to FsValue.Str("USER-UID-1"),
            "createdAt" to FsValue.Time(now),
            "updatedAt" to FsValue.Time(now),
            "followersCount" to FsValue.Int64(12L),
            "followingCount" to FsValue.Int64(34L),
            "postsCount" to FsValue.Int64(56L),
            "displayName" to FsValue.Str("そら"),
            "photoURL" to FsValue.Str("https://example.invalid/icon.jpg"),
            "bio" to FsValue.Str("空が好き"),
        )
        assertEquals(expected, doc)
    }

    @Test
    fun `publicProfileCreateは補完元の値が無い任意項目だけをキーごと省略する`() {
        // 要件 3.5：nullを書かず、キーごと省略する。3 項目は互いに独立
        val base = UserProfileFields("そら", "https://example.invalid/icon.jpg", "空が好き", 1L, 2L, 3L)
        listOf(
            "displayName" to base.copy(displayName = null),
            "photoURL" to base.copy(photoUrl = null),
            "bio" to base.copy(bio = null),
        ).forEach { (key, source) ->
            val doc = DocumentBuilders.publicProfileCreate(uid, source, now)
            assertFalse(key in doc.keys, "$key のキーが残っている: ${doc.keys}")
            assertEquals(8, doc.size, "$key 以外は写る: ${doc.keys}")
        }
        val allNull = DocumentBuilders.publicProfileCreate(uid, UserProfileFields(null, null, null, 7L, 8L, 9L), now)
        assertEquals(setOf("id", "createdAt", "updatedAt", "followersCount", "followingCount", "postsCount"), allNull.keys)
        assertEquals(FsValue.Int64(7L), allNull["followersCount"], "任意項目が無くてもカウンタは写る")
        assertEquals(FsValue.Int64(9L), allNull["postsCount"])
    }

    @Test
    fun `publicProfileCreateは補完元の空文字をキーごと省略する`() {
        // 要件 3.5：空文字も書かない。users から読んだ値は外部のデータなので、空文字が混ざっても補完を止めず省略する
        val doc = DocumentBuilders.publicProfileCreate(uid, UserProfileFields("", "", "", 0L, 0L, 0L), now)
        listOf("displayName", "photoURL", "bio").forEach { key -> assertFalse(key in doc.keys, "$key の空文字が書かれる") }
        assertEquals(emptyList(), validateProfile(doc))
    }

    @Test
    fun `publicProfileCreateのキー名はiOSの綴りのphotoURL`() {
        val doc = DocumentBuilders.publicProfileCreate(uid, UserProfileFields(null, "https://example.invalid/i.jpg", null, 0L, 0L, 0L), now)
        assertEquals(FsValue.Str("https://example.invalid/i.jpg"), doc["photoURL"])
        assertFalse("photoUrl" in doc.keys, "Kotlin の綴り photoUrl をキーにしてはいけない（PublicProfile.swift:91-93）")
    }

    @Test
    fun `publicProfileCreateは機密の項目やおすすめの空を出力しない`() {
        val source = UserProfileFields("そら", "https://example.invalid/i.jpg", "空が好き", 1L, 2L, 3L)
        listOf(null, source).forEach { s ->
            val doc = DocumentBuilders.publicProfileCreate(uid, s, now)
            listOf(
                "email", "fcmToken", "fcmTokenUpdatedAt", "blockedUserIds", "followedTags", "iapAccountToken",
                "notifyReactions", "notifyNewPostsFromFollowing", "notifyNewPostsFromEveryone",
                "recommendedPostIds", "customEditTools", "customEditToolsOrder",
            ).forEach { key -> assertFalse(key in doc.keys, "出力に $key が含まれる") }
        }
    }

    @Test
    fun `publicProfileCreateの出力は全て契約PUBLIC_PROFILE_CREATEに合格する`() {
        val sources: List<UserProfileFields?> = listOf(
            null,
            UserProfileFields("そら", iconUrl, "空が好き", 12L, 34L, 56L),
            UserProfileFields("そら", null, null, 0L, 0L, 0L),
            UserProfileFields(null, iconUrl, null, 0L, 0L, 0L),
            UserProfileFields(null, null, "空が好き", 0L, 0L, 0L),
            UserProfileFields(null, null, null, 5L, 6L, 7L),
            UserProfileFields("", "", "", 0L, 0L, 0L),
        )
        sources.forEachIndexed { index, source ->
            assertEquals(emptyList(), validateProfile(DocumentBuilders.publicProfileCreate(uid, source, now)), "補完元 #$index")
        }
    }

    @Test
    fun `publicProfileCreateは補完元のカウンタが負なら契約違反のまま書かせない`() {
        // 壊れた users（負のカウンタ）を、そのまま公開プロフィールへ広げない。ビルダーは値を黙って直さず、契約が止める
        val doc = DocumentBuilders.publicProfileCreate(uid, UserProfileFields(null, null, null, -1L, 0L, 0L), now)
        assertEquals(FsValue.Int64(-1L), doc["followersCount"])
        val violations = validateProfile(doc)
        assertEquals(1, violations.size, violations.toString())
        assertTrue(violations.single() is Violation.OutOfRange, violations.toString())
    }
}
