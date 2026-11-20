// ⭐️ プロフィールの更新の契約（USER_PROFILE_UPDATE・PUBLIC_PROFILE_UPDATE）と組み立ての単体テスト（タスク 13.3・要件 2.10・3.6・10.6・10.7）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.Uid
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 更新は「変えた項目と更新日時だけ」の部分更新で、空にした項目はキーの削除（設計書 QD）。
 * 2 つの契約は同じ形なので、どのテストも両方に当てる。
 *
 * 陽性対照（先に赤を確かめたもの）：`fcmToken`・フォロワー数などのカウンタ・`id`・`email` 入りの更新が違反になること。
 */
class ProfileUpdateContractsTest {

    private val uid = Uid("USER-UID-1")
    private val now = Instant.parse("2026-10-05T01:02:03Z")
    private val target = WriteTarget(documentId = uid.value, authUid = uid)

    private val contracts = listOf(ShapeContracts.USER_PROFILE_UPDATE, ShapeContracts.PUBLIC_PROFILE_UPDATE)

    private fun validate(contract: ShapeContract, doc: FsDocument): List<Violation> =
        AllowListShapeValidator.validate(contract, doc, target)

    private val updatedOnly: FsDocument = mapOf("updatedAt" to FsValue.Time(now))

    /** アイコンの URL（契約は Storage のダウンロード URL の形だけを通す。レビュー R14）。 */
    private val iconUrl =
        "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/users%2FUSER-UID-1%2Fprofile%2Ficon.jpg?alt=media&token=abc-123"

    /** 違反のキー（Violation は種類ごとに key を持つ）。 */
    private fun keyOf(violation: Violation): String = when (violation) {
        is Violation.MissingKey -> violation.key
        is Violation.UnexpectedKey -> violation.key
        is Violation.WrongKind -> violation.key
        is Violation.OutOfRange -> violation.key
    }

    // ---- 契約（手で組んだ文書） ----

    @Test
    fun `契約のIDは操作ごとに正しい`() {
        assertEquals(ContractId.USER_PROFILE_UPDATE, ShapeContracts.USER_PROFILE_UPDATE.id)
        assertEquals(ContractId.PUBLIC_PROFILE_UPDATE, ShapeContracts.PUBLIC_PROFILE_UPDATE.id)
    }

    @Test
    fun `更新日時だけの更新と、3項目を値にする更新と、3項目を消す更新は合格する`() {
        contracts.forEach { contract ->
            assertEquals(emptyList(), validate(contract, updatedOnly), contract.id.name)
            assertEquals(
                emptyList(),
                validate(
                    contract,
                    updatedOnly + mapOf(
                        "displayName" to FsValue.Str("そら"),
                        "bio" to FsValue.Str("空が好き"),
                        "photoURL" to FsValue.Str(iconUrl),
                    ),
                ),
                contract.id.name,
            )
            assertEquals(
                emptyList(),
                validate(
                    contract,
                    updatedOnly + mapOf(
                        "displayName" to FsValue.DeleteField,
                        "bio" to FsValue.DeleteField,
                        "photoURL" to FsValue.DeleteField,
                    ),
                ),
                contract.id.name,
            )
        }
    }

    @Test
    fun `更新日時の無い更新は欠落として違反にする`() {
        contracts.forEach { contract ->
            assertEquals(
                listOf<Violation>(Violation.MissingKey("updatedAt")),
                validate(contract, mapOf("displayName" to FsValue.Str("そら"))),
                contract.id.name,
            )
        }
    }

    @Test
    fun `空文字は値として書かず、範囲外として違反にする`() {
        contracts.forEach { contract ->
            listOf("displayName", "bio", "photoURL").forEach { key ->
                val violations = validate(contract, updatedOnly + (key to FsValue.Str("")))
                assertEquals(listOf(key), violations.map(::keyOf), "${contract.id.name} の $key")
                assertEquals(true, violations.single() is Violation.OutOfRange, "${contract.id.name} の $key")
            }
        }
    }

