// ⭐️ アカウント文書の作成の契約（USER_CREATE・PUBLIC_PROFILE_CREATE）の単体テスト（タスク 13.2・要件 2.10・3.1〜3.5）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.Uid
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * 契約そのものを、**ビルダーを使わずに手で組んだ文書**で確かめる。
 * ビルダーの出力が合格するかは DocumentBuildersTest 側で見る。ここは「契約が何を通し、何を弾くか」を固定する。
 *
 * 陽性対照（先に赤を確かめたもの）：
 * - 必須キーの欠落が `MissingKey` になること
 * - 契約外のキー（`fcmToken` など）を含む作成が `UnexpectedKey` になること
 * - 通知設定の既定値・カウンタの 0 を崩した作成が `OutOfRange` になること
 * 仮置き（空の許可リストの契約）では、これらは全て赤になった（空の許可リストは、必須キーを欠落とも言わず、
 * 全てのキーを契約外と言うため、「この 1 件だけ」という期待と食い違う）。
 * ただし、仮置きで赤になることは、契約が本物のとき `fcmToken` だけを正しく契約外にできる証拠にはならない。
 * その検出力は、契約へ `fcmToken` を許す改変や必須キーを外す改変で別に確かめる（引き継ぎ文書に記録）。
 * 仮置きでも緑のままだったのは、契約の `id` の取り違えと、違反の説明に値が入らないことの 2 組の回帰ガードだけ。
 */
class AccountCreateContractsTest {

    private val uid = Uid("USER-UID-1")
    private val otherUid = Uid("OTHER-UID-2")
    private val now = Instant.parse("2026-10-05T01:02:03Z")

    /** `users/{uid}` への作成。ドキュメント ID も認証ユーザーも同じ uid（`isOwner(userId)`）。 */
    private val userTarget = WriteTarget(documentId = uid.value, authUid = uid)

    /** `publicProfiles/{uid}` への作成。 */
    private val profileTarget = WriteTarget(documentId = uid.value, authUid = uid)

    /** アイコン（`photoURL`）として通る、本番の Storage のダウンロード URL の形の値（名前の `/` は `%2F` に符号化する）。 */
    private val iconUrl =
        "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/users%2FUSER-UID-1%2Fprofile%2Ficon.jpg?alt=media&token=abc-123"

    // ---- 合格する文書（手書き） ----

    /** 必須のキーだけの `users` の作成（メールアドレス無し）。 */
    private fun validUser(): Map<String, FsValue> = linkedMapOf(
        "id" to FsValue.Str(uid.value),
        "createdAt" to FsValue.Time(now),
        "updatedAt" to FsValue.Time(now),
        "followersCount" to FsValue.Int64(0L),
        "followingCount" to FsValue.Int64(0L),
        "postsCount" to FsValue.Int64(0L),
        "notifyReactions" to FsValue.Bool(true),
        "notifyNewPostsFromFollowing" to FsValue.Bool(true),
        "notifyNewPostsFromEveryone" to FsValue.Bool(false),
    )

    /** 必須のキーだけの `publicProfiles` の作成。 */
    private fun validProfile(): Map<String, FsValue> = linkedMapOf(
        "id" to FsValue.Str(uid.value),
        "createdAt" to FsValue.Time(now),
        "updatedAt" to FsValue.Time(now),
        "followersCount" to FsValue.Int64(0L),
        "followingCount" to FsValue.Int64(0L),
        "postsCount" to FsValue.Int64(0L),
    )

    private val requiredUserKeys = listOf(
        "id", "createdAt", "updatedAt", "followersCount", "followingCount", "postsCount",
        "notifyReactions", "notifyNewPostsFromFollowing", "notifyNewPostsFromEveryone",
    )
    private val requiredProfileKeys = listOf("id", "createdAt", "updatedAt", "followersCount", "followingCount", "postsCount")

