// ⭐️ 書き込みの形の違反（タスク 3.1。検証の仕組み本体はタスク 3.3）
package com.yoshidometoru.soramoyou.contract.document

// AppError.ShapeViolation（タスク 3.1）が違反の一覧を持つために、設計書 :579-591 の定義をそのまま先に置いている。
// DocumentShapeValidator・ShapeContracts・FieldRule（タスク 3.3）は、これを再定義せずに使うこと。

/** Firestore へ書く値の種類（FsValue の種類と 1 対 1。FsValue 自体はタスク 3.3 で定義する）。 */
enum class ValueKind {
    STR,
    INT64,
    BOOL,
    TIME,
    SERVER_TIME,
    INCREMENT,
    STR_LIST,
    MAP_LIST,
    ARRAY_UNION,
    ARRAY_REMOVE,
    DELETE,
}

/** 形の契約に対する 1 件の違反。検証は違反の一覧を返し、空なら合格とする。 */
sealed interface Violation {
    /** 必須のキーが無い。 */
    data class MissingKey(val key: String) : Violation

    /** 契約（許可リスト）に無いキーがある。 */
    data class UnexpectedKey(val key: String) : Violation

    /** 値の種類が契約と違う。[actual] は実際に入っていた種類。 */
    data class WrongKind(val key: String, val actual: ValueKind) : Violation

    /** 値が契約の範囲の外にある。[detail] は「何が範囲外か」の説明（値そのものは入れない）。 */
    data class OutOfRange(val key: String, val detail: String) : Violation
}
