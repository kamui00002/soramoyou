//
//  ProfileEditView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import Kingfisher

struct ProfileEditView: View {
    @ObservedObject var viewModel: ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingImagePicker = false
    @State private var selectedImage: UIImage?
    
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
                        // プロフィール画像セクション
                        profileImageSection
                        
                        // 表示名セクション
                        VStack(alignment: .leading, spacing: 12) {
                            Text("表示名")
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            TextField("表示名", text: $viewModel.editingDisplayName)
                                .textInputAutocapitalization(.never)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.white.opacity(0.2))
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(.white.opacity(0.4), lineWidth: 1)
                                        )
                                )
                                .foregroundColor(.primary)
                        }
                        
                        // 自己紹介セクション
                        VStack(alignment: .leading, spacing: 12) {
                            Text("自己紹介")
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            TextEditor(text: $viewModel.editingBio)
                                .frame(minHeight: 100)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.white.opacity(0.2))
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(.white.opacity(0.4), lineWidth: 1)
                                        )
                                )
                                .foregroundColor(.primary)
                                .scrollContentBackground(.hidden)
                        }
                        
                        // バリデーションメッセージ
                        if !viewModel.isValidProfileEdit {
                            Text("表示名は50文字以内、自己紹介は200文字以内で入力してください")
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(.white.opacity(0.9))
                                )
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("プロフィール編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        // 編集内容をリセット
                        resetEditingValues()
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        Task {
                            await saveProfile()
                        }
                    }
                    .disabled(!viewModel.isValidProfileEdit || viewModel.isLoading)
                    .foregroundColor(.white)
                }
            }
            .sheet(isPresented: $showingImagePicker) {
                ImagePicker(
                    selectedImages: Binding(
                        get: { selectedImage.map { [$0] } ?? [] },
                        set: { selectedImage = $0.first }
                    ),
                    maxSelectionCount: 1,
                    onSelectionComplete: {
                        if let image = selectedImage {
                            viewModel.editingProfileImage = image
                        }
                    }
                )
            }
            .alert("エラー", isPresented: Binding(errorMessage: $viewModel.errorMessage)) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                }
            }
            .onAppear {
                // 編集用の値を初期化（既にProfileViewModelで設定済み）
            }
        }
        .navigationViewStyle(.stack)
    }
    
    // MARK: - Profile Image Section
    
    private var profileImageSection: some View {
        VStack(spacing: 16) {
            // プロフィール画像表示
            Group {
                if let editingImage = viewModel.editingProfileImage {
                    Image(uiImage: editingImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if let photoURL = viewModel.user?.photoURL, let url = URL(string: photoURL) {
                    KFImage(url)
                        .placeholder {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 80))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.4), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
            
            // 画像変更ボタン
            Button(action: {
                showingImagePicker = true
            }) {
                HStack {
                    Image(systemName: "photo")
                    Text("画像を変更")
                }
                .font(.body)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(0.2))
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.white.opacity(0.4), lineWidth: 1)
                        )
                )
            }
            
            // 画像を削除ボタン（既存の画像がある場合）
            if viewModel.user?.photoURL != nil || viewModel.editingProfileImage != nil {
                Button(action: {
                    viewModel.editingProfileImage = nil
                    viewModel.shouldDeleteProfileImage = true
                }) {
                    Text("画像を削除")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
    }
    
    // MARK: - Actions
    
    private func saveProfile() async {
        await viewModel.updateProfile()
        
        // エラーがなければ画面を閉じる
        if viewModel.errorMessage == nil {
            dismiss()
        }
    }
    
    private func resetEditingValues() {
        // 編集用の値をリセット（ProfileViewModelのloadProfileで再設定される）
        selectedImage = nil
    }
}

