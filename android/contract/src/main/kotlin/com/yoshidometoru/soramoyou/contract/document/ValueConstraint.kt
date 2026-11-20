// ⭐️ 値の範囲の制約（タスク 3.3・要件 7.12・7.13）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.rules.TextLimits

/**
 * 契約の項目に付ける、値の範囲の制約。種類（[ValueKind]）が合った値に対して、さらに範囲を検査する。
 *
 * [check] は、範囲内なら `null`、範囲外なら「何が範囲外か」の説明を返す。
 * 説明は `Violation.OutOfRange.detail` になり、ログ（Crashlytics）へ載る。
 * **説明に値そのもの（文字列の中身・ID・整数の値）を入れてはいけない**。キャプションは利用者の文章であり、
 * ID は個人を特定しうるため。入れてよいのは、長さ・件数・範囲という、契約と入力の形だけである。
 *
 * [check] は値のほかに、書き込み先 [WriteTarget] と、トップレベルの文書全体 [root] を受け取る。
 * 今ある制約は [root] を使わないが、投稿の `storagePath` の接頭辞（`posts/{userId}/{visibility}/`）のように、
 * 「同じ文書の別のキーの値」に依存する制約を、タスク 20.4 で**制約を 1 つ足すだけで**書けるようにするためである
 * （入れ子の要素の検証中でも、[root] には要素ではなくトップレベルの文書が渡る）。
 * 投稿の `storagePath` の接頭辞の制約は [StoragePathUnder]（タスク 20.4）。
 *
 * 制約が想定していない種類の値に当たったときは、黙って通さず範囲外とする（fail-closed）。
 * 契約の `kinds` に、その制約が扱えない種類を書き間違えたときに、検証が素通りするのを防ぐ。
 */
sealed interface ValueConstraint {

    /** 範囲内なら `null`。範囲外なら、値を含まない説明。 */
    fun check(value: FsValue, target: WriteTarget, root: FsDocument): String?

