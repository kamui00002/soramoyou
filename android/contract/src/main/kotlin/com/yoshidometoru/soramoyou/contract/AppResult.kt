// ⭐️ 処理の成功・失敗を表す結果の型（タスク 3.1）
package com.yoshidometoru.soramoyou.contract

/**
 * 処理の結果。例外を投げる代わりに、失敗も値として返す（呼び出し側が分岐を書き忘れるとコンパイルが通らない）。
 * 失敗は [AppError] で、成功の型 [T] に依存しない（[Err] は `AppResult<Nothing>`）ため、
 * どの成功の型の結果としても返せる。
 */
sealed interface AppResult<out T> {
    /** 成功。[value] が結果。 */
    data class Ok<out T>(val value: T) : AppResult<T>

    /** 失敗。[error] が原因。 */
    data class Err(val error: AppError) : AppResult<Nothing>
}
