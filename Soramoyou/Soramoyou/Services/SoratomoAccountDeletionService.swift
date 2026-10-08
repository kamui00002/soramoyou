//
//  SoratomoAccountDeletionService.swift
//  Soramoyou
//
//  退会のときに、そらとものデータを消すサービス ⭐️☁️
//  （release-gate 9.4・design.md の「退会（SoratomoAccountDeletionService・SettingsViewModel・SettingsView）」・要件 3.1・3.2）
//
//  - Callable `soratomoDeleteMyData` を、完了（`{ done: true }`）が返るまで呼ぶ（最大 8 回・1 回 75 秒）。
//    サーバーは 1 回あたり 45 秒の予算で消し、消し切れなければ `done: false` を返す（続きは次の呼び出しで消す）
//  - 失敗は固定の文言（通信できない／時間をおいて）に写す。サーバーの文言は画面に出さない
//
//  ⚠️ そらともの機能フラグに関わらず呼ぶ。サーバーもクレームを確かめない（要件 1.4）。
//     使っていない人（匿名を含む）には、消すものが無いので 1 回目で完了が返る（要件 3.8）。
//  ⚠️ 失敗の記録（SoratomoError.record）に入れてよいのは ID だけ（要件 14.1）。
//

import FirebaseFunctions
import Foundation

// MARK: - Functions の窓口（テストで差し替える）

/// 退会の Callable の窓口
///
/// `SoratomoAccountDeletionService` は、この窓口が投げたエラーを写すことと、呼び直すかを決めることを受け持つ。
/// 窓口は元のエラーのまま投げる（形は `SoratomoModerationDataSource` と同じ）。
protocol SoratomoAccountDeletionDataSource: Sendable {
    /// Callable を呼んで、戻り値（デコード済みの JSON）を返す
    /// - Parameters:
    ///   - name: Callable の名前
    ///   - payload: 送る値
    ///   - timeout: 制限時間（秒）
    func callCallable(_ name: String, payload: [String: Any], timeout: TimeInterval) async throws -> Any
}

// MARK: - サービス

/// 記録（非致命エラー）に残す、退会のそらとも分の失敗（ID も中身も持たない）
private enum SoratomoAccountDeletionFailure: LocalizedError {
    /// 戻り値が、決めた形（`{ done: Bool }`）でなかった
    case malformedResponse
    /// 最大回数まで呼んでも、完了が返らなかった
    case incomplete

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            "soratomo: 退会の戻り値の形が違う"
        case .incomplete:
            "soratomo: 退会の削除が最大回数で終わらなかった"
        }
    }
}

/// 退会のときに、そらとものデータを消すサービス（`SoratomoAccountDeletionServiceProtocol` の本物の実装）
final class SoratomoAccountDeletionService: SoratomoAccountDeletionServiceProtocol {
    /// 退会の Callable の名前（functions/soratomo.js の `exports` と同じ）
    static let callableName = "soratomoDeleteMyData"
    /// 1 回の制限時間（秒）。サーバーの予算 45 秒（`DELETE_BUDGET_MS`）＋余裕
    static let callTimeout: TimeInterval = 75
    /// 呼ぶ回数の上限
    static let maxCalls = 8

    /// Functions の窓口
    private let dataSource: any SoratomoAccountDeletionDataSource

    /// - Parameter dataSource: Functions の窓口。既定は本物（呼ばれたときに初めて Firebase を使う）
    init(dataSource: any SoratomoAccountDeletionDataSource = SoratomoAccountDeletionFirebaseDataSource()) {
        self.dataSource = dataSource
    }

    // MARK: - SoratomoAccountDeletionServiceProtocol

    /// そらとものデータを消し終えるまで、退会の Callable を呼ぶ
    ///
    /// - 完了が返ったら、すぐに戻る（それ以上は呼ばない）
    /// - 失敗したら、呼び直さずに投げる（通信・制限時間切れは `.network`、それ以外は `.unknown`）。
    ///   続きは利用者がもう一度退会を押したときに消す（サーバーの削除は何度流しても同じ結果になる・要件 3.3・3.4）
    /// - `maxCalls` 回呼んでも完了しなければ `.incomplete`
    func deleteMyData() async throws(SoratomoAccountDeletionError) {
        for _ in 0 ..< Self.maxCalls {
            let response: Any
            do {
                response = try await dataSource.callCallable(
                    Self.callableName,
                    payload: [:],
                    timeout: Self.callTimeout
                )
            } catch {
                throw Self.mapCallError(error)
            }
            guard let done = Self.doneValue(response) else {
                SoratomoError.record(SoratomoAccountDeletionFailure.malformedResponse, context: "soratomo.deleteMyData.response")
                throw SoratomoAccountDeletionError.unknown
            }
            if done {
                return
            }
        }
        SoratomoError.record(SoratomoAccountDeletionFailure.incomplete, context: "soratomo.deleteMyData.incomplete")
        throw SoratomoAccountDeletionError.incomplete
    }

    // MARK: - 純関数

    /// Callable の失敗を写す。通信・制限時間切れは `.network`、それ以外は記録に残して `.unknown`
    static func mapCallError(_ error: Error) -> SoratomoAccountDeletionError {
        if SoratomoGroupService.mapCallableError(error) == .network {
            return .network
        }
        SoratomoError.record(error, context: "soratomo.deleteMyData")
        return .unknown
    }

    /// 戻り値の `done`。形が違えば nil
    static func doneValue(_ response: Any) -> Bool? {
        guard let object = response as? [String: Any] else {
            return nil
        }
        return object["done"] as? Bool
    }
}

// MARK: - 本物の窓口

/// 退会の Callable（asia-northeast1）の本物の窓口
///
/// 状態を持たない（呼ばれるたびに `Functions` を引く）。アプリの外（単体テスト）で
/// `SoratomoAccountDeletionService()` を作っても、呼ばない限り Firebase に触れない。
struct SoratomoAccountDeletionFirebaseDataSource: SoratomoAccountDeletionDataSource {
    private var functions: Functions {
        Functions.functions(region: SoratomoGroupService.region)
    }

    func callCallable(_ name: String, payload: [String: Any], timeout: TimeInterval) async throws -> Any {
        let callable = functions.httpsCallable(name)
        callable.timeoutInterval = timeout
        let result = try await callable.call(payload)
        return result.data
    }
}
