// ⭐️ EditView.swift
// 編集画面
// 3タブ構成（フィルター/編集ツール/切り取り）に改善
// リアルタイムプレビュー対応
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

    // MARK: - State

    /// 選択中のタブ
    @State private var selectedTab: EditTab = .filter
    /// 選択中のフィルター
    @State private var selectedFilter: FilterType?
    /// 選択中の編集ツール
    @State private var selectedTool: EditTool?
    /// スライダーの現在値（リアルタイム用）
    @State private var sliderValue: Float = 0
    /// 投稿情報入力画面の表示フラグ
    @State private var showPostInfoView = false
    /// 最終編集済み画像
    @State private var finalEditedImages: [UIImage] = []
    /// 編集ツール設定画面の表示フラグ
    @State private var showEditToolsSettings = false
    /// 回転スライダーの値（リアルタイム用）
    @State private var rotationSliderValue: Double = 0

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
                // 空のグラデーション背景
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

                    // 編集コントロール（3タブ構成）
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
                    HStack(spacing: 16) {
                        // 編集ツール設定ボタン
                        Button(action: {
                            showEditToolsSettings = true
                        }) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.body)
                        }
                        .foregroundColor(.white)

                        // 次へボタン
                        Button("次へ") {
                            Task {
                                do {
                                    let finalImages = try await viewModel.generateFinalImages()
                                    await MainActor.run {
                                        finalEditedImages = finalImages
                                        showPostInfoView = true
                                    }
                                } catch {
                                    // エラーは viewModel.errorMessage に設定
                                }
                            }
                        }
                        .disabled(viewModel.isLoading)
                        .foregroundColor(.white)
                    }
                }
            }
            .sheet(isPresented: $showEditToolsSettings) {
                Task {
                    await viewModel.loadEquippedTools()
                }
            } content: {
                EditToolsSettingsView()
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

            if viewModel.isLoading && !viewModel.isEditingRealtime {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            } else if let displayImage = viewModel.displayPreviewImage {
                // リアルタイム編集中は高速プレビュー、それ以外は通常プレビュー
                Image(uiImage: displayImage)
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

            // 複数画像の場合のナビゲーション
            if viewModel.originalImages.count > 1 {
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
            if viewModel.originalImages.count > 1 {
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

    // MARK: - Edit Controls View (3タブ構成)

    private var editControlsView: some View {
        VStack(spacing: 0) {
            // コンテンツエリア（タブに応じて切り替え）
            tabContentView

            // タブバー
            editTabBar
        }
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 0)
        )
    }

    // MARK: - Tab Content View

    @ViewBuilder
    private var tabContentView: some View {
        switch selectedTab {
        case .filter:
            filterContentView
        case .adjustment:
            adjustmentContentView
        case .crop:
            cropContentView
        }
    }

    // MARK: - Edit Tab Bar (3タブ)

    private var editTabBar: some View {
        HStack(spacing: 0) {
            ForEach(EditTab.allCases) { tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                        // タブ切り替え時にツール選択をリセット
                        selectedTool = nil
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: tab.iconName)
                            .font(.title3)
                        Text(tab.displayName)
                            .font(.caption2)
                    }
                    .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
        }
        .background(Color.black.opacity(0.3))
    }

    // MARK: - Filter Content View

    private var filterContentView: some View {
        VStack(spacing: 0) {
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
                .padding(.vertical, 16)
            }
        }
        .frame(height: 120)
    }

    // MARK: - Adjustment Content View (編集ツール)

    private var adjustmentContentView: some View {
        VStack(spacing: 0) {
            // ツール選択中はスライダーを表示
            if let tool = selectedTool {
                improvedSliderView(tool: tool)
            }

            // ツール一覧
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
                                } else {
                                    selectedTool = tool
                                    // 現在の値をスライダーに反映
                                    sliderValue = viewModel.editSettings.value(for: tool) ?? 0
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
        }
        .frame(minHeight: selectedTool != nil ? 180 : 100)
    }

    // MARK: - Improved Slider View (目盛り付き)

    private func improvedSliderView(tool: EditTool) -> some View {
        VStack(spacing: 8) {
            // ヘッダー（ツール名・現在値・リセット）
            HStack {
                Text(tool.displayName)
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                // 現在値の表示
                Text(formatSliderValue(sliderValue))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)

                Button(action: {
                    sliderValue = 0
                    viewModel.resetToolValue(for: tool)
                }) {
                    Text("リセット")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // 目盛り付きスライダー
            ZStack(alignment: .center) {
                // 目盛り
                TickMarksView()

                // スライダー
                Slider(
                    value: Binding(
                        get: { sliderValue },
                        set: { newValue in
                            sliderValue = newValue
                            // リアルタイムプレビュー
                            viewModel.setToolValueRealtime(newValue, for: tool)
                        }
                    ),
                    in: -1.0...1.0,
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            // スライダー操作完了時に高品質プレビュー生成
                            viewModel.finalizeToolValue(for: tool)
                        }
                    }
                )
                .tint(.white)
                .accentColor(.white)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color.black.opacity(0.2))
    }

    /// スライダー値のフォーマット
    private func formatSliderValue(_ value: Float) -> String {
        let intValue = Int(value * 100)
        if intValue >= 0 {
            return "+\(intValue)"
        } else {
            return "\(intValue)"
        }
    }

    // MARK: - Crop Content View (切り取り)

    private var cropContentView: some View {
        VStack(spacing: 16) {
            // 回転スライダー
            VStack(spacing: 8) {
                HStack {
                    Text("回転")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Spacer()

                    Text(String(format: "%.1f°", rotationSliderValue))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)

                    Button(action: {
                        rotationSliderValue = 0
                        viewModel.resetCropSettings()
                    }) {
                        Text("リセット")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal)

                Slider(
                    value: $rotationSliderValue,
                    in: -45...45,
                    onEditingChanged: { isEditing in
                        if isEditing {
                            viewModel.setRotationRealtime(rotationSliderValue)
                        } else {
                            viewModel.finalizeRotation()
                        }
                    }
                )
                .tint(.white)
                .padding(.horizontal)
                .onChange(of: rotationSliderValue) { newValue in
                    viewModel.setRotationRealtime(newValue)
                }
            }

            // 回転・反転ボタン
            HStack(spacing: 20) {
                // 左回転
                CropActionButton(
                    iconName: "rotate.left",
                    label: "左90°",
                    action: {
                        viewModel.rotateLeft()
                        rotationSliderValue = viewModel.rotationDegrees
                    }
                )

                // 右回転
                CropActionButton(
                    iconName: "rotate.right",
                    label: "右90°",
                    action: {
                        viewModel.rotateRight()
                        rotationSliderValue = viewModel.rotationDegrees
                    }
                )

                // 左右反転
                CropActionButton(
                    iconName: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    label: "左右反転",
                    isActive: viewModel.isFlippedHorizontal,
                    action: {
                        viewModel.toggleFlipHorizontal()
                    }
                )

                // 上下反転
                CropActionButton(
                    iconName: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                    label: "上下反転",
                    isActive: viewModel.isFlippedVertical,
                    action: {
                        viewModel.toggleFlipVertical()
                    }
                )
            }
            .padding(.horizontal)

            // アスペクト比選択
            HStack(spacing: 12) {
                ForEach(CropAspectRatio.allCases) { ratio in
                    AspectRatioButton(
                        ratio: ratio,
                        isSelected: viewModel.cropAspectRatio == ratio,
                        action: {
                            viewModel.setCropAspectRatio(ratio)
                        }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .frame(minHeight: 180)
    }
}

// MARK: - Tick Marks View (目盛り)

struct TickMarksView: View {
    /// 目盛りの数（21本: -100〜+100、10刻み）
    private let tickCount = 21

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(0..<tickCount, id: \.self) { index in
                    let isCenterTick = index == tickCount / 2

                    Rectangle()
                        .fill(isCenterTick ? Color.white : Color.white.opacity(0.3))
                        .frame(width: isCenterTick ? 2 : 1, height: isCenterTick ? 16 : 8)

                    if index < tickCount - 1 {
                        Spacer()
                    }
                }
            }
            .frame(height: 20)
            .padding(.horizontal, 8)
        }
        .frame(height: 20)
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
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

// MARK: - Crop Action Button

struct CropActionButton: View {
    let iconName: String
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundColor(isActive ? .blue : .white)
                    .frame(width: 44, height: 44)
                    .background(isActive ? Color.blue.opacity(0.2) : Color.white.opacity(0.1))
                    .cornerRadius(8)

                Text(label)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }
}

// MARK: - Aspect Ratio Button

struct AspectRatioButton: View {
    let ratio: CropAspectRatio
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(ratio.displayName)
                .font(.caption)
                .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color.white.opacity(0.1))
                .cornerRadius(8)
        }
    }
}

// MARK: - Preview

struct EditView_Previews: PreviewProvider {
    static var previews: some View {
        EditView(images: [], userId: nil)
    }
}
