//
//  GalleryViewModel.swift
//  Soramoyou
//
//  Created on 2025-01-19.
//
//  ギャラリー画面用ViewModel ⭐️
//  PaginatedPostsViewModelを継承し、グリッド表示に最適化された設定を提供
//  探索ヘッダー（絞り込み・並び替え・色で探す・シャッフル）に対応する。

import Foundation
import FirebaseFirestore
import Combine

/// ギャラリーの並び替え順
///
/// Firestore の `order(by:)` に渡すフィールド名を提供する。
enum GallerySortOrder {
    /// 新着順（createdAt 降順）
    case newest
    /// 人気順（likesCount 降順）
    case popular

    /// Firestore の並び替えフィールド名
    var sortField: String {
        switch self {
        case .newest: return "createdAt"
        case .popular: return "likesCount"
        }
    }
}

/// ギャラリーの写真配置レイアウト
enum GalleryLayoutMode {
    /// 正方形グリッド（従来）
    case grid
    /// 写真の縦横比そのままのモザイク（Pinterest 風）
    case mosaic
}

/// ギャラリー画面のViewModel
///
/// PaginatedPostsViewModelを継承し、グリッド表示に特化した設定を提供する。
/// ページサイズをホームより多め（30件）に設定してグリッド表示に最適化。
///
/// 探索ヘッダーの状態（時間帯・空の種類・並び替え・色・シャッフル）を保持し、
/// `executeQuery` を分岐させて絞り込み／並び替え／色検索を行う。
@MainActor
class GalleryViewModel: PaginatedPostsViewModel {
    // MARK: - 探索ヘッダーの状態

    /// 絞り込み: 時間帯（nil=すべて）
    @Published var selectedTimeOfDay: TimeOfDay?
    /// 絞り込み: 空の種類（nil=すべて）
    @Published var selectedSkyType: SkyType?
    /// 並び替え順（既定: 新着）
    @Published var sortOrder: GallerySortOrder = .newest
    /// 色で探す: 選択中の16進カラーコード（nil=色モードOFF）
    @Published var selectedColor: String?
    /// 表示順をシャッフルしているか
    @Published var isShuffled: Bool = false
    /// 写真配置レイアウト（グリッド/モザイク）
    @Published var layoutMode: GalleryLayoutMode = .grid

    /// 色検索の RGB 距離しきい値（SearchView と同じ既定値）
    private let colorThreshold: Double = 0.3

    // MARK: - PaginatedPostsViewModel Overrides

    /// ViewModel名（エラーログ用）
    override var viewModelName: String { "GalleryViewModel" }

    /// グリッド表示用に多めに取得（30件/ページ）
    override var pageSize: Int { 30 }

    /// ブロックしているユーザーIDのリスト
    private var blockedUserIds: [String] = []

    // MARK: - 探索状態の派生プロパティ

    /// 時間帯・空の種類のいずれかで絞り込み中か
    var hasActiveFilter: Bool {
        selectedTimeOfDay != nil || selectedSkyType != nil
    }

    /// 色で探すモードか
    var isColorMode: Bool {
        selectedColor != nil
    }

    /// 実際に適用される並び替え順
    ///
    /// 時間帯／空の種類で絞り込み中は「新着」に固定する。
    /// 「絞り込み × 人気順」の複合インデックス増殖を避けるための設計上の割り切り。
    var effectiveSortOrder: GallerySortOrder {
        hasActiveFilter ? .newest : sortOrder
    }

    // MARK: - Fetch Overrides

    /// 投稿を取得（ブロックユーザーのフィルタリング付き）
    override func fetchPosts() async {
        await loadBlockedUsers()
        await super.fetchPosts()
        filterBlockedUsers()
        // 色で探すモードは単発取得のため、追加読み込みを無効化する
        if isColorMode {
            hasMorePosts = false
        }
        // シャッフルON時は初回ページを並べ替える
        if isShuffled {
            posts.shuffle()
        }
    }

    /// 次のページの投稿を取得（ブロックユーザーのフィルタリング付き）
    override func loadMorePosts() async {
        // 色で探すモードはページングしない（searchByColor は一括取得）
        guard !isColorMode else { return }

        let previousCount = posts.count
        await super.loadMorePosts()
        filterBlockedUsers()

        // シャッフルON時は「新しく追加された分だけ」を並べ替える。
        // 既存表示分の順序を保つことで、スクロール中に見た写真が飛び回るのを防ぐ。
        if isShuffled && posts.count > previousCount {
            let appended = Array(posts[previousCount...]).shuffled()
            posts.replaceSubrange(previousCount..., with: appended)
        }
    }

    // MARK: - 探索操作（View から呼ぶ）

