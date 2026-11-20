// ⭐️ エラーの分類（タスク 3.1・要件 15.2）
package com.yoshidometoru.soramoyou.contract

/**
 * エラーの分類。[raw] は、分析イベント `error_occurred` のパラメータ `error_category` にそのまま載る文字列で、
 * iOS 版の `ErrorCategory.rawValue` と 1 文字も違わない（LoggingService.swift:308-318、送信側は :140）。
 *
 * 分類は表示と記録の扱いを決める（設計書 Error Handling の表）。
 * - [USER]：入力や操作が原因。`error_occurred` だけを送る
 * - [SYSTEM]：通信・外部サービスなど、ユーザーの外側が原因。`error_occurred` に加えて Crashlytics へ非致命エラーとして記録する
 * - [BUSINESS]：制限や契約の違反。`error_occurred` に加えて Crashlytics へ非致命エラーとして記録する
 *
 * iOS 版の列挙（ErrorHandler.swift:12-16）の `userError`・`systemError`・`businessError` に 1 対 1 で対応する。
 */
enum class ErrorCategory(val raw: String) {
    USER("user_error"),
    SYSTEM("system_error"),
    BUSINESS("business_error"),
}
