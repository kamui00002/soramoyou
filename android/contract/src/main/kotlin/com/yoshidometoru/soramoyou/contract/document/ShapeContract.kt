// ⭐️ 書き込みの形の契約のデータ型（タスク 3.3・要件 3.5・7.12）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.Uid

// 契約は「このコレクションへ、この操作で書いてよいキーと値」を静的な定数として書いたもの（設計書 :556-595）。
// 個々のコレクションの契約（POST_CREATE の中身など）は、M2 以降の各マイルストーンで足す。
// このファイルは、契約を書くための型と、書き間違いを作った時点で止める検査だけを持つ。

/**
 * 契約の各項目が「なぜそう決まっているか」の根拠の種類。契約を読む人が、その制約を緩めてよいかを判断するための注記で、
 * 検証の動きには影響しない。
 */
enum class Basis {
    /** `firestore.rules` の `hasAll`（必須キー）に由来する。 */
    RULES_HAS_ALL,

    /** `firestore.rules` が値そのものを検査している（列挙値・件数・文字数・ID の一致など）。 */
    RULES_VALUE,

    /** iOS の読み取り（`Post.init(from:)` など）が、無いとデコードを失敗させる。 */
    IOS_READER_REQUIRED,

    /** カウンタだけを更新する操作（rules が「このキーだけの更新」に限っている）。 */
    COUNT_ONLY_UPDATE,

    /** rules は縛っていないが、iOS の書き込みと同じ形に揃える。 */
    IOS_SHAPE_PARITY,

    /** 任意の項目（無ければキーごと省略する）。 */
    OPTIONAL,
}

/** 契約の識別子。違反の記録で「どの契約に対する違反か」を示す。設計書 :583-584 のとおり。 */
enum class ContractId {
    POST_CREATE,
    POST_IMAGE,
    POST_LIKE_COUNTER,
    USER_CREATE,
    USER_PROFILE_UPDATE,
    USER_POSTS_COUNT,
    USER_BLOCKED_IDS,
    PUBLIC_PROFILE_CREATE,
    PUBLIC_PROFILE_UPDATE,
    PUBLIC_PROFILE_POSTS_COUNT,
    LIKE_CREATE,
    REPORT_CREATE,
    FEEDBACK_CREATE,

    /**
     * 投稿のコメント数の減算（退会で自分のコメントを消すとき。タスク 31.3）。設計書の DocumentShapeValidator／ShapeContracts の節の並びには無かったので、このタスクで足した。
     * 既存の値の序数を変えないよう、並びの末尾に置いた。
     */
    POST_COMMENT_COUNTER,
}

/**
 * 契約の 1 項目。
 *
 * @property key 許可するキー。
 * @property kinds 許可する値の種類。値が無いものは契約に書けない（空だと、その項目に何を入れても違反になり、
 *   書き間違いとしか考えられないため、作った時点で止める）。
 * @property required `true` なら、このキーが無いと違反。`false` の項目は「キーを入れない」ことで値無しを表す。
 * @property basis この項目の根拠の種類（注記）。
 * @property constraint 種類が合ったときに、さらに値の範囲を検査する制約。
 */
data class FieldRule(
    val key: String,
    val kinds: Set<ValueKind>,
    val required: Boolean,
    val basis: Basis,
    val constraint: ValueConstraint? = null,
) {
    init {
        require(kinds.isNotEmpty()) { "kinds が空の FieldRule は作れない: key=$key" }
    }
}

/**
 * 1 つのコレクション・1 つの操作に対する、書き込みの形の契約。
 *
 * @property id 契約の識別子。
 * @property fields 許可するキーの一覧（許可リスト）。**宣言順が、違反を報告する順序の基準になる**。
 *   ここに無いキーは全て違反（`UnexpectedKey`）。
 * @property nested `MAP_LIST` の項目（`images` など）の各要素の契約。キーは項目のキー。
 *
 * 契約は静的な定数なので、書き間違いは検証の実行時ではなく、契約を作った時点（このクラスの `init`）で止める。
 * 間違った契約が黙って「合格」を出し続けるのを避けるためである。
 */
data class ShapeContract(
    val id: ContractId,
    val fields: List<FieldRule>,
    val nested: Map<String, ShapeContract> = emptyMap(),
) {
    init {
        val keys = fields.map { it.key }
        require(keys.size == keys.toSet().size) {
            "契約 $id にキーの重複がある: ${keys.groupingBy { it }.eachCount().filterValues { it > 1 }.keys}"
        }

        // MAP_LIST を取りうる項目のキー。要素の中身（入れ子）の契約が要るのは、この項目だけ
        val mapListKeys = fields.filter { ValueKind.MAP_LIST in it.kinds }.map { it.key }.toSet()

        val strayNested = nested.keys - mapListKeys
        require(strayNested.isEmpty()) {
            "契約 $id の nested のキーが、MAP_LIST を取りうる項目のキーでない: $strayNested"
        }

        // nested が無いと、要素の中の未知キー・欠落を検証できず素通りになるので、作れないようにする（fail-closed）
        val missingNested = mapListKeys - nested.keys
        require(missingNested.isEmpty()) {
            "契約 $id の MAP_LIST の項目に nested の契約が無い: $missingNested"
        }
    }
}

/**
 * 書き込み先の情報。値が「ドキュメント ID と一致すること」「認証ユーザーの uid と一致すること」を検査するために使う。
 *
 * @property documentId 書き込み先ドキュメントの ID（`posts/{postId}` の postId など）。
 * @property authUid 書き込みをしている認証済みユーザーの uid。
 */
data class WriteTarget(val documentId: String, val authUid: Uid)