    /// 時間帯で絞り込む（同じ値の再選択で解除）
    func selectTimeOfDay(_ timeOfDay: TimeOfDay?) async {
        selectedTimeOfDay = (selectedTimeOfDay == timeOfDay) ? nil : timeOfDay
        // 色モードとは排他（色で探す状態は解除する）
        selectedColor = nil
        // 絞り込み中の並び替えは effectiveSortOrder が新着に固定するため、ユーザー選択の
        // sortOrder 自体は書き換えない（絞り込み解除後に元の並び順を復元するため／レビュー F5）
        LoggingService.shared.logEvent(
            "gallery_filter_selected",
            parameters: ["filter_type": "time_of_day", "value": selectedTimeOfDay?.rawValue ?? "cleared"]
        )
        await fetchPosts()
    }

    /// 空の種類で絞り込む（同じ値の再選択で解除）
    func selectSkyType(_ skyType: SkyType?) async {
        selectedSkyType = (selectedSkyType == skyType) ? nil : skyType
        selectedColor = nil
        LoggingService.shared.logEvent(
            "gallery_filter_selected",
            parameters: ["filter_type": "sky_type", "value": selectedSkyType?.rawValue ?? "cleared"]
        )
        await fetchPosts()
    }

    /// 並び替え順を変更する
    func setSortOrder(_ order: GallerySortOrder) async {
        // 絞り込み中は人気順に切り替えられない（新着固定）
        if order == .popular && hasActiveFilter { return }
        sortOrder = order
        // 並び替えは通常モード。色モードを抜ける
        selectedColor = nil
        LoggingService.shared.logEvent(
            "gallery_sort_changed",
            parameters: ["sort": order == .popular ? "popular" : "newest"]
        )
        await fetchPosts()
    }

    /// 色で探す（同じ色の再選択で解除）。色モードは絞り込み・並び替えと排他。
    func selectColor(_ color: String?) async {
        selectedColor = (selectedColor == color) ? nil : color
        if isColorMode {
            selectedTimeOfDay = nil
            selectedSkyType = nil
            sortOrder = .newest
        }
        LoggingService.shared.logEvent(
            "gallery_color_searched",
            parameters: ["color": selectedColor ?? "cleared"]
        )
        await fetchPosts()
    }

    /// 表示順シャッフルを切り替える
    func toggleShuffle() async {
        isShuffled.toggle()
        LoggingService.shared.logEvent(
            "gallery_shuffle_toggled",
            parameters: ["state": isShuffled ? "on" : "off"]
        )
        if isShuffled {
            // ON: 取得済みの投稿をその場でシャッフル（再取得不要）
            posts.shuffle()
        } else {
            // OFF: 元の並び順に戻すため再取得する
            await fetchPosts()
        }
    }

    /// 表示レイアウト（グリッド/モザイク）を切り替える
    func toggleLayoutMode() {
        layoutMode = (layoutMode == .grid) ? .mosaic : .grid
        LoggingService.shared.logEvent(
            "gallery_layout_toggled",
            parameters: ["mode": layoutMode == .mosaic ? "mosaic" : "grid"]
        )
    }

    // MARK: - Query Hook

    /// Firestore クエリを実行する（探索状態に応じて分岐）
    ///
    /// - 色モード: `searchByColor` で一括取得（ページング無効）
    /// - 通常: 時間帯／空の種類フィルタ ＋ 並び替え ＋ ページング
    override func executeQuery(lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        // 色で探すモード: SearchView と同じ一括取得方式。
        // RGB 距離のクライアント側フィルタで件数が減りページング判定を壊すため、
        // 2ページ目以降は取得しない（空を返してページング終了）。
        if let color = selectedColor {
            if lastDocument != nil {
                return (posts: [], lastDocument: nil)
            }
            let colorPosts = try await firestoreService.searchByColor(color, threshold: colorThreshold)
            return (posts: colorPosts, lastDocument: nil)
        }

        // 通常モード: フィルタ＋並び替え＋ページング
        return try await firestoreService.fetchPostsWithSnapshot(
            timeOfDay: selectedTimeOfDay,
            skyType: selectedSkyType,
            sortField: effectiveSortOrder.sortField,
            limit: pageSize,
            lastDocument: lastDocument
        )
    }

    // MARK: - ブロックユーザー処理

    /// ブロックユーザーリストを読み込む
    private func loadBlockedUsers() async {
        let authService = AuthService()
        guard let currentUserId = authService.currentUser()?.id else { return }

        do {
            blockedUserIds = try await firestoreService.fetchBlockedUserIds(userId: currentUserId)
        } catch {
            blockedUserIds = []
        }
    }

    /// ブロックユーザーの投稿をフィルタリング
    private func filterBlockedUsers() {
        guard !blockedUserIds.isEmpty else { return }
        posts = posts.filter { !blockedUserIds.contains($0.userId) }
    }

    /// 投稿をローカル一覧から削除する（削除完了後のUI更新用）
    func removePost(postId: String) {
        posts.removeAll { $0.id == postId }
    }
}