    /** 文字列。列挙値の `raw` だけを許す（要件 7.13）。大文字小文字・前後の空白は区別する（正規化しない）。 */
    data class OneOf(val allowed: Set<String>) : ValueConstraint {
        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            if (value !is FsValue.Str) return unsupportedKind(this, value)
            return if (value.value in allowed) null else "value is not one of the ${allowed.size} allowed values"
        }
    }

    /**
     * 文字列。UTF-16 の長さ（[String.length]）が [range] 内。
     * Firestore rules の `size()` に対して緩くならないよう、コードポイント数ではなくこちらで数える（設計書 :619）。
     * 絵文字 1 個は 2 と数える。下限を 1 にすれば空文字も弾ける（要件 7.12）。
     */
    data class Utf16LengthIn(val range: IntRange) : ValueConstraint {
        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            if (value !is FsValue.Str) return unsupportedKind(this, value)
            val length = value.value.length
            return if (length in range) null else "length $length not in $range"
        }
    }

    /** 整数。`likesCount` を 0 に固定する、`width` を正にする、など。 */
    data class IntIn(val range: LongRange) : ValueConstraint {
        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            if (value !is FsValue.Int64) return unsupportedKind(this, value)
            // 値そのものは説明に入れない（範囲だけ）
            return if (value.value in range) null else "integer value not in $range"
        }
    }

    /** リスト（文字列の配列・マップの配列・配列への追加・配列からの削除）の要素数。`images` は 1..10、`hashtags` は 1..30。 */
    data class CountIn(val range: IntRange) : ValueConstraint {
        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            val count = when (value) {
                is FsValue.StrList -> value.values.size
                is FsValue.MapList -> value.values.size
                is FsValue.ArrayUnion -> value.values.size
                is FsValue.ArrayRemove -> value.values.size
                else -> return unsupportedKind(this, value)
            }
            return if (count in range) null else "count $count not in $range"
        }
    }

    /** 加算の差分 `by`。許す値だけを通す（いいねの数は ±1 のみ）。 */
    data class IncrementIn(val allowed: Set<Long>) : ValueConstraint {
        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            if (value !is FsValue.Increment) return unsupportedKind(this, value)
            // 許す値は契約の定数で、入力ではないので説明に入れてよい。入力の値は入れない
            return if (value.by in allowed) null else "increment is not one of the allowed values ${allowed.sorted()}"
        }
    }

    /**
     * 真偽値。期待した値（[expected]）だけを許す。通知設定の既定値（`notifyReactions`＝true など）を、作成の契約で固定する
     * （タスク 13.2・要件 3.2）。期待値は契約の定数なので、説明に入れてよい。入力の値は入れない。
     */
    data class BoolIs(val expected: Boolean) : ValueConstraint {
        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            if (value !is FsValue.Bool) return unsupportedKind(this, value)
            return if (value.value == expected) null else "value is not the expected boolean $expected"
        }
    }

    /** 文字列が、書き込み先のドキュメント ID（[WriteTarget.documentId]）と一致する（`postId`・`id`）。 */
    data object EqualsDocumentId : ValueConstraint {
        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            if (value !is FsValue.Str) return unsupportedKind(this, value)
            // 実際の値も期待する ID も、説明に入れない
            return if (value.value == target.documentId) null else "value does not match the document id"
        }
    }

    /**
     * 文字列が空でなく、書き込み先のドキュメント ID が「認証済みユーザーの uid ＋ `_` ＋ この値」である（いいね文書の `postId`）。
     * rules（firestore.rules の likes の create）の `likeId ==request.auth.uid + '_' + request.resource.data.postId` と同じ形。
     * 空の値を拒むのは、ドキュメント ID が `{uid}_` のときにも一致してしまうため。
     */
    data object DocumentIdIsAuthUidAndValue : ValueConstraint {
        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            if (value !is FsValue.Str) return unsupportedKind(this, value)
            if (value.value.isEmpty()) return "value is empty"
            // 実際の値も期待する ID も、説明に入れない
            return if (target.documentId == "${target.authUid.value}_${value.value}") null
            else "document id is not the authenticated uid joined with the value"
        }
    }

    /** 文字列が、認証済みユーザーの uid（[WriteTarget.authUid]）と一致する（`userId`）。他人の uid での書き込みを止める。 */
    data object EqualsAuthUid : ValueConstraint {
        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            if (value !is FsValue.Str) return unsupportedKind(this, value)
            return if (value.value == target.authUid.value) null else "value does not match the authenticated uid"
        }
    }

    /**
     * 投稿の画像の Storage のパスが、`{top}/{投稿者の uid}/{公開範囲}/{ファイル名}` の形である（要件 7.3。タスク 20.4）。
     *
     * 根拠：
     * - storage.rules の `match /posts/{userId}/public/{imageId}` などと、サムネイルの `match /thumbnails/{userId}/...`。
     *   公開範囲のセグメントは `public`・`followers`・`private` で、`Visibility.raw` と 1 対 1（iOS：PostViewModel.swift:706-716）
     * - iOS のパスの作り方（PostViewModel.swift:728-735）：本体 `posts/{uid}/{公開範囲}/{UUID}.jpg`、
     *   サムネイル `thumbnails/{uid}/{公開範囲}/{UUID}_thumb.jpg`
     *
     * 投稿者の uid と公開範囲は、トップレベルの文書（[root]）の `userId`・`visibility` から読む（画像の要素の中には無いため）。
     * 公開範囲を変えずにパスだけ違う、を止めるのが目的である（公開の投稿の画像が非公開の場所にあると、iOS で画像が読めない）。
     *
     * ファイル名は「空でなく `/` を含まない 1 区切り」で、[fileNameSuffix] で終わること（storage.rules の `{imageId}` は 1 区切り。
     * 接尾辞は rules ではなく iOS の形に揃えるため）。
     *
     * [root] の `userId`・`visibility` が無い・文字列でないときも、例外にせず範囲外とする（fail-closed）。説明に uid やパスは入れない。
     */
    data class StoragePathUnder(val top: String, val fileNameSuffix: String) : ValueConstraint {
        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            if (value !is FsValue.Str) return unsupportedKind(this, value)
            val userId = (root["userId"] as? FsValue.Str)?.value
            val visibility = (root["visibility"] as? FsValue.Str)?.value
            if (userId.isNullOrEmpty() || visibility.isNullOrEmpty()) return "cannot resolve the owner uid and visibility of the document"
            val prefix = "$top/$userId/$visibility/"
            if (!value.value.startsWith(prefix)) return "path is not under $top/{userId}/{visibility}/ of the document"
            val fileName = value.value.removePrefix(prefix)
            if ('/' in fileName || fileName.length <= fileNameSuffix.length || !fileName.endsWith(fileNameSuffix)) {
                return "file name is not a single segment ending with $fileNameSuffix"
            }
            return null
        }
    }

    /**
     * 文字列。空白だけでなく（空文字も含む）、UTF-16 の長さが [max] 以下（フィードバックの本文：タスク 28）。
     *
     * 空白は全角空白を含む Unicode の空白で、[TextLimits.isBlank] と同じ集合（iOS の `.whitespacesAndNewlines` と同じ。
     * Kotlin の `isBlank()` は集合が違うので使わない）。長さは [Utf16LengthIn] と同じく UTF-16 の単位（rules の `size()` に合わせる）。
     * 前後の空白を取り除くのはこの制約でなく入力の段階の責任で、ここは書く値そのものを見る（rules も書く値の `size()` を見る）。
     *
     * 説明には、空白だけか長すぎるかと長さだけを入れる。本文（利用者の文章）は入れない。
     */
    data class NonBlankUtf16LengthAtMost(val max: Int) : ValueConstraint {
        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            if (value !is FsValue.Str) return unsupportedKind(this, value)
            if (TextLimits.isBlank(value.value)) return "value is blank (empty or whitespace only)"
            val length = value.value.length
            return if (length <= max) null else "length $length not in 1..$max"
        }
    }

    /**
     * 文字列が、[patterns]（正規表現）のどれかに**全体で**一致する（画像の URL：Storage のダウンロード URL の形。レビュー R14）。
     *
     * 正規表現は rules の `matches` と同じく全体で一致を見る（[Regex.matches]。一部の一致では通さない）。
     * 使う形は [com.yoshidometoru.soramoyou.contract.rules.StorageDownloadUrl] に置く（rules の文字列を写したもの）。
     *
     * 説明には形の数だけを入れ、値（URL）は入れない。URL のパスには uid が、クエリにはダウンロードの token が入るため。
     */
    data class MatchesAnyPattern(val patterns: List<String>) : ValueConstraint {
        init {
            require(patterns.isNotEmpty()) { "MatchesAnyPattern の形が空" }
        }

        private val regexes: List<Regex> = patterns.map(::Regex)

        override fun check(value: FsValue, target: WriteTarget, root: FsDocument): String? {
            if (value !is FsValue.Str) return unsupportedKind(this, value)
            return if (regexes.any { it.matches(value.value) }) null else "value does not match any of the ${patterns.size} allowed patterns"
        }
    }
}

/** 制約が想定していない種類の値に当たったときの説明。種類の名前だけを入れ、値は入れない。 */
private fun unsupportedKind(constraint: ValueConstraint, value: FsValue): String =
    "constraint ${constraint::class.simpleName} cannot be applied to kind ${value.kind}"
