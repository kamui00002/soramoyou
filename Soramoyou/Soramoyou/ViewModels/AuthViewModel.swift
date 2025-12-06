//
//  AuthViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import Combine
import FirebaseAuth

@MainActor
class AuthViewModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var errorMessage: String?
    
    private let authService: AuthServiceProtocol
    private var cancellables = Set<AnyCancellable>()
    
    init(authService: AuthServiceProtocol = AuthService()) {
        self.authService = authService
        
        // 認証状態の監視
        Task {
            await observeAuthState()
        }
    }
    
    func signIn(email: String, password: String) async throws {
        let user = try await authService.signIn(email: email, password: password)
        currentUser = user
        isAuthenticated = true
    }
    
    func signUp(email: String, password: String) async throws {
        let user = try await authService.signUp(email: email, password: password)
        currentUser = user
        isAuthenticated = true
    }
    
    func signOut() async throws {
        try await authService.signOut()
        currentUser = nil
        isAuthenticated = false
    }
    
    private func observeAuthState() async {
        for await user in authService.observeAuthState() {
            currentUser = user
            isAuthenticated = user != nil
        }
    }
}

