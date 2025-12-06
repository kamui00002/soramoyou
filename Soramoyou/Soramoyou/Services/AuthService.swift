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
        // バリデーション
        guard !email.isEmpty, !password.isEmpty else {
            throw AuthError.invalidInput
        }
        
        guard isValidEmail(email) else {
            throw AuthError.invalidEmail
        }
        
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            return User(from: result.user)
        } catch {
            throw mapFirebaseError(error)
        }
    }
    
    func signUp(email: String, password: String) async throws -> User {
        // バリデーション
        guard !email.isEmpty, !password.isEmpty else {
            throw AuthError.invalidInput
        }
        
        guard isValidEmail(email) else {
            throw AuthError.invalidEmail
        }
        
        guard password.count >= 6 else {
            throw AuthError.weakPassword
        }
        
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            return User(from: result.user)
        } catch {
            throw mapFirebaseError(error)
        }
    }
    
    func signOut() async throws {
        do {
            try Auth.auth().signOut()
        } catch {
            throw mapFirebaseError(error)
        }
    }
    
    // MARK: - Helper Methods
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
    
    private func mapFirebaseError(_ error: Error) -> AuthError {
        if let authError = error as NSError? {
            switch authError.code {
            case 17007: // Email already in use
                return .emailAlreadyInUse
            case 17008: // Invalid email
                return .invalidEmail
            case 17009: // Wrong password
                return .wrongPassword
            case 17010: // User not found
                return .userNotFound
            case 17011: // Weak password
                return .weakPassword
            case 17020: // Network error
                return .networkError
            default:
                return .unknown(error.localizedDescription)
            }
        }
        return .unknown(error.localizedDescription)
    }
}

// MARK: - AuthError

enum AuthError: LocalizedError {
    case invalidInput
    case invalidEmail
    case weakPassword
    case emailAlreadyInUse
    case wrongPassword
    case userNotFound
    case networkError
    case unknown(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "メールアドレスとパスワードを入力してください"
        case .invalidEmail:
            return "有効なメールアドレスを入力してください"
        case .weakPassword:
            return "パスワードは6文字以上で入力してください"
        case .emailAlreadyInUse:
            return "このメールアドレスは既に使用されています"
        case .wrongPassword:
            return "メールアドレスまたはパスワードが正しくありません"
        case .userNotFound:
            return "このメールアドレスのアカウントが見つかりません"
        case .networkError:
            return "ネットワークエラーが発生しました。接続を確認してください"
        case .unknown(let message):
            return message
        }
    }
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


