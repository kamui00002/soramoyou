// ⭐️ アプリ内フィードバックの書き込み（タスク 30・要件 13.2〜13.4）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.contract.document.FeedbackInput
import com.yoshidometoru.soramoyou.contract.document.ShapeContracts
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import java.util.UUID

/**
 * アプリ内フィードバックの書き込み（設計書の ModerationRepository・FeedbackRepository の節の FeedbackRepository）。画面（feature/feedback）が使う。この部品は状態を持たない。
 *
 * 書き込みの失敗は [AppResult.Err] で返し、記録はこの部品が行う（発生箇所は `FeedbackRepository.submit`。入口が自分で断って
 * 記録済みのもの〔可否の無効・形の違反〕は記録し直さない）。呼び出し側（画面）は、失敗を表示するだけで記録し直さない。
 */
interface FeedbackRepository {

    /**
     * [input] のフィードバックを、`feedback` に大文字の UUID の文書として作る（iOS の `submitFeedback`：FirestoreService.swift:1161-1169）。
     * 常に書くのは `userId`・`message`・`createdAt`（サーバー時刻）で、種別・アプリのバージョン・端末情報は値があるときだけ書く（要件 13.2）。
     * メールアドレスと表示名は入力の型に無く、書かない（要件 13.4）。可否は [WriteCapability.FEEDBACK]。無効なビルド（M4 以前）では
     * Firebase に届かずに `WriteBlocked` を返す。
     *
     * 本文は前後の空白を取り除いた後の値を書く。取り除いた後が空（空白だけ・空）なら `Validation(FEEDBACK_BLANK)`、
     * 1000 を超える（rules と同じ UTF-16 の単位）なら `Validation(FEEDBACK_TOO_LONG)` を返し、何も書かない（要件 13.3）。
     * この 2 つは画面が先に止める入力の不備なので記録しない（他の入力の不備と同じ）。
     */
    suspend fun submit(input: FeedbackInput): AppResult<Unit>
}

/**
 * フィードバックの本文 [message] に、送れない理由があれば返す（無ければ null）。前後の空白（全角の空白・改行を含む。iOS の
 * `whitespacesAndNewlines` と同じ集合）を取り除いた後の本文で、空白だけなら [ValidationReason.FEEDBACK_BLANK]、
 * 1000 を超えるなら [ValidationReason.FEEDBACK_TOO_LONG]。
 *
 * 数えるのは UTF-16 の長さ（[TextLimits.isFeedbackWithinLimit]）。iOS は書記素で数える（`trimmed.count <= 1000`）が、
 * 絵文字の多い本文が iOS では通っても rules（`size() <= 1000`）が断るので、rules と同じ数え方で先に止める。
 * 書き込みの部品（[DefaultFeedbackRepository]）と画面の状態（FeedbackViewModel）の両方が使う（判定を 1 か所にして、画面と書き込みで食い違わせない）。
 */
fun feedbackMessageProblem(message: String): ValidationReason? {
    val trimmed = TextLimits.trimWhitespace(message)
    return when {
        TextLimits.isBlank(trimmed) -> ValidationReason.FEEDBACK_BLANK
        !TextLimits.isFeedbackWithinLimit(trimmed) -> ValidationReason.FEEDBACK_TOO_LONG
        else -> null
    }
}

/**
 * [FeedbackRepository] の実装。書き込みは必ず [gateway]（可否 → 書き手 → 形の検証）を通す。
 *
 * @param gateway Firestore への書き込みの唯一の入口。書き手の uid は入口が認証の SDK から読み、入力の `userId` と一致しなければ契約が止める。
 * @param analytics 失敗の記録先。
 * @param newFeedbackId 文書の ID を作る。既定は大文字の UUID（iOS の `UUID().uuidString`：Feedback.swift:44）。単体テストでは決まった値に差し替える。
 */
class DefaultFeedbackRepository(
    private val gateway: FirestoreWriteGateway,
    private val analytics: AnalyticsFacade,
    private val newFeedbackId: () -> String = { UUID.randomUUID().toString().uppercase() },
) : FeedbackRepository {

    override suspend fun submit(input: FeedbackInput): AppResult<Unit> {
        feedbackMessageProblem(input.message)?.let { return AppResult.Err(AppError.Validation(it)) }
        val result = gateway.create(
            WriteCapability.FEEDBACK,
            DocRef.feedback(newFeedbackId()),
            ShapeContracts.FEEDBACK_CREATE,
            // 書くのは取り除いた後の本文（iOS も `message: trimmed` を送る：FeedbackViewModel.swift:53）
            DocumentBuilders.feedbackCreate(input.copy(message = TextLimits.trimWhitespace(input.message))),
        )
        if (result is AppResult.Err) analytics.recordForwardedWriteFailure(result.error, SUBMIT_CONTEXT)
        return result
    }

    private companion object {
        /** 記録の発生箇所（`クラス名.メソッド名`）。 */
        const val SUBMIT_CONTEXT = "FeedbackRepository.submit"
    }
}
