// ⭐️ RecipeStore.swift
// EditRecipe のローカル JSON 永続化（サイドカーファイル方式）
//
//  RecipeStore.swift
//  Soramoyou
//

import Foundation

/// EditRecipe をアプリ内 JSON ファイルとして永続化するストア
///
/// 保存先: `Documents/recipes/<id>.json`
///
/// Firestore を使わない場合（オフライン下書きなど）の保存先として機能する。
/// `schemaVersion` によるマイグレーション対応。
final class RecipeStore {

    // MARK: - Properties

    private let recipesDirectory: URL

    // MARK: - Init

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.recipesDirectory = docs.appendingPathComponent("recipes", isDirectory: true)

        // レシピディレクトリを作成（存在しない場合）
        try? FileManager.default.createDirectory(
            at: recipesDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - 保存

    /// レシピを JSON ファイルとして保存する
    ///
    /// - Parameters:
    ///   - recipe: 保存するレシピ
    ///   - id: 識別子（投稿ID・下書き ID を推奨）
    func save(_ recipe: EditRecipe, id: String) throws {
        var mutableRecipe = recipe
        mutableRecipe.lastModifiedAt = Date()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting     = [.prettyPrinted, .sortedKeys]

        let data    = try encoder.encode(mutableRecipe)
        let fileURL = url(for: id)
        try data.write(to: fileURL, options: .atomicWrite)
    }

    // MARK: - 読み込み

    /// レシピを JSON ファイルから読み込む
    ///
    /// - Parameter id: 識別子
    /// - Returns: 読み込んだレシピ（マイグレーション適用済み）
    func load(id: String) throws -> EditRecipe {
        let fileURL = url(for: id)
        let data    = try Data(contentsOf: fileURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let recipe = try decoder.decode(EditRecipe.self, from: data)
        return migrate(recipe)
    }

    // MARK: - 削除

    /// レシピファイルを削除する
    ///
    /// - Parameter id: 識別子
    func delete(id: String) throws {
        try FileManager.default.removeItem(at: url(for: id))
    }

    // MARK: - 一覧

    /// 保存済みレシピの ID 一覧を返す
    var allIDs: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: recipesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .map    { $0.deletingPathExtension().lastPathComponent }
    }

    // MARK: - Private

    private func url(for id: String) -> URL {
        recipesDirectory.appendingPathComponent("\(id).json")
    }

    /// スキーマバージョンに基づくマイグレーション
    private func migrate(_ recipe: EditRecipe) -> EditRecipe {
        var migrated = recipe

        // 例: schemaVersion 1 → 2 のマイグレーション
        // if migrated.schemaVersion < 2 {
        //     migrated.newField = defaultValue
        //     migrated.schemaVersion = 2
        // }

        return migrated
    }
}
