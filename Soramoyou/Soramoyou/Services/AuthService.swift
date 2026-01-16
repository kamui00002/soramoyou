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
    func signInAnonymously() async throws -> User
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

    func signInAnonymously() async throws -> User {
        do {
            let result = try await Auth.auth().signInAnonymously()
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
    
    // MARK: - Helper Methods
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
    
    private func mapFirebaseError(_ error: Error) -> AuthError {
        // Firebase AuthErrorCode列挙型を使用（数値コードより安全で保守性が高い）
        let nsError = error as NSError
        guard nsError.domain == AuthErrorDomain,
              let errorCode = AuthErrorCode(rawValue: nsError.code) else {
            return .unknown(error.localizedDescription)
        }

        switch errorCode {
        case .emailAlreadyInUse:
            return .emailAlreadyInUse
        case .invalidEmail:
            return .invalidEmail
        case .wrongPassword:
            return .wrongPassword
        case .userNotFound:
            return .userNotFound
        case .weakPassword:
            return .weakPassword
        case .networkError:
            return .networkError
        case .invalidCredential:
            // iOS 17以降、wrongPasswordとuserNotFoundはinvalidCredentialに統合
            return .wrongPassword
        case .tooManyRequests:
            return .tooManyRequests
        default:
            return .unknown(error.localizedDescription)
        }
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
    case tooManyRequests
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
        case .tooManyRequests:
            return "リクエストが多すぎます。しばらく待ってから再試行してください"
        case .unknown(let message):
            return message
        }
    }
}
