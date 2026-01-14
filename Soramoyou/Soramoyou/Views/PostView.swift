//
//  PostView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct PostView: View {
    @StateObject private var viewModel: PhotoSelectionViewModel
    @EnvironmentObject var authViewModel: AuthViewModel
    
    init() {
        // 認証状態に応じて最大選択数を設定
        // 実際の認証状態は環境オブジェクトから取得するため、初期値は10に設定
        _viewModel = StateObject(wrappedValue: PhotoSelectionViewModel(maxSelectionCount: 10))
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

                VStack(spacing: 0) {
                    ZStack {
                        if viewModel.selectedImages.isEmpty {
                            // 写真選択画面
                            photoSelectionView
                        } else {
                            // 選択された写真のプレビュー
                            photoPreviewView
                        }
                    }
                    
                    // 画面下部に固定表示されるバナー広告
                    BannerAdContainer()
                }
            }
            .navigationTitle("投稿")
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .sheet(isPresented: $viewModel.isShowingImagePicker) {
                ImagePicker(
                    selectedImages: $viewModel.selectedImages,
                    maxSelectionCount: maxSelectionCount,
                    onSelectionComplete: {
                        viewModel.isShowingImagePicker = false
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
        }
        .onAppear {
            updateMaxSelectionCount()
        }
        .onChange(of: authViewModel.isAuthenticated) { _ in
            updateMaxSelectionCount()
        }
    }
    
    private var maxSelectionCount: Int {
        authViewModel.isAuthenticated ? 10 : 3
    }
    
    private func updateMaxSelectionCount() {
        let newMaxCount = authViewModel.isAuthenticated ? 10 : 3
        viewModel.updateMaxSelectionCount(newMaxCount)
    }
    
    // MARK: - Photo Selection View
    
    private var photoSelectionView: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.8))
            
            Text("写真を選択")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            
            Text("空の写真を選択して投稿しましょう")
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: {
                viewModel.startPhotoSelection()
            }) {
                HStack {
                    Image(systemName: "photo.on.rectangle")
                    Text("写真を選択")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.25))
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(.white.opacity(0.5), lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
            }
            .padding(.horizontal)
            
            VStack(spacing: 8) {
                Text("選択可能な枚数")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                
                Text(authViewModel.isAuthenticated ? "最大10枚" : "最大3枚（ログインで10枚まで）")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.top)
        }
        .padding()
    }
    
    // MARK: - Photo Preview View
    
    private var photoPreviewView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 選択された写真のグリッド表示
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(Array(viewModel.selectedImages.enumerated()), id: \.offset) { index, image in
                        PhotoPreviewItem(
                            image: image,
                            index: index,
                            onRemove: {
                                viewModel.removeImage(at: index)
                            }
                        )
                    }
                }
                .padding()
                
                // アクションボタン
                VStack(spacing: 12) {
                    NavigationLink(destination: EditView(
                        images: viewModel.selectedImages,
                        userId: authViewModel.currentUser?.id
                    ).navigationBarBackButtonHidden(false)) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("次へ")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.white.opacity(0.25))
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(.white.opacity(0.5), lineWidth: 1)
                                )
                        )
                        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
                    }
                    .disabled(viewModel.isLoading || viewModel.selectedImages.isEmpty)
                    
                    Button(action: {
                        viewModel.clearSelection()
                    }) {
                        Text("選択をクリア")
                            .font(.body)
                            .foregroundColor(.white.opacity(0.9))
                    }
                    
                    Button(action: {
                        viewModel.startPhotoSelection()
                    }) {
                        Text("写真を追加")
                            .font(.body)
                            .foregroundColor(.white)
                    }
                    .disabled(viewModel.selectedImages.count >= maxSelectionCount)
                }
                .padding()
            }
        }
    }
}

// MARK: - Photo Preview Item

struct PhotoPreviewItem: View {
    let image: UIImage
    let index: Int
    let onRemove: () -> Void
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 150)
                .clipped()
                .cornerRadius(8)
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
            }
            .padding(8)
        }
    }
}

struct PostView_Previews: PreviewProvider {
    static var previews: some View {
        PostView()
            .environmentObject(AuthViewModel())
    }
}


