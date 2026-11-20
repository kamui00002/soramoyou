// ⭐️ 失敗の種類（タスク 3.1・要件 15.2・15.8）
package com.yoshidometoru.soramoyou.contract

import com.yoshidometoru.soramoyou.contract.document.Violation

/**
 * 失敗の種類。画面に出す日本語の文言はここに持たない（文言は :app の担当）。
 * [category] は、分析イベント `error_occurred` の `error_category` と、Crashlytics に残すかどうかを決める。
 *
 * 分類の根拠は 2 つある。食い違う所は、承認済みの設計書を優先する。
 * ただし [Auth] だけは例外で、iOS の型単位の規則（AuthError 型全体が userError）に揃える。
 * 設計書の表は「通信の断絶」を system_error とするが、[Auth] には種類ごとに分類を変える定めが設計書に無いためである。
 * - iOS の正典：Soramoyou/Soramoyou/Utils/ErrorHandler.swift の `categorize`（:23-98）
 * - 設計書：「Error Categories and Responses」の節（:1105-1110）
 * 各分類の理由と iOS との差は、AppErrorCategoryTest に 1 つずつ書いてある。
 */
sealed interface AppError {
    val category: ErrorCategory

    /**
     * 認証の失敗。分類は種類にかかわらず [ErrorCategory.USER]。
     * iOS は `AuthError` 型全体を userError にしている（ErrorHandler.swift:24-27）。通信の断絶（[AuthErrorKind.NETWORK]）も同じ。
     */
    data class Auth(val kind: AuthErrorKind) : AppError {
        override val category: ErrorCategory get() = ErrorCategory.USER
    }

    /** 通信の断絶・タイムアウトなど（ErrorHandler.swift:86-91）。 */
    data object Network : AppError {
        override val category: ErrorCategory get() = ErrorCategory.SYSTEM
    }

    /**
     * 権限の拒否（Firestore・Storage の `PERMISSION_DENIED`）。設計書 :1108 に従い [ErrorCategory.USER]。
     * ⚠️ iOS では `FirestoreServiceError.unauthorized`（FirestoreService.swift:366）が systemError になる
     * （ErrorHandler.swift:30-36 の default 分岐）。この 1 点だけ iOS と分類が異なる。
     */
    data object PermissionDenied : AppError {
        override val category: ErrorCategory get() = ErrorCategory.USER
    }

    /** 対象が見つからない。iOS の `FirestoreServiceError.notFound` と同じ userError（ErrorHandler.swift:30-33）。 */
    data object NotFound : AppError {
        override val category: ErrorCategory get() = ErrorCategory.USER
    }

    /**
     * ビルドのマイルストーン設定で無効な書き込みを、実行時に止めたこと（M1 の「本番への書き込みゼロ」の保証）。
     * iOS に対応物は無い。設計書 :1110 に従い [ErrorCategory.BUSINESS]（Crashlytics に残り、0 件でなければリリースを止める根拠になる）。
     */
    data class WriteBlocked(val capability: WriteCapability) : AppError {
        override val category: ErrorCategory get() = ErrorCategory.BUSINESS
    }

    /**
     * 書き込む直前の形の検査に失敗したこと（書き込みは実行していない）。
     * iOS に対応物は無い。設計書 :1110 に従い [ErrorCategory.BUSINESS]。
     */
    data class ShapeViolation(val violations: List<Violation>) : AppError {
        override val category: ErrorCategory get() = ErrorCategory.BUSINESS
    }

    /**
     * 入力の不備（文字数・枚数・個数の制限など）。
     * iOS の `PhotoSelectionError`（ErrorHandler.swift:81-84）・`PostViewModelError.noImages`（:57-60）と同じ userError。
     */
    data class Validation(val reason: ValidationReason) : AppError {
        override val category: ErrorCategory get() = ErrorCategory.USER
    }

    /**
     * [index] 枚目（0 始まり）の写真が読み込めない（破損・未対応形式など。要件 6.9）。
     * iOS の `ImageServiceError`（画像処理の失敗）と同じ systemError（ErrorHandler.swift:51-54）。
     */
    data class ImageUnreadable(val index: Int) : AppError {
        override val category: ErrorCategory get() = ErrorCategory.SYSTEM
    }

    /**
     * [index] 枚目（0 始まり）の画像が 5MB 以上（要件 7.5）。[bytes] は変換後のバイト数。
     * iOS の `StorageServiceError.imageTooLarge` と同じ businessError（ErrorHandler.swift:39-47）。
     * 同じ画像を何度送っても必ず失敗する制限違反なので、再試行しない。userError にすると Crashlytics に残らない。
     */
    data class ImageTooLarge(val index: Int, val bytes: Long) : AppError {
        override val category: ErrorCategory get() = ErrorCategory.BUSINESS
    }

    /**
     * 複数の手順からなる退会処理が、[stage] の段階で [cause] により止まったこと（要件 12.4）。
     * 段階名は「どこで止まったか」の付け足しで、分類は原因 [cause] のものを引き継ぐ。
     */
    data class StageFailed(val stage: DeletionStage, val cause: AppError) : AppError {
        override val category: ErrorCategory get() = cause.category
    }

