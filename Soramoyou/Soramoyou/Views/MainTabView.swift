//
//  MainTabView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("ホーム", systemImage: "house.fill")
                }
            
            PostView()
                .tabItem {
                    Label("投稿", systemImage: "plus.circle.fill")
                }
            
            SearchView()
                .tabItem {
                    Label("検索", systemImage: "magnifyingglass")
                }
            
            ProfileView()
                .tabItem {
                    Label("プロフィール", systemImage: "person.fill")
                }
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}

