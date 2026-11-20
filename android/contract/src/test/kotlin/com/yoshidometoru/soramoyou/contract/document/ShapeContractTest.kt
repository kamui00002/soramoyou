// ⭐️ 契約（FieldRule・ShapeContract）の構築時の検査の単体テスト（タスク 3.3・要件 3.5・7.12）
package com.yoshidometoru.soramoyou.contract.document

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * 契約は静的な定数として書く。書き間違い（キーの重複・nested の付け忘れ）を、検証の実行時ではなく
 * 契約を作った時点で止める（そうしないと、間違った契約が黙って「合格」を出し続けうる）。
 *
 * ContractId は、ここでは何でもよいので、テスト用に POST_CREATE / POST_IMAGE を借りている（実際の契約ではない）。
 */
class ShapeContractTest {

    private fun strField(key: String) = FieldRule(key, setOf(ValueKind.STR), required = true, basis = Basis.OPTIONAL)

    private fun mapListField(key: String, kinds: Set<ValueKind> = setOf(ValueKind.MAP_LIST)) =
        FieldRule(key, kinds, required = true, basis = Basis.RULES_HAS_ALL)

    /** テスト用の入れ子の契約。 */
    private val elementContract = ShapeContract(ContractId.POST_IMAGE, listOf(strField("url")))

    @Test
    fun `正しい契約は作れる`() {
        val contract = ShapeContract(
            id = ContractId.POST_CREATE, // テスト用
            fields = listOf(strField("a"), mapListField("images")),
            nested = mapOf("images" to elementContract),
        )
        assertEquals(listOf("a", "images"), contract.fields.map { it.key })
    }

    @Test
    fun `nestedの無い単純な契約も作れる`() {
        ShapeContract(ContractId.POST_LIKE_COUNTER, listOf(strField("a"))) // テスト用
    }

    @Test
    fun `fieldsが空の契約も作れる`() {
        ShapeContract(ContractId.POST_LIKE_COUNTER, emptyList()) // テスト用
    }

    @Test
    fun `MAP_LISTを含む複数kindのfieldにもnestedを付けられる`() {
        ShapeContract(
            id = ContractId.POST_CREATE, // テスト用
            fields = listOf(mapListField("images", kinds = setOf(ValueKind.MAP_LIST, ValueKind.DELETE))),
            nested = mapOf("images" to elementContract),
        )
    }

    @Test
    fun `キーが重複する契約は作れない`() {
        assertFailsWith<IllegalArgumentException> {
            ShapeContract(ContractId.POST_CREATE, listOf(strField("a"), strField("b"), strField("a"))) // テスト用
        }
    }

    @Test
    fun `MAP_LISTのfieldにnestedが無い契約は作れない`() {
        // 要素の中身を検証できず、要素の中の未知キーが素通りしてしまうため（fail-closed）
        assertFailsWith<IllegalArgumentException> {
            ShapeContract(ContractId.POST_CREATE, listOf(mapListField("images"))) // テスト用
        }
    }

    @Test
    fun `MAP_LISTを含む複数kindのfieldにnestedが無い契約も作れない`() {
        assertFailsWith<IllegalArgumentException> {
            ShapeContract(
                ContractId.POST_CREATE, // テスト用
                listOf(mapListField("images", kinds = setOf(ValueKind.MAP_LIST, ValueKind.DELETE))),
            )
        }
    }

    @Test
    fun `MAP_LISTでないfieldへのnestedは作れない`() {
        assertFailsWith<IllegalArgumentException> {
            ShapeContract(
                id = ContractId.POST_CREATE, // テスト用
                fields = listOf(strField("caption")),
                nested = mapOf("caption" to elementContract),
            )
        }
    }

    @Test
    fun `どのfieldにも無いキーへのnestedは作れない`() {
        assertFailsWith<IllegalArgumentException> {
            ShapeContract(
                id = ContractId.POST_CREATE, // テスト用
                fields = listOf(strField("caption")),
                nested = mapOf("nothing" to elementContract),
            )
        }
    }

    @Test
    fun `kindsが空のFieldRuleは作れない`() {
        assertFailsWith<IllegalArgumentException> {
            FieldRule("a", emptySet(), required = true, basis = Basis.OPTIONAL)
        }
    }
}
