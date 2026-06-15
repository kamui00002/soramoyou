//
//  FeedbackViewModel.swift
//  Soramoyou
//
//  アプリ内フィードバック送信の ViewModel
//

import Foundation
import UIKit

/// フィードバック画面の ViewModel
@MainActor
class FeedbackViewModel: ObservableObject {
    @Published var message = ""
    @Published var category: FeedbackCategory = .bug
    @Published var isSending = false
    @Published var errorMessage: String?
    /// 送信完了（成功画面の表示に使う）
    @Published var didSubmit = false

    private let firestoreService: FirestoreServiceProtocol
    private let authService: AuthServiceProtocol

    /// 本文の最大文字数（`firestore.rules` の上限と一致させる）
    let maxLength = 1000

    init(firestoreService: FirestoreServiceProtocol = FirestoreService(),
         authService: AuthServiceProtocol = AuthService()) {
        self.firestoreService = firestoreService
        self.authService = authService
    }

    /// フィードバックを送信
    /// - Returns: 成功時は true
    func submit() async -> Bool {
        // 未ログインは送信不可（ルールでも拒否されるため事前に弾く）
        guard let userId = authService.currentUser()?.id else {
            errorMessage = "ログインが必要です"
            return false
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else {
            errorMessage = "1〜\(maxLength)文字で入力してください"
            return false
        }

        isSending = true
        errorMessage = nil

        let feedback = Feedback(
            userId: userId,
            message: trimmed,
            category: category.rawValue,
            appVersion: Self.currentAppVersion(),
            deviceInfo: Self.currentDeviceInfo()
        )

        do {
            try await firestoreService.submitFeedback(feedback)
            isSending = false
            didSubmit = true
            return true
        } catch {
            ErrorHandler.logError(error, context: "FeedbackViewModel.submit", userId: userId)
            errorMessage = error.userFriendlyMessage
            isSending = false
            return false
        }
    }

    // MARK: - Metadata

    /// 送信時のアプリバージョン（例 "1.7.4 (57)"）
    static func currentAppVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// 送信時の端末情報（例 "iOS 18.5 / iPhone"）
    static func currentDeviceInfo() -> String {
        "iOS \(UIDevice.current.systemVersion) / \(UIDevice.current.model)"
    }
}
