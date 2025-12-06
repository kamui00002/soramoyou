//
//  AuthService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import FirebaseAuth

protocol AuthServiceProtocol {
    func signIn(email: String, password: String) async throws -> User
    func signUp(email: String, password: String) async throws -> User
    func signOut() async throws
    func currentUser() -> User?
    func observeAuthState() -> AsyncStream<User?>
}

class AuthService: AuthServiceProtocol {
    func signIn(email: String, password: String) async throws -> User {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        return User(from: result.user)
    }
    
    func signUp(email: String, password: String) async throws -> User {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        return User(from: result.user)
    }
    
    func signOut() async throws {
        try Auth.auth().signOut()
    }
    
    func currentUser() -> User? {
        guard let firebaseUser = Auth.auth().currentUser else {
            return nil
        }
        return User(from: firebaseUser)
    }
    
    func observeAuthState() -> AsyncStream<User?> {
        AsyncStream { continuation in
            let listener = Auth.auth().addStateDidChangeListener { _, firebaseUser in
                if let firebaseUser = firebaseUser {
                    continuation.yield(User(from: firebaseUser))
                } else {
                    continuation.yield(nil)
                }
            }
            
            continuation.onTermination = { @Sendable _ in
                Auth.auth().removeStateDidChangeListener(listener)
            }
        }
    }
}

