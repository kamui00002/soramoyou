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
            Form {
                // プロフィール画像セクション
                Section {
                    profileImageSection
                }
                
                // 表示名セクション
                Section(header: Text("表示名")) {
                    TextField("表示名", text: $viewModel.editingDisplayName)
                        .textInputAutocapitalization(.never)
                }
                
                // 自己紹介セクション
                Section(header: Text("自己紹介")) {
                    TextEditor(text: $viewModel.editingBio)
                        .frame(minHeight: 100)
                }
                
                // バリデーションメッセージ
                if !viewModel.isValidProfileEdit {
                    Section {
                        Text("表示名は50文字以内、自己紹介は200文字以内で入力してください")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("プロフィール編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        // 編集内容をリセット
                        resetEditingValues()
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        Task {
                            await saveProfile()
                        }
                    }
                    .disabled(!viewModel.isValidProfileEdit || viewModel.isLoading)
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
                // 編集用の値を初期化（既にProfileViewModelで設定済み）
            }
        }
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
                                .foregroundColor(.gray)
                        }
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.gray)
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 2)
            )
            
            // 画像変更ボタン
            Button(action: {
                showingImagePicker = true
            }) {
                HStack {
                    Image(systemName: "photo")
                    Text("画像を変更")
                }
                .font(.body)
            }
            
            // 画像を削除ボタン（既存の画像がある場合）
            if viewModel.user?.photoURL != nil || viewModel.editingProfileImage != nil {
                Button(action: {
                    viewModel.editingProfileImage = nil
                    viewModel.shouldDeleteProfileImage = true
                }) {
                    Text("画像を削除")
                        .font(.body)
                        .foregroundColor(.red)
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

