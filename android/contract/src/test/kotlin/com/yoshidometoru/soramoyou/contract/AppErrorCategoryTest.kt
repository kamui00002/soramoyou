// ⭐️ 失敗の種類ごとの分類（error_category）の単体テスト（タスク 3.1・要件 15.2・15.8）
package com.yoshidometoru.soramoyou.contract

import com.yoshidometoru.soramoyou.contract.document.ValueKind
import com.yoshidometoru.soramoyou.contract.document.Violation
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 各 [AppError] がどの [ErrorCategory] に写るかを固定する。
 * 分類は「Crashlytics に非致命エラーとして残るか（system・business）」を決めるので、変わると監視の穴になる。
 *
 * 根拠は 2 つ。食い違う所は、承認済みの設計書（design.md の Error Categories 表）を優先し、各テストに明記する。
 * ただし Auth だけは例外で、iOS の型単位の規則（AuthError 型全体が userError）に揃えている。
 * - iOS の正典: Soramoyou/Soramoyou/Utils/ErrorHandler.swift の `categorize`（:23-98）
 * - 設計書: 「Error Categories and Responses」の節（:1105-1110）
 */
class AppErrorCategoryTest {

    // ── user_error ──

    @Test
    fun `認証の失敗はどの種類でもuser_errorである`() {
        // iOS は AuthError 型全体を userError にしている（ErrorHandler.swift:24-27）。種類別の例外は無い。
        // ⚠️ 設計書の表は「通信の断絶」を system_error とするが、iOS は AuthError.networkError（AuthService.swift:184）
        //    も userError。iOS の物差しに揃えることが目的（要件 15.2）なので、NETWORK も含めて USER にする。
        //    ネットワーク不通を system_error で扱いたい箇所は、Auth ではなく AppError.Network を返す。
        for (kind in AuthErrorKind.entries) {
            assertEquals(ErrorCategory.USER, AppError.Auth(kind).category, "kind=$kind")
        }
    }

    @Test
    fun `不在はuser_errorである`() {
        // ErrorHandler.swift:30-33（FirestoreServiceError.notFound → userError）
        assertEquals(ErrorCategory.USER, AppError.NotFound.category)
    }

    @Test
    fun `権限の拒否はuser_errorである`() {
        // 設計書 :1108 は「権限の拒否」を user_error に挙げている。これに従う。
        // ⚠️ iOS では FirestoreServiceError.unauthorized（FirestoreService.swift:366）が default 分岐に落ち
        //    systemError になる（ErrorHandler.swift:30-36 の default）。iOS と Android で分類が異なる箇所。
        //    なお権限の拒否も `error_occurred` には必ず載る（要件 15.8）。Crashlytics に残らないだけである。
        assertEquals(ErrorCategory.USER, AppError.PermissionDenied.category)
    }

    @Test
    fun `入力の不備はどの理由でもuser_errorである`() {
        // ErrorHandler.swift:81-84（PhotoSelectionError → userError）、:57-60（PostViewModelError.noImages → userError）
        for (reason in ValidationReason.entries) {
            assertEquals(ErrorCategory.USER, AppError.Validation(reason).category, "reason=$reason")
        }
    }

    // ── system_error ──

    @Test
    fun `通信の断絶はsystem_errorである`() {
        // ErrorHandler.swift:86-91（NSURLErrorDomain → systemError）、設計書 :1109
        assertEquals(ErrorCategory.SYSTEM, AppError.Network.category)
    }

    @Test
    fun `読めない画像はsystem_errorである`() {
        // ErrorHandler.swift:51-54（ImageServiceError.invalidImage〔ImageService.swift:1078〕などの画像処理の失敗 → systemError）
        assertEquals(ErrorCategory.SYSTEM, AppError.ImageUnreadable(index = 0).category)
    }

    @Test
    fun `未分類の失敗はsystem_errorである`() {
        // ErrorHandler.swift:96-97（どれにも当たらなければ systemError）
        assertEquals(ErrorCategory.SYSTEM, AppError.Unknown("原因不明").category)
    }

    // ── business_error ──

    @Test
    fun `5MB以上の画像はbusiness_errorである`() {
        // ErrorHandler.swift:39-47（StorageServiceError.imageTooLarge）。同じ画像で何度送っても必ず失敗する制限違反なので businessError。
        // user_error にすると Crashlytics に送られず、件数が減ったことを修正の証拠にできなくなる（同ファイルのコメント）。
        assertEquals(ErrorCategory.BUSINESS, AppError.ImageTooLarge(index = 2, bytes = 5L * 1024 * 1024).category)
    }

    @Test
    fun `書き込みの遮断はbusiness_errorである`() {
        // iOS に対応物は無い（Android 独自の仕組み）。設計書 :1110 に従う。
        for (capability in WriteCapability.entries) {
            assertEquals(ErrorCategory.BUSINESS, AppError.WriteBlocked(capability).category, "capability=$capability")
        }
    }

    @Test
    fun `形の契約違反はbusiness_errorである`() {
        // iOS に対応物は無い。設計書 :1110 に従う。
        val violations = listOf(
            Violation.MissingKey("likesCount"),
            Violation.UnexpectedKey("fcmToken"),
            Violation.WrongKind("width", ValueKind.STR),
            Violation.OutOfRange("caption", "2001文字"),
        )
        assertEquals(ErrorCategory.BUSINESS, AppError.ShapeViolation(violations).category)
    }

    // ── 段階つきの失敗 ──

    @Test
    fun `退会の段階つきの失敗は原因の分類をそのまま引き継ぐ`() {
        // iOS に対応物は無い。段階名は「どこで止まったか」の付加情報で、分類は原因で決まる。
        // 原因の分類が違う 2 つで確かめる（どちらか一方に固定されていたら片方が落ちる）。
        val network = AppError.StageFailed(DeletionStage.LIKES, AppError.Network)
        val denied = AppError.StageFailed(DeletionStage.POSTS, AppError.PermissionDenied)
        assertEquals(ErrorCategory.SYSTEM, network.category)
        assertEquals(ErrorCategory.USER, denied.category)
        assertEquals(ErrorCategory.BUSINESS, AppError.StageFailed(DeletionStage.USER, AppError.WriteBlocked(WriteCapability.ACCOUNT_DELETE)).category)
    }

    @Test
    fun `段階つきの失敗は段階と原因を取り出せる`() {
        val failed = AppError.StageFailed(DeletionStage.COMMENTS, AppError.NotFound)
        assertEquals(DeletionStage.COMMENTS, failed.stage)
        assertEquals(AppError.NotFound, failed.cause)
    }

    // ── 値の保持 ──

    @Test
    fun `画像の失敗は何枚目かと大きさを保持する`() {
        assertEquals(3, AppError.ImageUnreadable(index = 3).index)
        val tooLarge = AppError.ImageTooLarge(index = 1, bytes = 6_000_000L)
        assertEquals(1, tooLarge.index)
        assertEquals(6_000_000L, tooLarge.bytes)
    }
}
