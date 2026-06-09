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
    @State private var showEditView = false
    /// 投稿モード（通常/配置写真）。配置写真は4枚固定・ログイン必須。
    /// 広角合成(.panorama)は OpenCV 必須のため本ブランチでは未提供（別ブランチで追加）。
    @State private var postKind: PostKind = .single

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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    GradientTitleView(title: "投稿", fontSize: 20)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .sheet(isPresented: $viewModel.isShowingImagePicker) {
                ImagePicker(
                    selectedImages: $viewModel.selectedImages,
                    pickedMetadata: $viewModel.pickedMetadata,
                    maxSelectionCount: maxSelectionCount,
                    onSelectionComplete: {
                        viewModel.isShowingImagePicker = false
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
            .fullScreenCover(isPresented: $showEditView, onDismiss: {
                // 編集画面から戻ったら選択をクリア
                viewModel.clearSelection()
            }) {
                EditView(
                    images: viewModel.selectedImages,
                    userId: authViewModel.currentUser?.id,
                    externalEditInfos: viewModel.pickedMetadata,
                    postKind: postKind
                )
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            updateMaxSelectionCount()
        }
        .onChange(of: authViewModel.isAuthenticated) { _ in
            // ログアウトで配置写真が使えなくなったら通常モードへ戻す（無効な選択を残さない）
            if !availableKinds.contains(postKind) {
                postKind = .single
            }
            updateMaxSelectionCount()
        }
    }
    
    /// 選択可能枚数。配置写真は「ちょうど4枚」が要件なので 4 固定（ピッカー生成前に確定が必須）。
    private var maxSelectionCount: Int {
        if postKind == .collage { return 4 }
        return authViewModel.isAuthenticated ? 10 : 3
    }

    private func updateMaxSelectionCount() {
        viewModel.updateMaxSelectionCount(maxSelectionCount)
    }

    /// 選べる投稿モード（配置写真はログイン必須＝未ログインでは通常のみ）。
    private var availableKinds: [PostKind] {
        authViewModel.isAuthenticated ? [.single, .collage] : [.single]
    }

    /// 配置写真モードで「ちょうど4枚」を満たしているか。
    private var collageReady: Bool {
        postKind != .collage || viewModel.selectedImages.count == 4
    }
    
    // MARK: - Photo Selection View
    
    private var photoSelectionView: some View {
        VStack(spacing: 24) {
            // 投稿モード選択（配置写真はログイン必須＝未ログインでは表示しない）
            if availableKinds.count > 1 {
                Picker("投稿モード", selection: $postKind) {
                    ForEach(availableKinds) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: postKind) { _ in
                    // モードで枚数上限が変わる。PHPicker の selectionLimit は生成時に固定されるため、
                    // ピッカーを開く前にここで確定させておく。
                    updateMaxSelectionCount()
                }
            }

            Image(systemName: postKind == .collage ? "square.grid.2x2" : "photo.on.rectangle")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.8))

            Text(postKind == .collage ? "配置写真をつくる" : "写真を選択")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            Text(postKind == .collage
                 ? "朝・昼・夜・雨など、空を4枚選んで1枚に並べます"
                 : "空の写真を選択して投稿しましょう")
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
                
                Text(postKind == .collage
                     ? "ちょうど4枚を選んでください"
                     : (authViewModel.isAuthenticated ? "最大10枚" : "最大3枚（ログインで10枚まで）"))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))

                if postKind == .single && !authViewModel.isAuthenticated {
                    Text("配置写真はログインで使えます")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }
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
                
                // 配置写真モードで枚数不足のときのガイド
                if postKind == .collage && !collageReady {
                    Text("配置写真はちょうど4枚です（今 \(viewModel.selectedImages.count) 枚）")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal)
                }

                // アクションボタン
                VStack(spacing: 12) {
                    Button(action: {
                        showEditView = true
                    }) {
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
                    .disabled(viewModel.isLoading || viewModel.selectedImages.isEmpty || !collageReady)
                    
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


