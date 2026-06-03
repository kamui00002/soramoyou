// ⭐️ RecipeCorpusStore.swift
// パーソナルAI編集の学習コーパス（ユーザー別ローカル永続化）
//
//  RecipeCorpusStore.swift
//  Soramoyou
//

import Foundation

/// ユーザー自身の確定編集レシピ（`RecipeCorpusEntry`）をローカルに蓄積するストア。
///
/// 保存先: `Documents/recipes/corpus/<userId>.json`（ユーザー別の配列 JSON）
///
/// 設計方針:
/// - パーソナルAI編集（柱1）の学習データ基盤。投稿/保存の確定時に `append` する。
/// - **端末内完結**（プライバシー）。サーバーへは送らない。
/// - 古いエントリは `capacity` 件まで保持（直近を優先）。無限肥大を防ぐ。
/// - `baseDirectory` を注入可能にし、単体テストで一時ディレクトリを使えるようにする。
final class RecipeCorpusStore {

    // MARK: - Properties

    private let corpusDirectory: URL
    private let capacity: Int

    // MARK: - Init

    /// - Parameters:
    ///   - baseDirectory: 保存ルート（既定: アプリの Documents）。テスト時に差し替える。
    ///   - capacity: 保持する最大エントリ数（既定 300。超過分は古い順に破棄）。
    init(baseDirectory: URL? = nil, capacity: Int = 300) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.corpusDirectory = base.appendingPathComponent("recipes/corpus", isDirectory: true)
        self.capacity = max(1, capacity)

        try? FileManager.default.createDirectory(
            at: corpusDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - 読み込み

    /// ユーザーの全エントリを返す（古い順）。ファイル無し・壊れている場合は空配列。
    func entries(userId: String) -> [RecipeCorpusEntry] {
        guard let data = try? Data(contentsOf: url(for: userId)) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 壊れた JSON はクラッシュさせず空扱い（学習データは欠損しても致命的でない）。
        return (try? decoder.decode([RecipeCorpusEntry].self, from: data)) ?? []
    }

    // MARK: - 追記

    /// エントリを 1 件追記し、容量超過分を古い順に破棄して保存する。
    /// - Returns: 保存後の全エントリ（古い順）。
    @discardableResult
    func append(_ entry: RecipeCorpusEntry, userId: String) -> [RecipeCorpusEntry] {
        var all = entries(userId: userId)
        all.append(entry)
        if all.count > capacity {
            all = Array(all.suffix(capacity))
        }
        save(all, userId: userId)
        return all
    }

    // MARK: - 削除

    /// ユーザーのコーパスファイルを削除する（主にテスト・アカウント削除時）。
    func clear(userId: String) {
        try? FileManager.default.removeItem(at: url(for: userId))
    }

    // MARK: - Private

    private func save(_ entries: [RecipeCorpusEntry], userId: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url(for: userId), options: .atomicWrite)
    }

    /// ユーザー ID をファイル名に安全化して保存先 URL を返す。
    private func url(for userId: String) -> URL {
        let safe = userId.replacingOccurrences(of: "/", with: "_")
        return corpusDirectory.appendingPathComponent("\(safe).json")
    }
}