    @Test
    fun `陽性対照：fcmTokenやカウンタやidやemailを含む更新は契約外として違反にする`() {
        val forbidden = listOf(
            "fcmToken" to FsValue.Str("token"),
            "fcmTokenUpdatedAt" to FsValue.Time(now),
            "followersCount" to FsValue.Int64(1),
            "followingCount" to FsValue.Int64(1),
            "postsCount" to FsValue.Int64(1),
            "id" to FsValue.Str(uid.value),
            "email" to FsValue.Str("a@example.com"),
            "createdAt" to FsValue.Time(now),
        )
        contracts.forEach { contract ->
            forbidden.forEach { (key, value) ->
                assertEquals(
                    listOf<Violation>(Violation.UnexpectedKey(key)),
                    validate(contract, updatedOnly + (key to value)),
                    "${contract.id.name} が $key を通した",
                )
            }
        }
    }

    // ---- 組み立て（DocumentBuilders.profileUpdate） ----

    @Test
    fun `変えない項目はキーを出さず、更新日時だけを書く`() {
        val doc = DocumentBuilders.profileUpdate(
            ProfileChange(FieldChange.Unchanged, FieldChange.Unchanged, FieldChange.Unchanged),
            now,
        )
        assertEquals(updatedOnly, doc)
    }

    @Test
    fun `値にする項目は文字列で、アイコンのキーはiOSの綴りのphotoURLで書く`() {
        val doc = DocumentBuilders.profileUpdate(
            ProfileChange(FieldChange.Set("そら"), FieldChange.Set("空が好き"), FieldChange.Set("https://example.com/a.jpg")),
            now,
        )
        assertEquals(
            updatedOnly + mapOf(
                "displayName" to FsValue.Str("そら"),
                "bio" to FsValue.Str("空が好き"),
                "photoURL" to FsValue.Str("https://example.com/a.jpg"),
            ),
            doc,
        )
    }

    @Test
    fun `空にする項目はキーの削除として書く`() {
        val doc = DocumentBuilders.profileUpdate(ProfileChange(FieldChange.Clear, FieldChange.Unchanged, FieldChange.Clear), now)
        assertEquals(updatedOnly + mapOf("displayName" to FsValue.DeleteField, "photoURL" to FsValue.DeleteField), doc)
    }

    @Test
    fun `組み立ての出力は全て両方の契約に合格する`() {
        val choices = listOf(FieldChange.Unchanged, FieldChange.Set("値"), FieldChange.Clear)
        // アイコンは Storage のダウンロード URL の形だけを通すので、値にするときはその形の URL にする
        val photoChoices = listOf(FieldChange.Unchanged, FieldChange.Set(iconUrl), FieldChange.Clear)
        for (displayName in choices) for (bio in choices) for (photoUrl in photoChoices) {
            val doc = DocumentBuilders.profileUpdate(ProfileChange(displayName, bio, photoUrl), now)
            contracts.forEach { contract ->
                assertEquals(emptyList(), validate(contract, doc), "${contract.id.name}: $displayName / $bio / $photoUrl")
            }
        }
    }

    @Test
    fun `アイコンのURLはStorageのダウンロードURLの形だけ`() {
        // 契約の画像の URL の形（レビュー R14）。形の細かい境界は ValueConstraintTest が確かめる。説明に URL は入れない
        contracts.forEach { contract ->
            assertEquals(
                listOf<Violation>(Violation.OutOfRange("photoURL", "value does not match any of the 2 allowed patterns")),
                validate(contract, updatedOnly + ("photoURL" to FsValue.Str("https://example.com/a.jpg"))),
                contract.id.name,
            )
        }
    }

    @Test
    fun `空文字の値は変換せずに書き、契約が止める`() {
        // 空にするのは Clear の役目。Set("") を黙って削除に変えると、呼び出し側の取り違えが見えなくなる（userCreate の email と同じ方針）
        val doc = DocumentBuilders.profileUpdate(ProfileChange(FieldChange.Set(""), FieldChange.Unchanged, FieldChange.Unchanged), now)
        assertEquals(updatedOnly + ("displayName" to FsValue.Str("")), doc)
        contracts.forEach { contract ->
            assertEquals(listOf("displayName"), validate(contract, doc).map(::keyOf), contract.id.name)
        }
    }
}
