//
//  EditView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct EditView: View {
    @StateObject private var viewModel: EditViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFilter: FilterType?
    @State private var selectedTool: EditTool?
    @State private var showToolSlider = false
    @State private var showPostInfoView = false
    @State private var finalEditedImages: [UIImage] = []
    @State private var isComparisonMode = false
    @State private var comparisonSliderPosition: CGFloat = 0.5

    private let userId: String?
    private let originalImages: [UIImage]
    
    init(images: [UIImage], userId: String?) {
        self.userId = userId
        self.originalImages = images
        _viewModel = StateObject(wrappedValue: EditViewModel(images: images, userId: userId))
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                // 空のグラデーション背景（上部）
                LinearGradient(
                    colors: [
                        Color(red: 0.68, green: 0.85, blue: 0.90),
                        Color(red: 0.53, green: 0.81, blue: 0.98),
                        Color(red: 0.39, green: 0.58, blue: 0.93),
                        Color.black
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 画像プレビュー
                    imagePreviewView
                    
                    // 編集コントロール
                    editControlsView
                }
            }
            .navigationTitle("編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("次へ") {
                        Task {
                            // 最終的な編集済み画像を生成してから遷移
                            do {
                                let finalImages = try await viewModel.generateFinalImages()
                                // 編集済み画像を設定
                                await MainActor.run {
                                    finalEditedImages = finalImages
                                    showPostInfoView = true
                                }
                            } catch {
                                // エラーは既にviewModel.errorMessageに設定されている
                            }
                        }
                    }
                    .disabled(viewModel.isLoading)
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
            .fullScreenCover(isPresented: $showPostInfoView) {
                NavigationView {
                    PostInfoView(
                        images: originalImages,
                        editedImages: finalEditedImages.isEmpty ? [] : finalEditedImages,
                        editSettings: viewModel.editSettings,
                        userId: userId
                    )
                }
            }
        }
        .onAppear {
            Task {
                await viewModel.loadEquippedTools()
            }
        }
    }
    
    // MARK: - Image Preview View

    private var imagePreviewView: some View {
        ZStack {
            // 暗い背景で画像を見やすく
            Color.black.opacity(0.3)

            if viewModel.isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            } else if isComparisonMode {
                // 比較モード表示
                comparisonView
            } else if let previewImage = viewModel.previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let currentImage = viewModel.currentImage {
                Image(uiImage: currentImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }

            // 比較モードトグルボタン
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isComparisonMode.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isComparisonMode ? "eye.fill" : "eye")
                            Text(isComparisonMode ? "編集後" : "比較")
                                .font(.caption)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isComparisonMode ? Color.blue : Color.white.opacity(0.2))
                        .cornerRadius(20)
                    }
                    .padding()
                }
                Spacer()
            }

            // 複数画像の場合のナビゲーション
            if viewModel.originalImages.count > 1 && !isComparisonMode {
                HStack {
                    Button(action: {
                        viewModel.previousImage()
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                            .background(.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .disabled(viewModel.currentImageIndex == 0)

                    Spacer()

                    Button(action: {
                        viewModel.nextImage()
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                            .background(.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .disabled(viewModel.currentImageIndex >= viewModel.originalImages.count - 1)
                }
                .padding()
            }

            // 画像インデックス表示
            if viewModel.originalImages.count > 1 && !isComparisonMode {
                VStack {
                    Spacer()
                    Text("\(viewModel.currentImageIndex + 1) / \(viewModel.originalImages.count)")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.2))
                        .cornerRadius(12)
                        .padding(.bottom, 100)
                }
            }
        }
    }

    // MARK: - Comparison View

    private var comparisonView: some View {
        GeometryReader { geometry in
            ZStack {
                // 編集後の画像（右側）
                if let previewImage = viewModel.previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 編集前の画像（左側、クリッピング）
                if let currentImage = viewModel.currentImage {
                    Image(uiImage: currentImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(
                            ComparisonClipShape(position: comparisonSliderPosition)
                        )
                }

                // スライダーライン
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 3)
                    .position(x: geometry.size.width * comparisonSliderPosition, y: geometry.size.height / 2)
                    .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 0)

                // スライダーハンドル
                Circle()
                    .fill(Color.white)
                    .frame(width: 40, height: 40)
                    .overlay(
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.caption2)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .foregroundColor(.gray)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                    .position(x: geometry.size.width * comparisonSliderPosition, y: geometry.size.height / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newPosition = value.location.x / geometry.size.width
                                comparisonSliderPosition = max(0.05, min(0.95, newPosition))
                            }
                    )

                // ラベル表示
                VStack {
                    Spacer()
                    HStack {
                        Text("Before")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(4)
                            .padding(.leading, 12)

                        Spacer()

                        Text("After")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(4)
                            .padding(.trailing, 12)
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }
    
    // MARK: - Edit Controls View
    
    private var editControlsView: some View {
        VStack(spacing: 0) {
            // フィルター選択
            filterSelectionView
            
            Divider()
                .background(.white.opacity(0.3))
            
            // 編集ツール選択
            toolSelectionView
            
            // スライダー（ツール選択時のみ表示）
            if showToolSlider, let tool = selectedTool {
                toolSliderView(tool: tool)
            }
        }
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 0)
        )
    }
    
    // MARK: - Filter Selection View
    
    private var filterSelectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("フィルター")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal)
                .padding(.top, 8)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    // フィルターなし
                    FilterButton(
                        filter: nil,
                        displayName: "なし",
                        isSelected: viewModel.editSettings.appliedFilter == nil,
                        action: {
                            viewModel.removeFilter()
                            selectedFilter = nil
                        }
                    )
                    
                    // 10種類のフィルター
                    ForEach(FilterType.allCases, id: \.self) { filter in
                        FilterButton(
                            filter: filter,
                            displayName: filter.displayName,
                            isSelected: viewModel.editSettings.appliedFilter == filter,
                            action: {
                                viewModel.applyFilter(filter)
                                selectedFilter = filter
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)
        }
    }
    
    // MARK: - Tool Selection View
    
    private var toolSelectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("編集ツール")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal)
                .padding(.top, 8)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.equippedTools, id: \.self) { tool in
                        ToolButton(
                            tool: tool,
                            isSelected: selectedTool == tool,
                            hasValue: viewModel.editSettings.value(for: tool) != nil,
                            action: {
                                if selectedTool == tool {
                                    selectedTool = nil
                                    showToolSlider = false
                                } else {
                                    selectedTool = tool
                                    showToolSlider = true
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)
        }
    }
    
    // MARK: - Tool Slider View

    private func toolSliderView(tool: EditTool) -> some View {
        let currentValue = viewModel.editSettings.value(for: tool) ?? 0.0
        let displayValue = Int(currentValue * 100)

        return VStack(spacing: 12) {
            HStack {
                Text(tool.displayName)
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                // 現在の値を表示
                Text(displayValue >= 0 ? "+\(displayValue)" : "\(displayValue)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)

                Button(action: {
                    viewModel.resetToolValue(for: tool)
                }) {
                    Text("リセット")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            HStack {
                Image(systemName: "minus")
                    .foregroundColor(.secondary)

                Slider(
                    value: Binding(
                        get: {
                            viewModel.editSettings.value(for: tool) ?? 0.0
                        },
                        set: { newValue in
                            viewModel.setToolValue(newValue, for: tool)
                        }
                    ),
                    in: -1.0...1.0,
                    onEditingChanged: { isDragging in
                        viewModel.onDraggingChanged(isDragging)
                    }
                )
                .tint(.blue)

                Image(systemName: "plus")
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: - Filter Button

struct FilterButton: View {
    let filter: FilterType?
    let displayName: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue : Color.gray.opacity(0.2))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Text(displayName.prefix(2))
                            .font(.caption)
                            .foregroundColor(isSelected ? .white : .primary)
                    )
                
                Text(displayName)
                    .font(.caption)
                    .foregroundColor(isSelected ? .blue : .primary)
            }
        }
    }
}

// MARK: - Tool Button

struct ToolButton: View {
    let tool: EditTool
    let isSelected: Bool
    let hasValue: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: iconName(for: tool))
                    .font(.title3)
                    .foregroundColor(isSelected ? .blue : (hasValue ? .orange : .gray))
                    .frame(width: 44, height: 44)
                    .background(isSelected ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                    .cornerRadius(8)
                
                Text(tool.displayName)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .blue : .primary)
                    .lineLimit(1)
                    .frame(width: 60)
            }
        }
    }
    
    private func iconName(for tool: EditTool) -> String {
        switch tool {
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .saturation: return "paintpalette"
        case .exposure: return "camera.aperture"
        case .highlight: return "sun.max.circle"
        case .shadow: return "moon"
        case .warmth: return "flame"
        case .sharpness: return "wand.and.stars"
        case .vignette: return "circle.dashed"
        default: return "slider.horizontal.3"
        }
    }
}

// MARK: - Comparison Clip Shape

struct ComparisonClipShape: Shape {
    let position: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(CGRect(x: 0, y: 0, width: rect.width * position, height: rect.height))
        return path
    }
}

struct EditView_Previews: PreviewProvider {
    static var previews: some View {
        EditView(images: [], userId: nil)
    }
}

