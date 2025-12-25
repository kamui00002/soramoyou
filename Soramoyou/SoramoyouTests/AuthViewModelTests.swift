//
//  AuthViewModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import XCTest
@testable import Soramoyou
import Combine

@MainActor
final class AuthViewModelTests: XCTestCase {
    var viewModel: AuthViewModel!
    var mockAuthService: MockAuthService!
    
    override func setUp() {
        super.setUp()
        mockAuthService = MockAuthService()
        viewModel = AuthViewModel(authService: mockAuthService)
    }
    
    override func tearDown() {
        viewModel = nil
        mockAuthService = nil
        super.tearDown()
    }
    
    func testInitialState() {
        // Then
        XCTAssertFalse(viewModel.isAuthenticated)
        XCTAssertNil(viewModel.currentUser)
        XCTAssertNil(viewModel.errorMessage)
    }
    
    func testSignInSuccess() async throws {
        // Given
        let testUser = User(id: "test-id", email: "test@example.com", displayName: "Test User")
        mockAuthService.signInResult = .success(testUser)
        
        // When
        try await viewModel.signIn(email: "test@example.com", password: "password123")
        
        // Then
        XCTAssertTrue(viewModel.isAuthenticated)
        XCTAssertNotNil(viewModel.currentUser)
        XCTAssertEqual(viewModel.currentUser?.id, "test-id")
        XCTAssertEqual(viewModel.currentUser?.email, "test@example.com")
    }
    
    func testSignInFailure() async {
        // Given
        let error = NSError(domain: "AuthError", code: 17007, userInfo: [NSLocalizedDescriptionKey: "Invalid email or password"])
        mockAuthService.signInResult = .failure(error)
        
        // When
        do {
            try await viewModel.signIn(email: "invalid@example.com", password: "wrong")
            XCTFail("Should have thrown an error")
        } catch {
            // Then
            XCTAssertFalse(viewModel.isAuthenticated)
            XCTAssertNil(viewModel.currentUser)
        }
    }
    
    func testSignUpSuccess() async throws {
        // Given
        let testUser = User(id: "new-user-id", email: "new@example.com", displayName: "New User")
        mockAuthService.signUpResult = .success(testUser)
        
        // When
        try await viewModel.signUp(email: "new@example.com", password: "password123")
        
        // Then
        XCTAssertTrue(viewModel.isAuthenticated)
        XCTAssertNotNil(viewModel.currentUser)
        XCTAssertEqual(viewModel.currentUser?.id, "new-user-id")
    }
    
    func testSignOut() async throws {
        // Given
        let testUser = User(id: "test-id", email: "test@example.com")
        mockAuthService.signInResult = .success(testUser)
        try await viewModel.signIn(email: "test@example.com", password: "password123")
        XCTAssertTrue(viewModel.isAuthenticated)
        
        // When
        try await viewModel.signOut()
        
        // Then
        XCTAssertFalse(viewModel.isAuthenticated)
        XCTAssertNil(viewModel.currentUser)
    }
}

// MARK: - MockAuthService

class MockAuthService: AuthServiceProtocol {
    var signInResult: Result<User, Error>?
    var signUpResult: Result<User, Error>?
    var signOutError: Error?
    var currentUserValue: User?
    
    func signIn(email: String, password: String) async throws -> User {
        if let result = signInResult {
            switch result {
            case .success(let user):
                currentUserValue = user
                return user
            case .failure(let error):
                throw error
            }
        }
        throw NSError(domain: "MockAuthService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No result set"])
    }
    
    func signUp(email: String, password: String) async throws -> User {
        if let result = signUpResult {
            switch result {
            case .success(let user):
                currentUserValue = user
                return user
            case .failure(let error):
                throw error
            }
        }
        throw NSError(domain: "MockAuthService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No result set"])
    }
    
    func signOut() async throws {
        if let error = signOutError {
            throw error
        }
        currentUserValue = nil
    }
    
    func currentUser() -> User? {
        return currentUserValue
    }
    
    func observeAuthState() -> AsyncStream<User?> {
        AsyncStream { continuation in
            continuation.yield(currentUserValue)
            continuation.finish()
        }
    }
}




