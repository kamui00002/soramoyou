//
//  SoratomoReactionService.swift
//  Soramoyou
//
//  そらともの投稿へのリアクションのサービス ⭐️☁️
//  （soratomo-reactions 7.5・design.md の「SoratomoReactionService」の節・要件 1.3, 1.4, 1.5, 4.15, 10.4, 10.7）
//
//  - 送る: Callable `soratomoSetReaction`（制限時間 20 秒）に `{ groupId, skyId, kind }` を送る。
//    外すときも `kind` の鍵は残し、値を `NSNull()`（JSON の null）にする（tasks 1.2 で「鍵がある・値は null」で届くことを実測済み）
//  - 受ける: `{ outcome, kind }`。形が違っても失敗にしない（サーバーは書いた後に返すため）
//
//  ⚠️ 計測（SoratomoAnalytics.log）はここでは呼ばない。ViewModel の責務（7.6）。
//  ⚠️ 失敗の記録（SoratomoError.record）に入れてよいのは固定の文脈だけ。グループ ID・投稿 ID・uid は入れない（要件 14.1）。
//

import FirebaseFunctions
import Foundation

// MARK: - サービス

/// 記録（非致命エラー）に残す、リアクションの失敗（ID も中身も持たない）
private enum SoratomoReactionFailure: LocalizedError {
    /// Callable の戻り値が、決めた形（`{ outcome: 4 つのどれか, kind: 7 つの名前のどれか | null }`）でなかった
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            "soratomo: リアクションの戻り値の形が違う"
        }
    }
}

/// リアクションのサービス（`SoratomoReactionServiceProtocol` の本物の実装）
final class SoratomoReactionService: SoratomoReactionServiceProtocol {
    /// リアクションの Callable の名前（functions/soratomo.js の `exports` と同じ）
    static let setReactionCallableName = "soratomoSetReaction"

    /// Functions の窓口
    private let dataSource: any SoratomoReactionDataSource

    /// - Parameter dataSource: Functions の窓口。既定は本物（呼ばれたときに初めて Firebase を使う）
    init(dataSource: any SoratomoReactionDataSource = SoratomoReactionFirebaseDataSource()) {
        self.dataSource = dataSource
    }

    // MARK: - SoratomoReactionServiceProtocol

    /// 自分のリアクションを kind にする（nil なら外す）
    ///
    /// 失敗は `SoratomoGroupService.mapCallableError` で写す。想定外（`.unknown`・`.permissionDenied`）だけ記録する。
    /// 戻り値の形が違うときは、サーバーが書いた後かもしれないので失敗にせず、
    /// 「変わらなかった」と送った `kind` で返す（`createSky` と同じ考え方）。
    func setReaction(groupId: String, skyId: String, kind: SoratomoReactionKind?)
        async throws(SoratomoError) -> SoratomoReactionChange
    {
        let response: Any
        do {
            response = try await dataSource.callCallable(
                Self.setReactionCallableName,
                payload: Self.payload(groupId: groupId, skyId: skyId, kind: kind),
                timeout: SoratomoGroupService.callTimeout
            )
        } catch {
            let mapped = SoratomoGroupService.mapCallableError(error)
            switch mapped {
            case .unknown, .permissionDenied:
                // self_reaction・invalid_reaction・invalid_input もここに来る（新しい版のアプリは送らないので想定外）
                SoratomoError.record(error, context: "soratomo.setReaction")
            default:
                break
            }
            throw mapped
        }
        if let change = Self.change(from: response) {
            return change
        }
        SoratomoError.record(SoratomoReactionFailure.malformedResponse, context: "soratomo.setReaction.response")
        return SoratomoReactionChange(outcome: .unchanged, kind: kind)
    }

    // MARK: - 純関数

    /// 送る値を作る
    ///
    /// 外すときも `kind` の鍵を残して値を `NSNull()` にする。鍵を省くとサーバーは `invalid_input` で拒否する。
    static func payload(groupId: String, skyId: String, kind: SoratomoReactionKind?) -> [String: Any] {
        [
            "groupId": groupId,
            "skyId": skyId,
            "kind": kind?.rawValue ?? NSNull(),
        ]
    }

    /// Callable の戻り値 `{ outcome, kind }` を読む
    ///
    /// - Returns: 読めたら結果。辞書でない・`outcome` が無い／知らない値・`kind` の鍵が無い／null でも 7 つの名前でもない、は nil
    static func change(from response: Any) -> SoratomoReactionChange? {
        guard let object = response as? [String: Any],
              let outcomeName = object["outcome"] as? String,
              let outcome = SoratomoReactionOutcome(rawValue: outcomeName),
              let rawKind = object["kind"] // 鍵が無いときは読めない扱い（null は NSNull として鍵ごと残る）
        else {
            return nil
        }
        if rawKind is NSNull {
            return SoratomoReactionChange(outcome: outcome, kind: nil)
        }
        guard let kindName = rawKind as? String,
              let kind = SoratomoReactionKind(rawValue: kindName)
        else {
            return nil
        }
        return SoratomoReactionChange(outcome: outcome, kind: kind)
    }
}

// MARK: - 本物の窓口

/// リアクションの Callable（asia-northeast1）の本物の窓口
///
/// 状態を持たない（呼ばれるたびに `Functions` を引く）。アプリの外（単体テスト）で
/// `SoratomoReactionService()` を作っても、呼ばない限り Firebase に触れない。
struct SoratomoReactionFirebaseDataSource: SoratomoReactionDataSource {
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
