//
//  SearchView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import Kingfisher

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @State private var selectedPost: Post?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    // 検索条件セクション
                    searchCriteriaSection
                    
                    Divider()
                    
                    // 検索結果セクション
                    searchResultsSection
                }
                
                // 画面下部に固定表示されるバナー広告
                BannerAdContainer()
            }
            .navigationTitle("検索")
            .alert("エラー", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                }
            }
            .sheet(item: $selectedPost) { post in
                PostDetailView(post: post)
            }
        }
    }
    
    // MARK: - Search Criteria Section
    
    private var searchCriteriaSection: some View {
        ScrollView {
            VStack(spacing: 24) {
                // ハッシュタグ入力
                hashtagInputSection
                
                // 色選択
                colorSelectionSection
                
                // 時間帯選択
                timeOfDaySelectionSection
                
                // 空の種類選択
                skyTypeSelectionSection
                
                // 検索ボタン
                searchButton
            }
            .padding()
        }
    }
    
    // MARK: - Hashtag Input Section
    
    private var hashtagInputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ハッシュタグ")
                .font(.headline)
            
            HStack {
                TextField("ハッシュタグを入力（#なし）", text: $viewModel.hashtag)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit {
                        Task {
                            await viewModel.performSearch()
                        }
                    }
                
                if !viewModel.hashtag.isEmpty {
                    Button(action: {
                        viewModel.hashtag = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }
    
    // MARK: - Color Selection Section
    
    private var colorSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("色")
                .font(.headline)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    // 色の選択肢（主要な色）
                    let colors: [(name: String, hex: String)] = [
                        ("青", "#0000FF"),
                        ("赤", "#FF0000"),
                        ("緑", "#00FF00"),
                        ("黄", "#FFFF00"),
                        ("紫", "#800080"),
                        ("オレンジ", "#FFA500"),
                        ("ピンク", "#FFC0CB"),
                        ("シアン", "#00FFFF")
                    ]
                    
                    ForEach(colors, id: \.hex) { color in
                        ColorSelectionButton(
                            name: color.name,
                            hex: color.hex,
                            isSelected: viewModel.selectedColor == color.hex,
                            action: {
                                if viewModel.selectedColor == color.hex {
                                    viewModel.selectedColor = nil
                                } else {
                                    Task {
                                        await viewModel.searchByColor(color.hex)
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }
            
            if let selectedColor = viewModel.selectedColor {
                HStack {
                    Circle()
                        .fill(hexToColor(selectedColor))
                        .frame(width: 20, height: 20)
                    Text("選択中: \(selectedColor)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button("クリア") {
                        viewModel.selectedColor = nil
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
            }
        }
    }
    
    // MARK: - Time Of Day Selection Section
    
    private var timeOfDaySelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("時間帯")
                .font(.headline)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(TimeOfDay.allCases, id: \.self) { timeOfDay in
                        FilterChip(
                            title: timeOfDay.displayName,
                            isSelected: viewModel.selectedTimeOfDay == timeOfDay,
                            action: {
                                if viewModel.selectedTimeOfDay == timeOfDay {
                                    viewModel.selectedTimeOfDay = nil
                                } else {
                                    Task {
                                        await viewModel.searchByTimeOfDay(timeOfDay)
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
    }
    
    // MARK: - Sky Type Selection Section
    
    private var skyTypeSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("空の種類")
                .font(.headline)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(SkyType.allCases, id: \.self) { skyType in
                        FilterChip(
                            title: skyType.displayName,
                            isSelected: viewModel.selectedSkyType == skyType,
                            action: {
                                if viewModel.selectedSkyType == skyType {
                                    viewModel.selectedSkyType = nil
                                } else {
                                    Task {
                                        await viewModel.searchBySkyType(skyType)
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
    }
    
    // MARK: - Search Button
    
    private var searchButton: some View {
        VStack(spacing: 12) {
            Button(action: {
                Task {
                    await viewModel.performSearch()
                }
            }) {
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(viewModel.isLoading ? "検索中..." : "検索")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(viewModel.isLoading ? Color.gray : Color.blue)
                .cornerRadius(12)
            }
            .disabled(viewModel.isLoading || !viewModel.hasSearchCriteria)
            
            if viewModel.hasSearchCriteria {
                Button(action: {
                    viewModel.clearSearch()
                }) {
                    Text("検索条件をクリア")
                        .font(.body)
                        .foregroundColor(.red)
                }
            }
        }
    }
    
    // MARK: - Search Results Section
    
    private var searchResultsSection: some View {
        Group {
            if viewModel.isLoading && viewModel.searchResults.isEmpty {
                ProgressView("検索中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.searchResults.isEmpty && viewModel.hasSearchCriteria {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("検索結果がありません")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.searchResults.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(viewModel.searchResults) { post in
                            PostCard(post: post)
                                .onTapGesture {
                                    selectedPost = post
                                }
                        }
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("検索条件を入力してください")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func hexToColor(_ hex: String) -> Color {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Color Selection Button

struct ColorSelectionButton: View {
    let name: String
    let hex: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Circle()
                    .fill(hexToColor(hex))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: isSelected ? 3 : 1)
                    )
                
                Text(name)
                    .font(.caption)
                    .foregroundColor(isSelected ? .blue : .primary)
            }
        }
    }
    
    private func hexToColor(_ hex: String) -> Color {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.blue : Color.gray.opacity(0.2))
                .cornerRadius(20)
        }
    }
}

struct SearchView_Previews: PreviewProvider {
    static var previews: some View {
        SearchView()
    }
}


