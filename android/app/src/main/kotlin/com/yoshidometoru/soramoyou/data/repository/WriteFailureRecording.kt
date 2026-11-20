// ⭐️ 書き込みの入口から返った失敗のうち、呼び出し側が記録するものだけを記録する（タスク 14.2・14.3）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade

/**
 * 書き込みの入口（FirestoreWriteGateway）が返した失敗 [error] を、呼び出し側が [context]（`クラス名.メソッド名[.段階]`）で記録する。
 *
 * 入口は、自分で断ったもの（可否の無効 [AppError.WriteBlocked]・形の違反 [AppError.ShapeViolation]）を、返す前に記録済みにしている。
 * それをもう一度記録すると、本番で 0 件でなければリリースを止める根拠になる件数（設計書 :1136）が二重になる。だからこの 2 つは記録しない。
 * 入口が写して返しただけの Firebase の失敗（通信・権限の拒否・不在・その他）は、入口は記録しないので、ここで記録する。
 *
 * ⚠️ 権限の拒否（[AppError.PermissionDenied]）には 2 通りある：入口が「未ログイン」や退会の間（`FirestoreWriteGateway.exclusively` の区間）で断ったもの（記録済み）と、Firestore の rules が拒んだもの
 *    （未記録）。値の上では区別できない。rules との食い違いの見逃しの方が、二重の記録より高くつくので、記録する側に倒す
 *    （権限の拒否は分類が user_error で `error_occurred` だけに行き、Crashlytics には行かない。二重になっても監視の件数には影響しない）。
 */
internal fun AnalyticsFacade.recordForwardedWriteFailure(error: AppError, context: String) {
    when (error) {
        is AppError.WriteBlocked, is AppError.ShapeViolation -> Unit
        else -> logError(error, context)
    }
}

/**
 * Storage の入口（StorageGateway）が返した失敗 [error] を、呼び出し側が [context] で記録する。
 *
 * Storage の入口が自分で断って記録済みにするのは、可否の無効 [AppError.WriteBlocked] と大きすぎる画像 [AppError.ImageTooLarge] である
 * （Firestore の入口と違い、形の検証は無く、大きさの検査がある）。この 2 つは記録せず、写して返しただけの Storage の失敗を記録する。
 *
 * ⚠️ 退会の間（`StorageGateway.exclusively` の区間）に入口が断ったアップロードの [AppError.PermissionDenied] も記録済みだが、
 *    Storage の rules の拒否と値の上では区別できないので、上の Firestore の権限の拒否と同じく記録する側に倒す（user_error なので監視の件数には影響しない）。
 */
internal fun AnalyticsFacade.recordForwardedStorageFailure(error: AppError, context: String) {
    when (error) {
        is AppError.WriteBlocked, is AppError.ImageTooLarge -> Unit
        else -> logError(error, context)
    }
}
