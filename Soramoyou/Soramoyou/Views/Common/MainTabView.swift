//
//  MainTabView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import UIKit

struct MainTabView: View {
    @State private var selectedTab: Tab = .home
    
    enum Tab: Int {
        case home = 0
        case post = 1
        case gallery = 2
        case search = 3
        case profile = 4

        var title: String {
            switch self {
            case .home: return "ホーム"
            case .post: return "投稿"
            case .gallery: return "ギャラリー"
            case .search: return "検索"
            case .profile: return "プロフィール"
            }
        }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .post: return "plus.circle.fill"
            case .gallery: return "photo.on.rectangle.angled"
            case .search: return "magnifyingglass"
            case .profile: return "person.fill"
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label(Tab.home.title, systemImage: Tab.home.icon)
                }
                .tag(Tab.home)
            
            PostView()
                .tabItem {
                    Label(Tab.post.title, systemImage: Tab.post.icon)
                }
                .tag(Tab.post)

            GalleryView()
                .tabItem {
                    Label(Tab.gallery.title, systemImage: Tab.gallery.icon)
                }
                .tag(Tab.gallery)

            SearchView()
                .tabItem {
                    Label(Tab.search.title, systemImage: Tab.search.icon)
                }
                .tag(Tab.search)
            
            ProfileView()
                .tabItem {
                    Label(Tab.profile.title, systemImage: Tab.profile.icon)
                }
                .tag(Tab.profile)
        }
        .onAppear {
            // タブバーの外観をカスタマイズ
            setupTabBarAppearance()
        }
    }
    
    // MARK: - Tab Bar Appearance
    
    private func setupTabBarAppearance() {
        // iOS 15以降でタブバーの外観をカスタマイズ
        if #available(iOS 15.0, *) {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            
            // 選択されていないタブの色
            appearance.stackedLayoutAppearance.normal.iconColor = UIColor.secondaryLabel
            appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
                .foregroundColor: UIColor.secondaryLabel
            ]
            
            // 選択されているタブの色
            appearance.stackedLayoutAppearance.selected.iconColor = UIColor.systemBlue
            appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
                .foregroundColor: UIColor.systemBlue
            ]
            
            // 背景色
            appearance.backgroundColor = UIColor.systemBackground
            
            UITabBar.appearance().standardAppearance = appearance
            if #available(iOS 15.0, *) {
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
            .environmentObject(AuthViewModel())
    }
}