    /** どれにも当てはまらない失敗。iOS の既定の分類（ErrorHandler.swift:96-97）と同じ systemError。 */
    data class Unknown(val message: String) : AppError {
        override val category: ErrorCategory get() = ErrorCategory.SYSTEM
    }
}

/**
 * 認証の失敗の種類。iOS の `AuthError` の 10 ケースと 1 対 1（AuthService.swift:177-188）。
 * ただし iOS の `unknown(String)` は文言を持つが、こちらの [UNKNOWN] は持たない（設計書 :731 のとおり）。
 * 日本語の文言への変換は :app の AuthErrorMapper が行う（要件 2.7）。
 */
enum class AuthErrorKind {
    INVALID_INPUT,
    INVALID_EMAIL,
    WEAK_PASSWORD,
    EMAIL_ALREADY_IN_USE,
    WRONG_PASSWORD,
    USER_NOT_FOUND,
    NETWORK,
    TOO_MANY_REQUESTS,
    REQUIRES_RECENT_LOGIN,
    UNKNOWN,
}

/**
 * 入力の不備の理由。各値の根拠は要件の行。上限の数値は TextLimits（設計書 :609-613。別タスクで定義）が持つ。
 * ⚠️ 設計書は [AppError.Validation] の型として `ValidationReason` を挙げるだけで、中身を定義していない。
 *    ここでは、要件が「送信させない・確定させない・受け付けない」と定めた入力の制限だけを置いた。
 *    パスワードの短さ・メールアドレスの形式は [AuthErrorKind] が受け持つので、ここには置かない。
 */
enum class ValidationReason {
    /** 写真が 1 枚も無い（要件 6.3 の「1〜10枚」の下限）。 */
    NO_IMAGES,

    /** 写真が 10 枚を超える（要件 6.3・6.4）。 */
    TOO_MANY_IMAGES,

    /** キャプションが 2000 文字を超える（要件 7.6）。 */
    CAPTION_TOO_LONG,

    /** ハッシュタグが 30 個を超える（要件 7.8）。 */
    TOO_MANY_HASHTAGS,

    /**
     * 投稿の処理中に、もう一度投稿しようとした（要件 7.21 の二重送信の防止。タスク 23.2・2026-10-10 ユーザー判断）。
     * 画面が送信ボタンを押せなくして先に止める操作なので、他の入力の不備と同じく記録しない。
     */
    PUBLISH_IN_PROGRESS,

    /** 表示名が上限を超える（要件 10.10）。 */
    DISPLAY_NAME_TOO_LONG,

    /** 自己紹介が上限を超える（要件 10.10）。 */
    BIO_TOO_LONG,

    /** フィードバックの本文が空白だけ（要件 13.3）。 */
    FEEDBACK_BLANK,

    /** フィードバックの本文が 1000 文字を超える（要件 13.3）。 */
    FEEDBACK_TOO_LONG,
}

/**
 * 退会処理の段階。宣言の順は設計書 :885 の並び。
 * iOS の Firestore 側の退会は FirestoreService.swift:884-945 で、段階名を `stage` 変数に持つ
 * （publicProfiles → follows.follower → follows.followee → likes → comments → posts → storage.postImages → posts → drafts → favorites →
 * storage.profileIcon → storage.leftovers → users。画像の 3 つは #260 から。
 * 初期値の `stage = "publicProfiles"` は :884）。この相対的な順は、下の宣言順と同じである。
 * [REAUTH]・[AUTH]・[POST_IMAGES]・[PROFILE_IMAGE] は Firestore の外側の手順で、設計書 :885 で足されている。
 * [STORAGE_LEFTOVERS] も Firestore の外側の手順で、タスク 31.6 で足した（自分の画像のフォルダを一覧して、文書から拾えなかった画像を消す）。
 * 段階を作る側（AccountDeletionService）は :app にあるが、[AppError.StageFailed] が参照するためここに置く。
 */
enum class DeletionStage {
    REAUTH,
    PUBLIC_PROFILE,
    FOLLOWS_AS_FOLLOWER,
    FOLLOWS_AS_FOLLOWEE,
    LIKES,
    COMMENTS,
    POST_IMAGES,
    POSTS,
    DRAFTS,
    FAVORITES,
    PROFILE_IMAGE,
    STORAGE_LEFTOVERS,
    USER,
    AUTH,
}

/**
 * 書き込みの機能の単位。ビルドのマイルストーン設定で、有効な集合が決まる（設計書「マイルストーンと有効化の範囲」。M1 は空集合）。
 * 有効かどうかを答える WriteGate は :app にあるが、[AppError.WriteBlocked] が参照するためこの列挙はここに置く。
 */
enum class WriteCapability {
    ACCOUNT_CREATE,
    ACCOUNT_REPAIR,
    PROFILE_EDIT,
    LIKE,
    POST_CREATE,
    POSTS_COUNT_SYNC,
    POST_DELETE,
    REPORT,
    BLOCK,
    FEEDBACK,
    ACCOUNT_DELETE,
}
