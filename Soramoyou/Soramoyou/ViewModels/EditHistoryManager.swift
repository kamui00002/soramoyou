// ⭐️ EditHistoryManager.swift
// 編集履歴管理（Undo/Redo）
//
//  EditHistoryManager.swift
//  Soramoyou
//

import Foundation

// MARK: - EditorSnapshot

/// 編集画面の完全な状態スナップショット
///
/// EditRecipe（色調整・フィルター）と変形状態（回転・反転・クロップ）を
/// 一体として保持することで、Undo/Redo が全操作を正しく復元できる。
struct EditorSnapshot: Equatable {
    let recipe:             EditRecipe
    let rotationDegrees:    Double
    let isFlippedHorizontal: Bool
    let isFlippedVertical:  Bool
    let cropAspectRatio:    CropAspectRatio
}

// MARK: - EditHistoryManager

/// EditorSnapshot を値コピーで積む履歴マネージャー
///
/// 設計方針:
/// - undoStack: 「前の状態」を積む（Undo するとここから取り出す）
/// - redoStack: 「Undo で戻った状態を再適用するための次の状態」を積む
/// - 新規変更時に redoStack を全クリア（分岐履歴は持たない）
/// - maxSize で履歴数を上限管理（デフォルト 50）
final class EditHistoryManager {

    // MARK: - Properties

    private(set) var undoStack: [EditorSnapshot] = []
    private(set) var redoStack: [EditorSnapshot] = []

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
    /// - Parameter snapshot: 変更前の EditorSnapshot（現在の状態）
    func push(_ snapshot: EditorSnapshot) {
        undoStack.append(snapshot)
        if undoStack.count > maxSize {
            undoStack.removeFirst()
        }
        // 新規変更で Redo スタックをクリア（分岐履歴は持たない）
        redoStack.removeAll()
    }

    /// Undo: 直前の状態に戻す
    ///
    /// - Parameter current: 現在の EditorSnapshot（Redo のために保存される）
    /// - Returns: 戻すべき EditorSnapshot、スタックが空なら nil
    func undo(current: EditorSnapshot) -> EditorSnapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    /// Redo: Undo した変更を再適用する
    ///
    /// - Parameter current: 現在の EditorSnapshot（Undo のために保存される）
    /// - Returns: 再適用すべき EditorSnapshot、スタックが空なら nil
    func redo(current: EditorSnapshot) -> EditorSnapshot? {
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
