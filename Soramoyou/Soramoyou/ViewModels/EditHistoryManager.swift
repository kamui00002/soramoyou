// ⭐️ EditHistoryManager.swift
// 編集履歴管理（Undo/Redo）
//
//  EditHistoryManager.swift
//  Soramoyou
//

import Foundation

/// EditRecipe スナップショットを値コピーで積むシンプルな履歴マネージャー
///
/// 設計方針:
/// - EditRecipe が immutable struct なので、値コピーで安全に履歴を積める
/// - undoStack: 「前の状態」を積む（Undo するとここから取り出す）
/// - redoStack: 「Undo で戻った状態を再適用するための次の状態」を積む
/// - 新規変更時に redoStack を全クリア（分岐履歴は持たない）
/// - maxSize で履歴数を上限管理（デフォルト 50）
final class EditHistoryManager {

    // MARK: - Properties

    private(set) var undoStack: [EditRecipe] = []
    private(set) var redoStack: [EditRecipe] = []

    /// 最大履歴数（超えた分は先頭から削除）
    let maxSize: Int

    // MARK: - Init

    init(maxSize: Int = 50) {
        self.maxSize = maxSize
    }

    // MARK: - 状態クエリ

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - 履歴操作

    /// 現在の状態を Undo スタックに積む（新規変更前に呼ぶ）
    ///
    /// - Parameter recipe: 変更前の EditRecipe（現在の状態）
    func push(_ recipe: EditRecipe) {
        undoStack.append(recipe)
        if undoStack.count > maxSize {
            undoStack.removeFirst()
        }
        // 新規変更で Redo スタックをクリア（分岐履歴は持たない）
        redoStack.removeAll()
    }

    /// Undo: 直前の状態に戻す
    ///
    /// - Parameter current: 現在の EditRecipe（Redo のために保存される）
    /// - Returns: 戻すべき EditRecipe、スタックが空なら nil
    func undo(current: EditRecipe) -> EditRecipe? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    /// Redo: Undo した変更を再適用する
    ///
    /// - Parameter current: 現在の EditRecipe（Undo のために保存される）
    /// - Returns: 再適用すべき EditRecipe、スタックが空なら nil
    func redo(current: EditRecipe) -> EditRecipe? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    /// 履歴を全クリア（画像切り替え時などに使用）
    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