    private fun validateUser(doc: FsDocument, target: WriteTarget = userTarget) =
        AllowListShapeValidator.validate(ShapeContracts.USER_CREATE, doc, target)

    private fun validateProfile(doc: FsDocument, target: WriteTarget = profileTarget) =
        AllowListShapeValidator.validate(ShapeContracts.PUBLIC_PROFILE_CREATE, doc, target)

    // ============================================================
    // USER_CREATE
    // ============================================================

    @Test
    fun `USER_CREATEの契約はIDがUSER_CREATEである`() {
        assertEquals(ContractId.USER_CREATE, ShapeContracts.USER_CREATE.id)
    }

    @Test
    fun `USER_CREATEは必須のキーだけの作成を通す`() {
        assertEquals(emptyList(), validateUser(validUser()))
    }

    @Test
    fun `USER_CREATEはメールアドレスがあれば通しメールアドレスが無くても通す`() {
        // 要件 3.3：メールアドレスがあるときだけ書く。匿名（採用する場合）のメールアドレス無しも合格
        assertEquals(emptyList(), validateUser(validUser() + ("email" to FsValue.Str("taro@example.com"))))
        assertEquals(emptyList(), validateUser(validUser()))
    }

    @Test
    fun `USER_CREATEは必須キーを1つ欠くとそのキーの欠落だけを返す`() {
        // 陽性対照：必須キーの欠落（要件 3.1・3.2）
        requiredUserKeys.forEach { key ->
            val doc = validUser() - key
            assertEquals(listOf<Violation>(Violation.MissingKey(key)), validateUser(doc), "必須の $key を外した")
        }
    }

    @Test
    fun `USER_CREATEはメールアドレスの有無で必須キーの数が変わらない`() {
        val keys = ShapeContracts.USER_CREATE.fields.filter { it.required }.map { it.key }
        assertEquals(requiredUserKeys.sorted(), keys.sorted())
        val email = ShapeContracts.USER_CREATE.fields.single { it.key == "email" }
        assertEquals(false, email.required, "email は任意（匿名ではキーごと省略）")
    }

    @Test
    fun `USER_CREATEは契約外のキーを全て契約外として返す`() {
        // 陽性対照：契約外のキーを含む作成（要件 2.10：fcmToken は Android が書かない）
        val forbidden = listOf(
            "fcmToken", "fcmTokenUpdatedAt", "customEditTools", "customEditToolsOrder", "followedTags",
            "iapAccountToken", "blockedUserIds", "displayName", "photoURL", "bio", "recommendedPostIds",
        )
        forbidden.forEach { key ->
            val doc = validUser() + (key to FsValue.Str("x"))
            assertEquals(listOf<Violation>(Violation.UnexpectedKey(key)), validateUser(doc), "$key は USER_CREATE の許可リストに無い")
        }
    }

    @Test
    fun `USER_CREATEはfcmTokenを配列や別の種類で入れても契約外とする`() {
        listOf(
            FsValue.Str("token"), FsValue.StrList(listOf("token")), FsValue.ServerTime, FsValue.DeleteField,
        ).forEach { value ->
            assertEquals(
                listOf<Violation>(Violation.UnexpectedKey("fcmToken")),
                validateUser(validUser() + ("fcmToken" to value)),
                "fcmToken を ${value.kind} で入れた",
            )
        }
    }

    @Test
    fun `USER_CREATEのidはドキュメントIDと一致しなければ範囲外`() {
        // id の一致はこの契約（EqualsDocumentId）で縛る
        val doc = validUser() + ("id" to FsValue.Str(otherUid.value))
        val violations = validateUser(doc)
        assertEquals(1, violations.size, violations.toString())
        assertTrue(violations.single() is Violation.OutOfRange && (violations.single() as Violation.OutOfRange).key == "id", violations.toString())
    }

