//
//  DraftsViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import Combine
import FirebaseAuth

@MainActor
class DraftsViewModel: ObservableObject {
    @Published var drafts: [Draft] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let firestoreService: FirestoreServiceProtocol
    
    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }
    
    // MARK: - Load Drafts
    
    /// 下書き一覧を読み込む
    func loadDrafts() async {
        guard let userId = Auth.auth().currentUser?.uid else {
            errorMessage = "ユーザーが認証されていません"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            // リトライ可能な操作として実行
            drafts = try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.fetchDrafts(userId: userId)
            }
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "DraftsViewModel.loadDrafts", userId: userId)
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
        
        isLoading = false
    }
    
    // MARK: - Delete Draft
    
    /// 下書きを削除
    func deleteDraft(_ draft: Draft) async {
        isLoading = true
        errorMessage = nil
        
        do {
            // リトライ可能な操作として実行
            try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.deleteDraft(draftId: draft.id)
            }
            // ローカルのリストからも削除
            drafts.removeAll { $0.id == draft.id }
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "DraftsViewModel.deleteDraft", userId: Auth.auth().currentUser?.uid)
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
        
        isLoading = false
    }
}
