// ⭐️ 許可リスト方式の形の検証（タスク 3.3・要件 3.5・7.12）
package com.yoshidometoru.soramoyou.contract.document

/**
 * 書き込む文書が、契約（[ShapeContract]）の形に合っているかを検証する。
 * 戻り値は違反の一覧で、**空なら合格**。書き込みの直前に、ゲートウェイが全ての書き込みでこれを通し、
 * 違反があれば書き込まずに失敗とする（fail-closed。設計書 :576）。
 */
interface DocumentShapeValidator {
    fun validate(contract: ShapeContract, doc: FsDocument, target: WriteTarget): List<Violation>
}

/**
 * 許可リスト方式の検証。状態を持たない純関数。
 *
 * 規約:
 * - 契約の `fields` に無いキーは、全て [Violation.UnexpectedKey]（`MAP_LIST` の各要素の中も同じ）。
 *   ブラックリスト（書いてはいけないキーの列挙）にしないのは、iOS 側で新しいキーが増えても、
 *   契約に足すまでは Android から書けない側に倒れるため。
 * - 必須（`required`）のキーが無ければ [Violation.MissingKey]。必須でないキーが無いのは合格（キーを入れないことが「値無し」）。
 * - 値の種類が `kinds` に無ければ [Violation.WrongKind]。**種類が違うときは制約を見ない**（二重に報告しない）。
 *   `DeleteField` も特別扱いせず、`kinds` に `DELETE` が無ければ同じく [Violation.WrongKind]。
 * - `kinds` に `DELETE` があって値が `DeleteField` なら、**制約は見ない**。削除は「値を入れない」ことで、値の範囲の制約の
 *   対象ではないため（2026-10-05 ユーザー判断・タスク 13.3）。これで「入れるなら 1 文字以上・消すのは可」を 1 つの項目で書ける。
 *   削除を許すかどうかは、`kinds` の `DELETE` だけで決まる。
 * - 種類が合えば、制約を検査して外れたら [Violation.OutOfRange]。
 * - `MAP_LIST` の値は、種類と制約（件数）を検査したあとで、各要素を `nested` の契約で再帰的に検証する。
 *   要素の違反のキーは `images[0].width` の形（親のキー[添字].子のキー）。
 * - **違反の順序は決定的**: 契約の `fields` の宣言順に、そのキーの違反（欠落・種類・範囲・入れ子の違反）を並べ、
 *   最後にその階層の契約外のキーをキーの昇順で並べる。入れ子の要素の中でも同じ規則で、
 *   要素の契約外のキーは、その要素の違反の最後（親のキーの枠の中）に入る。
 *   文書（Map）のキーの並びには依存しない。
 */
object AllowListShapeValidator : DocumentShapeValidator {

    override fun validate(contract: ShapeContract, doc: FsDocument, target: WriteTarget): List<Violation> =
        validateDocument(contract, doc, target, root = doc, keyPrefix = "")

    /**
     * 1 つの階層（トップレベルの文書、または `MAP_LIST` の 1 要素）を検証する。
     *
     * @param root トップレベルの文書。入れ子の要素の検証中も、要素ではなくトップレベルを制約に渡す
     *   （他のキーの値に依存する制約のため。[ValueConstraint] の説明を参照）。
     * @param keyPrefix 違反のキーの前に付ける、親のキーと添字（例: `images[1].`）。トップレベルは空。
     */
    private fun validateDocument(
        contract: ShapeContract,
        doc: FsDocument,
        target: WriteTarget,
        root: FsDocument,
        keyPrefix: String,
    ): List<Violation> {
        val violations = mutableListOf<Violation>()

        for (rule in contract.fields) {
            val key = keyPrefix + rule.key
            // FsValue は null を表現できないので、get が null ならキーが無い
            val value = doc[rule.key]
            if (value == null) {
                if (rule.required) violations += Violation.MissingKey(key)
                continue
            }
            if (value.kind !in rule.kinds) {
                violations += Violation.WrongKind(key, value.kind)
                continue
            }
            // 削除は値の範囲の制約の対象外（上の規約）。削除を許すかどうかは、直前の種類の検査で済んでいる
            if (value !is FsValue.DeleteField) {
                rule.constraint?.check(value, target, root)?.let { violations += Violation.OutOfRange(key, it) }
            }

            if (value is FsValue.MapList) {
                // ShapeContract の init が、MAP_LIST を取りうる項目には必ず nested があることを保証している
                val elementContract = checkNotNull(contract.nested[rule.key]) {
                    "契約 ${contract.id} の $key に nested が無い（ShapeContract の検査をすり抜けた）"
                }
                value.values.forEachIndexed { index, element ->
                    violations += validateDocument(elementContract, element, target, root, "$key[$index].")
                }
            }
        }

        // 許可リスト: 契約に無いキーは全て違反。報告の順序を決めるため、キーの昇順にする
        val allowed = contract.fields.mapTo(HashSet()) { it.key }
        doc.keys.filter { it !in allowed }.sorted().forEach { violations += Violation.UnexpectedKey(keyPrefix + it) }

        return violations
    }
}
