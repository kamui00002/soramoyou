//
//  EditToolsSettingsView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct EditToolsSettingsView: View {
    @StateObject private var viewModel: ProfileViewModel
    @Environment(\.dismiss) private var dismiss

    init(viewModel: ProfileViewModel? = nil) {
        if let viewModel = viewModel {
            _viewModel = StateObject(wrappedValue: viewModel)
        } else {
            _viewModel = StateObject(wrappedValue: ProfileViewModel())
        }
    }

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

                VStack(spacing: 16) {
                    // 説明テキスト
                    Text("右側のハンドル(≡)をドラッグして\n順序を変更できます")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    // 全ツールの並び替えリスト
                    List {
                        ForEach(viewModel.selectedTools, id: \.self) { tool in
                            HStack(spacing: 12) {
                                Image(systemName: tool.iconName)
                                    .foregroundColor(.white)
                                    .frame(width: 24)

                                Text(tool.displayName)
                                    .foregroundColor(.white)

                                Spacer()
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.white.opacity(0.15))
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                        .onMove { from, to in
                            viewModel.selectedTools.move(fromOffsets: from, toOffset: to)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("編集ツールの並び替え")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        viewModel.resetEditTools()
                        dismiss()
                    }
                    .foregroundColor(.white)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        Task {
                            await viewModel.updateEditTools()
                            if viewModel.errorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(viewModel.isLoading)
                    .foregroundColor(.white)
                }
            }
            .alert("エラー", isPresented: .init(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                }
            }
            .task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await viewModel.loadEditToolsSettings()
            }
        }
    }
}