    @Test
    fun `USER_CREATEのcreatedAtとupdatedAtは端末時刻のTimestampだけ`() {
        // QC：users は端末の時刻。サーバー時刻・文字列・整数は種類が違う
        listOf("createdAt", "updatedAt").forEach { key ->
            assertEquals(
                listOf<Violation>(Violation.WrongKind(key, ValueKind.SERVER_TIME)),
                validateUser(validUser() + (key to FsValue.ServerTime)),
                "$key にサーバー時刻を入れた",
            )
            assertEquals(
                listOf<Violation>(Violation.WrongKind(key, ValueKind.STR)),
                validateUser(validUser() + (key to FsValue.Str("2026-10-05"))),
                "$key に文字列を入れた",
            )
        }
    }

    @Test
    fun `USER_CREATEのカウンタは整数の0だけ`() {
        listOf("followersCount", "followingCount", "postsCount").forEach { key ->
            assertEquals(emptyList(), validateUser(validUser() + (key to FsValue.Int64(0L))))
            assertEquals(
                listOf<Violation>(Violation.OutOfRange(key, "integer value not in 0..0")),
                validateUser(validUser() + (key to FsValue.Int64(1L))),
                "$key=1 は新規の値ではない",
            )
            assertEquals(
                listOf<Violation>(Violation.OutOfRange(key, "integer value not in 0..0")),
                validateUser(validUser() + (key to FsValue.Int64(-1L))),
                "$key=-1",
            )
            assertEquals(
                listOf<Violation>(Violation.WrongKind(key, ValueKind.STR)),
                validateUser(validUser() + (key to FsValue.Str("0"))),
                "$key を文字列の 0 にした",
            )
            // 加算は「作成」ではない（作成時にカウンタを書くのは値そのもの）
            assertEquals(
                listOf<Violation>(Violation.WrongKind(key, ValueKind.INCREMENT)),
                validateUser(validUser() + (key to FsValue.Increment(1L))),
                "$key を increment にした",
            )
        }
    }

    @Test
    fun `USER_CREATEの通知設定は既定値のtrue_true_falseだけ`() {
        // 要件 3.2。Functions の既定（functions/index.js:49-53）と一致させる。誤ると全員への新着通知が既定で届く
        val expected = mapOf(
            "notifyReactions" to true,
            "notifyNewPostsFromFollowing" to true,
            "notifyNewPostsFromEveryone" to false,
        )
        expected.forEach { (key, value) ->
            assertEquals(emptyList(), validateUser(validUser() + (key to FsValue.Bool(value))), "$key の既定値")
            val violations = validateUser(validUser() + (key to FsValue.Bool(!value)))
            assertEquals(
                listOf<Violation>(Violation.OutOfRange(key, "value is not the expected boolean $value")),
                violations,
                "$key を既定値の反対にした",
            )
            assertEquals(
                listOf<Violation>(Violation.WrongKind(key, ValueKind.STR)),
                validateUser(validUser() + (key to FsValue.Str(value.toString()))),
                "$key を文字列にした",
            )
        }
    }

    @Test
    fun `USER_CREATEのメールアドレスは文字列で長さ1から254`() {
        // rules の isValidEmail の size() の部分。正規表現は EmailValidator（13.1）が入力の段階で見る
        assertEquals(emptyList(), validateUser(validUser() + ("email" to FsValue.Str("a".repeat(254)))), "254 は上端")
        assertEquals(
            listOf<Violation>(Violation.OutOfRange("email", "length 255 not in 1..254")),
            validateUser(validUser() + ("email" to FsValue.Str("a".repeat(255)))),
        )
        assertEquals(
            listOf<Violation>(Violation.OutOfRange("email", "length 0 not in 1..254")),
            validateUser(validUser() + ("email" to FsValue.Str(""))),
            "空文字は書かない（要件 3.5）",
        )
        assertEquals(
            listOf<Violation>(Violation.WrongKind("email", ValueKind.INT64)),
            validateUser(validUser() + ("email" to FsValue.Int64(1L))),
        )
        assertEquals(
            listOf<Violation>(Violation.WrongKind("email", ValueKind.DELETE)),
            validateUser(validUser() + ("email" to FsValue.DeleteField)),
            "作成でフィールドの削除は書けない",
        )
    }

