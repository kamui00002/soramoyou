//
//  EditToolsSettingsView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct EditToolsSettingsView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                // 選択状況の表示
                Section(header: Text("選択状況")) {
                    HStack {
                        Text("選択数")
                        Spacer()
                        Text("\(viewModel.selectedTools.count) / \(viewModel.maxEditTools)")
                            .foregroundColor(selectionCountColor)
                    }
                    
                    if !viewModel.isValidEditToolsSelection {
                        Text("編集装備は5個から8個まで選択してください")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                
                // 選択されたツール（ドラッグ&ドロップ可能）
                Section(header: Text("選択された編集装備（ドラッグで順序変更）")) {
                    if viewModel.selectedTools.isEmpty {
                        Text("編集装備を選択してください")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.selectedTools, id: \.self) { tool in
                            EditToolRow(
                                tool: tool,
                                isSelected: true,
                                canRemove: viewModel.selectedTools.count > viewModel.minEditTools,
                                onToggle: {
                                    viewModel.removeEditTool(tool)
                                }
                            )
                        }
                        .onMove(perform: viewModel.moveEditTool)
                    }
                }
                
                // 利用可能なツール一覧
                Section(header: Text("利用可能な編集装備")) {
                    let availableTools = viewModel.availableTools.filter { tool in
                        !viewModel.selectedTools.contains(tool)
                    }
                    
                    if availableTools.isEmpty {
                        Text("すべての編集装備が選択されています")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(availableTools, id: \.self) { tool in
                            EditToolRow(
                                tool: tool,
                                isSelected: false,
                                canRemove: false,
                                onToggle: {
                                    if viewModel.selectedTools.count < viewModel.maxEditTools {
                                        viewModel.addEditTool(tool)
                                    }
                                }
                            )
                            .disabled(viewModel.selectedTools.count >= viewModel.maxEditTools)
                        }
                    }
                }
            }
            .navigationTitle("編集装備設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        // 編集内容をリセット
                        viewModel.resetEditTools()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        Task {
                            await saveEditTools()
                        }
                    }
                    .disabled(!viewModel.isValidEditToolsSelection || viewModel.isLoading)
                }
            }
            .alert("エラー", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                }
            }
            .onAppear {
                // 選択されたツールを初期化（既にProfileViewModelで設定済み）
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var selectionCountColor: Color {
        if viewModel.selectedTools.count < viewModel.minEditTools {
            return .red
        } else if viewModel.selectedTools.count > viewModel.maxEditTools {
            return .red
        } else {
            return .primary
        }
    }
    
    // MARK: - Actions
    
    private func saveEditTools() async {
        await viewModel.updateEditTools()
        
        // エラーがなければ画面を閉じる
        if viewModel.errorMessage == nil {
            dismiss()
        }
    }
}

// MARK: - Edit Tool Row

struct EditToolRow: View {
    let tool: EditTool
    let isSelected: Bool
    let canRemove: Bool
    let onToggle: () -> Void
    
    var body: some View {
        HStack {
            // ツール名
            Text(tool.displayName)
                .font(.body)
            
            Spacer()
            
            // 選択状態の表示
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                
                // 削除可能な場合は削除ボタン
                if canRemove {
                    Button(action: onToggle) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                }
            } else {
                Button(action: onToggle) {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.blue)
                }
            }
        }
        .contentShape(Rectangle())
    }
}


