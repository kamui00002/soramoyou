//
//  SearchViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import Combine

@MainActor
class SearchViewModel: ObservableObject {
    @Published var searchResults: [Post] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    // 検索クエリ
    @Published var hashtag: String = ""
    @Published var selectedColor: String?
    @Published var selectedTimeOfDay: TimeOfDay?
    @Published var selectedSkyType: SkyType?
    @Published var colorThreshold: Double = 0.3 // 色検索の閾値（デフォルト0.3）
    
    private let firestoreService: FirestoreServiceProtocol
    private var activeSearchToken: UUID?
    
    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }
    
    // MARK: - Search
    
    /// 検索を実行
    func performSearch() async {
        let token = UUID()
        activeSearchToken = token
        
        let trimmedHashtag = hashtag.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHashtag = !trimmedHashtag.isEmpty
        let hasCriteria = hasHashtag || selectedColor != nil || selectedTimeOfDay != nil || selectedSkyType != nil
        
        if !hasCriteria {
            if activeSearchToken == token {
                isLoading = false
                errorMessage = nil
                searchResults = []
            }
            return
        }
        
        isLoading = true
        errorMessage = nil
        searchResults = []
        
        do {
            // 検索条件を整理
            let hashtagQuery = hasHashtag ? trimmedHashtag : nil
            let colorQuery = selectedColor
            
            // 複合検索を実行（リトライ可能）
            let results = try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.searchPosts(
                    hashtag: hashtagQuery,
                    color: colorQuery,
                    timeOfDay: self.selectedTimeOfDay,
                    skyType: self.selectedSkyType,
                    colorThreshold: colorQuery != nil ? self.colorThreshold : nil,
                    limit: 50
                )
            }
            if activeSearchToken == token {
                searchResults = results
            }
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "SearchViewModel.performSearch")
            // ユーザーフレンドリーなメッセージを表示
            if activeSearchToken == token {
                errorMessage = error.userFriendlyMessage
            }
        }
        
        if activeSearchToken == token {
            isLoading = false
        }
    }
    
    /// ハッシュタグ検索
    func searchByHashtag(_ hashtag: String) async {
        self.hashtag = hashtag.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedColor = nil
        selectedTimeOfDay = nil
        selectedSkyType = nil
        
        await performSearch()
    }
    
    /// 色検索
    func searchByColor(_ color: String, threshold: Double = 0.3) async {
        selectedColor = color
        colorThreshold = threshold
        hashtag = ""
        selectedTimeOfDay = nil
        selectedSkyType = nil
        
        await performSearch()
    }
    
    /// 時間帯検索
    func searchByTimeOfDay(_ timeOfDay: TimeOfDay) async {
        selectedTimeOfDay = timeOfDay
        hashtag = ""
        selectedColor = nil
        selectedSkyType = nil
        
        await performSearch()
    }
    
    /// 空の種類検索
    func searchBySkyType(_ skyType: SkyType) async {
        selectedSkyType = skyType
        hashtag = ""
        selectedColor = nil
        selectedTimeOfDay = nil
        
        await performSearch()
    }
    
    /// 検索条件をクリア
    func clearSearch() {
        hashtag = ""
        selectedColor = nil
        selectedTimeOfDay = nil
        selectedSkyType = nil
        searchResults = []
        errorMessage = nil
    }
    
    /// 検索条件があるかどうか
    var hasSearchCriteria: Bool {
        !hashtag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedColor != nil
            || selectedTimeOfDay != nil
            || selectedSkyType != nil
    }
}