    @Test
    fun `USER_CREATEの違反の説明にuidやメールアドレスの値が入らない`() {
        val secretEmail = "secret.person@example.com"
        val doc = validUser() + ("id" to FsValue.Str(otherUid.value)) + ("email" to FsValue.Str(secretEmail.repeat(20)))
        val text = validateUser(doc).toString()
        assertTrue(!text.contains(otherUid.value), text)
        assertTrue(!text.contains("secret.person"), text)
        assertTrue(!text.contains(uid.value), text)
    }

    // ============================================================
    // PUBLIC_PROFILE_CREATE
    // ============================================================

    @Test
    fun `PUBLIC_PROFILE_CREATEの契約はIDがPUBLIC_PROFILE_CREATEである`() {
        assertEquals(ContractId.PUBLIC_PROFILE_CREATE, ShapeContracts.PUBLIC_PROFILE_CREATE.id)
    }

    @Test
    fun `PUBLIC_PROFILE_CREATEは必須のキーだけの作成を通す`() {
        assertEquals(emptyList(), validateProfile(validProfile()))
    }

    @Test
    fun `PUBLIC_PROFILE_CREATEは任意項目が全てあっても通す`() {
        val doc = validProfile() +
            ("displayName" to FsValue.Str("そら")) +
            ("photoURL" to FsValue.Str(iconUrl)) +
            ("bio" to FsValue.Str("空が好き"))
        assertEquals(emptyList(), validateProfile(doc))
    }

    @Test
    fun `PUBLIC_PROFILE_CREATEは必須キーを1つ欠くとそのキーの欠落だけを返す`() {
        // 陽性対照：必須キーの欠落（要件 3.4）
        requiredProfileKeys.forEach { key ->
            assertEquals(listOf<Violation>(Violation.MissingKey(key)), validateProfile(validProfile() - key), "必須の $key を外した")
        }
    }

    @Test
    fun `PUBLIC_PROFILE_CREATEの任意項目は表示名とアイコンと自己紹介だけ`() {
        val optional = ShapeContracts.PUBLIC_PROFILE_CREATE.fields.filter { !it.required }.map { it.key }
        assertEquals(listOf("bio", "displayName", "photoURL"), optional.sorted())
        val required = ShapeContracts.PUBLIC_PROFILE_CREATE.fields.filter { it.required }.map { it.key }
        assertEquals(requiredProfileKeys.sorted(), required.sorted())
    }

    @Test
    fun `PUBLIC_PROFILE_CREATEは契約外のキーを全て契約外として返す`() {
        // 陽性対照：契約外のキーを含む作成。公開プロフィールは誰でも読めるので、機密の項目を絶対に書かせない
        val forbidden = listOf(
            "fcmToken", "fcmTokenUpdatedAt", "email", "blockedUserIds", "followedTags", "iapAccountToken",
            "notifyReactions", "notifyNewPostsFromFollowing", "notifyNewPostsFromEveryone",
            // iOS も空のときは書かない。Android MVP は書かない（設計書 :1093）
            "recommendedPostIds", "customEditTools", "customEditToolsOrder",
        )
        forbidden.forEach { key ->
            val doc = validProfile() + (key to FsValue.Str("x"))
            assertEquals(listOf<Violation>(Violation.UnexpectedKey(key)), validateProfile(doc), "$key は PUBLIC_PROFILE_CREATE の許可リストに無い")
        }
    }

    @Test
    fun `PUBLIC_PROFILE_CREATEのidはドキュメントIDと一致しなければ範囲外`() {
        // rules の publicProfiles の create（issue #133）
        val violations = validateProfile(validProfile() + ("id" to FsValue.Str(otherUid.value)))
        assertEquals(1, violations.size, violations.toString())
        val v = violations.single()
        assertTrue(v is Violation.OutOfRange && v.key == "id", violations.toString())
    }

