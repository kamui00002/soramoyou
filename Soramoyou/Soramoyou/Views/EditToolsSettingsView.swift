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

                ScrollView {
                    VStack(spacing: 24) {
                        // 選択状況の表示
                        VStack(alignment: .leading, spacing: 12) {
                            Text("選択状況")
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            HStack {
                                Text("選択数")
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(viewModel.selectedTools.count) / \(viewModel.maxEditTools)")
                                    .foregroundColor(selectionCountColor)
                                    .fontWeight(.bold)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.white.opacity(0.15))
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(.white.opacity(0.3), lineWidth: 1)
                                    )
                            )
                            
                            if !viewModel.isValidEditToolsSelection {
                                Text("編集装備は5個から8個まで選択してください")
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 8)
                            }
                        }
                        
                        // 選択されたツール
                        VStack(alignment: .leading, spacing: 12) {
                            Text("選択された編集装備")
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            if viewModel.selectedTools.isEmpty {
                                Text("編集装備を選択してください")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding()
                            } else {
                                LazyVStack(spacing: 8) {
                                    ForEach(viewModel.selectedTools, id: \.self) { tool in
                                        EditToolRowGlass(
                                            tool: tool,
                                            isSelected: true,
                                            canRemove: viewModel.selectedTools.count > viewModel.minEditTools,
                                            onToggle: {
                                                viewModel.removeEditTool(tool)
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        
                        // 利用可能なツール一覧
                        VStack(alignment: .leading, spacing: 12) {
                            Text("利用可能な編集装備")
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            let availableTools = viewModel.availableTools.filter { tool in
                                !viewModel.selectedTools.contains(tool)
                            }
                            
                            if availableTools.isEmpty {
                                Text("すべての編集装備が選択されています")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding()
                            } else {
                                LazyVStack(spacing: 8) {
                                    ForEach(availableTools, id: \.self) { tool in
                                        EditToolRowGlass(
                                            tool: tool,
                                            isSelected: false,
                                            canRemove: false,
                                            onToggle: {
                                                if viewModel.selectedTools.count < viewModel.maxEditTools {
                                                    viewModel.addEditTool(tool)
                                                }
                                            }
                                        )
                                        .opacity(viewModel.selectedTools.count >= viewModel.maxEditTools ? 0.5 : 1.0)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("編集装備設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        // 編集内容をリセット
                        viewModel.resetEditTools()
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        Task {
                            await saveEditTools()
                        }
                    }
                    .disabled(!viewModel.isValidEditToolsSelection || viewModel.isLoading)
                    .foregroundColor(.white)
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
            return .white
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

// MARK: - Edit Tool Row Glass Style

struct EditToolRowGlass: View {
    let tool: EditTool
    let isSelected: Bool
    let canRemove: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack {
                Image(systemName: tool.iconName)
                    .foregroundColor(.white)
                    .frame(width: 24)
                
                Text(tool.displayName)
                    .foregroundColor(.white)
                
                Spacer()
                
                if isSelected {
                    if canRemove {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red.opacity(0.8))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green.opacity(0.8))
                    }
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(isSelected ? 0.25 : 0.15))
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(isSelected ? 0.4 : 0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
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


