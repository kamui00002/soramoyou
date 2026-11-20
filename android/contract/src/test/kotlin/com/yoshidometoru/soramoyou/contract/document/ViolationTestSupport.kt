// ⭐️ 形の検証（AllowListShapeValidator）の単体テストで共有する部品（M5 レビュー F03）
package com.yoshidometoru.soramoyou.contract.document

/**
 * 違反の並びを（種類, キー）の並びにする。違反の中身（期待した型など）まで比べず、どのキーがどう違反したかだけを確かめるため。
 *
 * テストのファイルごとに同じ中身を写していたものを、ここ 1 か所にまとめた。[Violation] に種類を足したら、ここだけを直す
 * （when は全ての種類を並べているので、足したときにコンパイルで気づく）。
 * いま使っているのは、通報・ブロック（ModerationContractsTest）・フィードバック（FeedbackContractsTest）・
 * 退会のコメント数の減算（CommentCounterContractTest）の契約のテスト。
 * 前からある LikeContractsTest・PostContractsTest は、それぞれのファイルに同じ中身の private な写しを持っている
 * （同じ名前でもメンバーの側が優先されるので、衝突しない）。
 */
internal fun shapeOf(violations: List<Violation>): List<Pair<String, String>> = violations.map {
    when (it) {
        is Violation.MissingKey -> "MissingKey" to it.key
        is Violation.UnexpectedKey -> "UnexpectedKey" to it.key
        is Violation.WrongKind -> "WrongKind" to it.key
        is Violation.OutOfRange -> "OutOfRange" to it.key
    }
}
