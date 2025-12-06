//
//  SoramoyouApp.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import FirebaseCore

@main
struct SoramoyouApp: App {
    @StateObject private var authViewModel = AuthViewModel()
    
    init() {
        // Firebase初期化
        FirebaseApp.configure()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authViewModel)
        }
    }
}

