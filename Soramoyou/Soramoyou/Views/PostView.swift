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
    /// 広角合成(.panorama)のプレビュー＋課金画面の表示フラグ。
    @State private var showStitch = false
    /// 合成＋購入が完了した広角画像（stitch 画面を閉じた後に EditView へ渡す）。
    @State private var pendingStitched: UIImage?
    /// 投稿モード（通常/配置写真/広角合成）。配置写真・広角合成は4枚固定・ログイン必須。
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
            // 広角合成(v2): 合成＋課金プレビュー。閉じた後、購入済みなら合成1枚で EditView を開く。
            .fullScreenCover(isPresented: $showStitch, onDismiss: {
                if let stitched = pendingStitched {
                    pendingStitched = nil
                    viewModel.selectedImages = [stitched]   // 合成済み1枚を投稿パイプラインへ
                    showEditView = true
                }
            }) {
                SkyStitchView(images: viewModel.selectedImages) { stitched in
                    // 購入完了 → 合成画像を保持して stitch 画面を閉じる（onDismiss で EditView へ）
                    pendingStitched = stitched
                    showStitch = false
                }
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
    
    /// 配置写真・広角合成は「ちょうど4枚」が要件。
    private var requiresFourPhotos: Bool {
        postKind == .collage || postKind == .panorama
    }

    /// 選択可能枚数。4枚モードは 4 固定（ピッカー生成前に確定が必須）。
    private var maxSelectionCount: Int {
        if requiresFourPhotos { return 4 }
        return authViewModel.isAuthenticated ? 10 : 3
    }

    private func updateMaxSelectionCount() {
        viewModel.updateMaxSelectionCount(maxSelectionCount)
    }

    /// 選べる投稿モード（配置写真・広角合成はログイン必須＝未ログインでは通常のみ）。
    private var availableKinds: [PostKind] {
        authViewModel.isAuthenticated ? [.single, .collage, .panorama] : [.single]
    }

    /// 4枚モードで「ちょうど4枚」を満たしているか。
    private var isPhotoCountReady: Bool {
        !requiresFourPhotos || viewModel.selectedImages.count == 4
    }

    // MARK: - モード別の表示文言

    private var modeIconName: String {
        switch postKind {
        case .collage:  return "square.grid.2x2"
        case .panorama: return "pano"
        case .single:   return "photo.on.rectangle"
        }
    }

    private var modeTitle: String {
        switch postKind {
        case .collage:  return "配置写真をつくる"
        case .panorama: return "広角合成をつくる"
        case .single:   return "写真を選択"
        }
    }

    private var modeDescription: String {
        switch postKind {
        case .collage:  return "朝・昼・夜・雨など、空を4枚選んで1枚に並べます"
        case .panorama: return "重ねて撮った空を4枚選ぶと、1枚の広い空に合成します（課金）"
        case .single:   return "空の写真を選択して投稿しましょう"
        }
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

            Image(systemName: modeIconName)
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.8))

            Text(modeTitle)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            Text(modeDescription)
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
                
                Text(requiresFourPhotos
                     ? "ちょうど4枚を選んでください"
                     : (authViewModel.isAuthenticated ? "最大10枚" : "最大3枚（ログインで10枚まで）"))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))

                if postKind == .single && !authViewModel.isAuthenticated {
                    Text("配置写真・広角合成はログインで使えます")
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
                
                // 4枚モードで枚数不足のときのガイド
                if requiresFourPhotos && !isPhotoCountReady {
                    Text("ちょうど4枚を選んでください（今 \(viewModel.selectedImages.count) 枚）")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal)
                }

                // アクションボタン
                VStack(spacing: 12) {
                    Button(action: {
                        // 広角合成は合成＋課金プレビューへ。それ以外は編集画面へ。
                        if postKind == .panorama {
                            showStitch = true
                        } else {
                            showEditView = true
                        }
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
                    .disabled(viewModel.isLoading || viewModel.selectedImages.isEmpty || !isPhotoCountReady)
                    
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


