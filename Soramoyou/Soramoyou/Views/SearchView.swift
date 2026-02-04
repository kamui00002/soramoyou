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
            ZStack {
                // 空のグラデーション背景
                LinearGradient(
                    colors: [
                        Color(red: 0.68, green: 0.85, blue: 0.90),
                        Color(red: 0.53, green: 0.81, blue: 0.98),
                        Color(red: 0.39, green: 0.58, blue: 0.93)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 検索条件セクション
                    searchCriteriaSection

                    Divider()
                        .background(.white.opacity(0.3))

                    // 検索結果セクション（検索条件がある場合のみ表示）
                    if viewModel.hasSearchCriteria || viewModel.isLoading || !viewModel.searchResults.isEmpty {
                        searchResultsSection
                    }

                    // バナー広告
                    BannerAdContainer()
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    GradientTitleView(title: "検索", fontSize: 20)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .alert("エラー", isPresented: Binding(errorMessage: $viewModel.errorMessage)) {
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
            VStack(spacing: 16) {
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
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
    
    // MARK: - Hashtag Input Section

    private var hashtagInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ハッシュタグ")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            
            HStack {
                TextField("ハッシュタグを入力（#なし）", text: $viewModel.hashtag)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.white.opacity(0.2))
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.white.opacity(0.4), lineWidth: 1)
                            )
                    )
                    .foregroundColor(.white)
                    .onSubmit {
                        guard viewModel.hasSearchCriteria else { return }
                        Task {
                            await viewModel.performSearch()
                        }
                    }
                
                if !viewModel.hashtag.isEmpty {
                    Button(action: {
                        viewModel.hashtag = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(DesignTokens.Colors.textTertiary)
                    }
                }
            }
        }
    }
    
    // MARK: - Color Selection Section

    private var colorSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("色")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            
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
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                    
                    Button("クリア") {
                        viewModel.selectedColor = nil
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                }
            }
        }
    }
    
    // MARK: - Time Of Day Selection Section

    private var timeOfDaySelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("時間帯")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            
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
        VStack(alignment: .leading, spacing: 8) {
            Text("空の種類")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            
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
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(viewModel.isLoading || !viewModel.hasSearchCriteria ? 0.15 : 0.25))
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(.white.opacity(0.4), lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
            }
            .disabled(viewModel.isLoading || !viewModel.hasSearchCriteria)
            
            if viewModel.hasSearchCriteria {
                Button(action: {
                    viewModel.clearSearch()
                }) {
                    Text("検索条件をクリア")
                        .font(.body)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
            } else {
                Text("検索条件を入力してください")
                    .font(.caption)
                    .foregroundColor(DesignTokens.Colors.textTertiary)
            }
        }
    }

    // MARK: - Search Results Section
    
    // MARK: - Search Results Section ☁️

    private var searchResultsSection: some View {
        Group {
            if viewModel.isLoading && viewModel.searchResults.isEmpty {
                // 検索中 ☁️
                LoadingStateView(type: .custom(message: "検索中..."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.searchResults.isEmpty && viewModel.hasSearchCriteria {
                // 検索結果がない場合 ☁️
                EmptyStateView(type: .searchResults) {
                    viewModel.clearSearch()
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
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        }) {
            VStack(spacing: 6) {
                ZStack {
                    // グロー効果（選択時）
                    if isSelected {
                        Circle()
                            .fill(hexToColor(hex).opacity(0.4))
                            .frame(width: 50, height: 50)
                            .blur(radius: 8)
                    }

                    Circle()
                        .fill(hexToColor(hex))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Circle()
                                .stroke(
                                    isSelected ? Color.white : Color.white.opacity(0.3),
                                    lineWidth: isSelected ? 3 : 1
                                )
                        )
                        .shadow(isSelected ? DesignTokens.Shadow.medium : DesignTokens.Shadow.soft)
                }
                .frame(width: 50, height: 50)

                Text(name)
                    .font(.system(size: DesignTokens.Typography.smallCaptionSize, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.1 : 1.0)
        .animation(DesignTokens.Animation.bouncySpring, value: isSelected)
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
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        }) {
            Text(title)
                .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium, design: .rounded))
                .foregroundColor(isSelected ? .white : DesignTokens.Colors.textSecondary)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(
                    ZStack {
                        Capsule()
                            .fill(isSelected ? DesignTokens.Colors.selectionAccent : DesignTokens.Colors.glassTertiary)

                        Capsule()
                            .stroke(
                                isSelected
                                    ? Color.white.opacity(0.3)
                                    : DesignTokens.Colors.glassBorderSecondary,
                                lineWidth: 1
                            )
                    }
                )
                .shadow(isSelected ? DesignTokens.Shadow.soft : DesignTokens.Shadow.inner)
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(DesignTokens.Animation.quickSpring, value: isSelected)
    }
}

struct SearchView_Previews: PreviewProvider {
    static var previews: some View {
        SearchView()
    }
}