    @Test
    fun `PUBLIC_PROFILE_CREATEのカウンタは補完で写せるよう0以上の整数なら通す`() {
        // 新規は 0、補完では users の値を写す（設計書 :1089）。負の値は書かない
        listOf("followersCount", "followingCount", "postsCount").forEach { key ->
            assertEquals(emptyList(), validateProfile(validProfile() + (key to FsValue.Int64(0L))), "$key=0")
            assertEquals(emptyList(), validateProfile(validProfile() + (key to FsValue.Int64(123L))), "$key=123")
            val negative = validateProfile(validProfile() + (key to FsValue.Int64(-1L)))
            assertEquals(1, negative.size, "$key=-1: $negative")
            assertTrue(negative.single() is Violation.OutOfRange, negative.toString())
            assertEquals(
                listOf<Violation>(Violation.WrongKind(key, ValueKind.STR)),
                validateProfile(validProfile() + (key to FsValue.Str("0"))),
                "$key を文字列にした",
            )
        }
    }

    @Test
    fun `PUBLIC_PROFILE_CREATEのcreatedAtとupdatedAtは端末時刻のTimestampだけ`() {
        listOf("createdAt", "updatedAt").forEach { key ->
            assertEquals(
                listOf<Violation>(Violation.WrongKind(key, ValueKind.SERVER_TIME)),
                validateProfile(validProfile() + (key to FsValue.ServerTime)),
                "$key にサーバー時刻を入れた",
            )
        }
    }

    @Test
    fun `PUBLIC_PROFILE_CREATEの任意の文字列は空文字や文字列以外を通さない`() {
        // 要件 3.5：nullや空文字を書かずキーごと省略する。空文字を書いた作成は契約違反
        listOf("displayName", "photoURL", "bio").forEach { key ->
            // photoURL は Storage のダウンロード URL の形だけを通すので、通る値はその形の URL にする（他の 2 つは 1 文字）
            val accepted = if (key == "photoURL") iconUrl else "a"
            assertEquals(emptyList(), validateProfile(validProfile() + (key to FsValue.Str(accepted))), "$key の通る値")
            val empty = validateProfile(validProfile() + (key to FsValue.Str("")))
            assertEquals(1, empty.size, "$key の空文字: $empty")
            val v = empty.single()
            assertTrue(v is Violation.OutOfRange && v.key == key, empty.toString())
            assertEquals(
                listOf<Violation>(Violation.WrongKind(key, ValueKind.INT64)),
                validateProfile(validProfile() + (key to FsValue.Int64(1L))),
                "$key を整数にした",
            )
            assertEquals(
                listOf<Violation>(Violation.WrongKind(key, ValueKind.DELETE)),
                validateProfile(validProfile() + (key to FsValue.DeleteField)),
                "作成でフィールドの削除は書けない",
            )
        }
    }

    @Test
    fun `PUBLIC_PROFILE_CREATEのアイコンのURLはStorageのダウンロードURLの形だけ`() {
        // 契約の画像の URL の形（レビュー R14）。形の細かい境界は ValueConstraintTest が確かめる。説明に URL は入れない
        assertEquals(
            listOf<Violation>(Violation.OutOfRange("photoURL", "value does not match any of the 2 allowed patterns")),
            validateProfile(validProfile() + ("photoURL" to FsValue.Str("https://example.com/a.jpg"))),
        )
    }

    @Test
    fun `PUBLIC_PROFILE_CREATEの違反の説明に表示名や自己紹介の値が入らない`() {
        val text = validateProfile(validProfile() + ("bio" to FsValue.Int64(1L)) + ("recommendedPostIds" to FsValue.StrList(listOf("SECRET-POST")))).toString()
        assertTrue(!text.contains("SECRET-POST"), text)
    }
}
