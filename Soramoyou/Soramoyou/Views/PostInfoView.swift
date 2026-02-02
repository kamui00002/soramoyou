//
//  PostInfoView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import MapKit

struct PostInfoView: View {
    @StateObject private var viewModel: PostViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLocationPicker = false
    @State private var showMapView = false
    @State private var selectedLandmark: MKMapItem?
    
    private let locationService: LocationServiceProtocol
    private let userId: String?
    
    init(
        images: [UIImage],
        editedImages: [UIImage],
        editSettings: EditSettings,
        userId: String?,
        locationService: LocationServiceProtocol = LocationService()
    ) {
        let postViewModel = PostViewModel(userId: userId)
        postViewModel.setSelectedImages(images)
        if !editedImages.isEmpty {
            postViewModel.setEditedImages(editedImages, editSettings: editSettings)
        } else {
            // 編集済み画像がない場合は、編集設定を適用して生成
            Task {
                let editViewModel = EditViewModel(images: images, userId: userId)
                let generatedImages = try? await editViewModel.generateFinalImages()
                if let generatedImages = generatedImages {
                    postViewModel.setEditedImages(generatedImages, editSettings: editSettings)
                }
            }
        }
        _viewModel = StateObject(wrappedValue: postViewModel)
        self.locationService = locationService
        self.userId = userId
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

                ScrollView {
                    VStack(spacing: 24) {
                        // 編集済み画像がない場合は生成中表示
                        if viewModel.editedImages.isEmpty {
                            VStack {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                Text("画像を生成中...")
                                    .foregroundColor(.white)
                            }
                            .padding()
                        } else {
                            // 編集済み写真のプレビュー
                            photoPreviewSection
                        }
                        
                        // キャプション入力
                        captionSection
                        
                        // ハッシュタグ表示
                        hashtagSection
                        
                        // 位置情報
                        locationSection
                        
                        // 自動抽出された情報
                        extractedInfoSection
                        
                        // 公開設定
                        visibilitySection

                        // オリジナル画像保存オプション
                        originalImagesSaveSection

                        // アクションボタン
                        actionButtons
                    }
                    .padding()
                }
            }
            .navigationTitle("投稿情報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .sheet(isPresented: $showMapView) {
                MapView(
                    selectedLandmark: $selectedLandmark,
                    onLandmarkSelected: { landmark in
                        if let landmark = landmark {
                            let location = Location(
                                latitude: landmark.placemark.coordinate.latitude,
                                longitude: landmark.placemark.coordinate.longitude,
                                city: nil,
                                prefecture: nil,
                                landmark: landmark.name
                            )
                            viewModel.setLocation(location)
                        }
                        showMapView = false
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
            .alert("投稿完了", isPresented: $viewModel.isPostSaved) {
                Button("OK") {
                    // 投稿完了後、画面を閉じてホーム画面に戻る
                    dismiss()
                }
            } message: {
                Text("投稿が完了しました")
            }
            .onAppear {
                // 編集済み画像がない場合は生成
                if viewModel.editedImages.isEmpty && !viewModel.selectedImages.isEmpty {
                    Task {
                        let editViewModel = EditViewModel(images: viewModel.selectedImages, userId: userId)
                        if let editSettings = viewModel.editSettings {
                            editViewModel.editSettings = editSettings
                        }
                        do {
                            let generatedImages = try await editViewModel.generateFinalImages()
                            viewModel.setEditedImages(generatedImages, editSettings: viewModel.editSettings ?? EditSettings())
                        } catch {
                            viewModel.errorMessage = "画像の生成に失敗しました"
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Photo Preview Section
    
    private var photoPreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("写真プレビュー")
                .font(.headline)
                .foregroundColor(.white)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(viewModel.editedImages.enumerated()), id: \.offset) { index, image in
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 100, height: 100)
                            .clipped()
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 3)
                    }
                }
            }
        }
    }
    
    // MARK: - Caption Section
    
    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("キャプション")
                .font(.headline)
                .foregroundColor(.white)
            
            TextEditor(text: Binding(
                get: { viewModel.caption },
                set: { viewModel.setCaption($0) }
            ))
            .frame(height: 100)
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
            
            Text("ハッシュタグは「#」で始まる単語で自動的に抽出されます")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
    }
    
    // MARK: - Hashtag Section
    
    private var hashtagSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ハッシュタグ")
                .font(.headline)
                .foregroundColor(.white)
            
            if viewModel.hashtags.isEmpty {
                Text("ハッシュタグはありません")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(viewModel.hashtags, id: \.self) { hashtag in
                        Text("#\(hashtag)")
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.2))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
            }
        }
    }
    
    // MARK: - Location Section
    
    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("位置情報")
                .font(.headline)
                .foregroundColor(.white)
            
            if let location = viewModel.location {
                VStack(alignment: .leading, spacing: 8) {
                    if let landmark = location.landmark {
                        Text("ランドマーク: \(landmark)")
                            .font(.body)
                            .foregroundColor(.white)
                    }
                    if let city = location.city, let prefecture = location.prefecture {
                        Text("\(prefecture) \(city)")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    Text("緯度: \(location.latitude, specifier: "%.6f"), 経度: \(location.longitude, specifier: "%.6f")")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                    
                    Button("位置情報を変更") {
                        showLocationPicker = true
                    }
                    .font(.caption)
                    .foregroundColor(.white)
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
            } else {
                Button(action: {
                    Task {
                        await addLocation()
                    }
                }) {
                    HStack {
                        Image(systemName: "location")
                        Text("位置情報を追加")
                    }
                    .font(.body)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.white.opacity(0.15))
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.white.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
            }
            
            Button(action: {
                showMapView = true
            }) {
                HStack {
                    Image(systemName: "map")
                    Text("地図からランドマークを選択")
                }
                .font(.body)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.15))
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.white.opacity(0.3), lineWidth: 1)
                        )
                )
            }
        }
    }
    
    // MARK: - Extracted Info Section
    
    private var extractedInfoSection: some View {
        Group {
            if let info = viewModel.extractedInfo {
                VStack(alignment: .leading, spacing: 12) {
                    Text("自動抽出された情報")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        // 撮影時刻
                        if let capturedAt = info.capturedAt {
                            HStack {
                                Image(systemName: "camera")
                                    .foregroundColor(.white.opacity(0.8))
                                Text("撮影時刻: \(formatDate(capturedAt))")
                                    .font(.body)
                                    .foregroundColor(.white)
                            }
                        }
                        
                        // 時間帯
                        if let timeOfDay = info.timeOfDay {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundColor(.white.opacity(0.8))
                                Text("時間帯: \(timeOfDay.displayName)")
                                    .font(.body)
                                    .foregroundColor(.white)
                            }
                        }
                        
                        // 空の種類
                        if let skyType = info.skyType {
                            HStack {
                                Image(systemName: "cloud")
                                    .foregroundColor(.white.opacity(0.8))
                                Text("空の種類: \(skyType.displayName)")
                                    .font(.body)
                                    .foregroundColor(.white)
                            }
                        }
                        
                        // 色温度
                        if let colorTemperature = info.colorTemperature {
                            HStack {
                                Image(systemName: "thermometer")
                                    .foregroundColor(.white.opacity(0.8))
                                Text("色温度: \(colorTemperature)K")
                                    .font(.body)
                                    .foregroundColor(.white)
                            }
                        }
                        
                        // 主要色
                        if !info.skyColors.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("主要色")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.8))
                                
                                HStack(spacing: 12) {
                                    ForEach(info.skyColors.prefix(5), id: \.self) { colorHex in
                                        ColorCircle(colorHex: colorHex)
                                    }
                                }
                            }
                        }
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
                }
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: date)
    }
    
    // MARK: - Visibility Section

    private var visibilitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("公開設定")
                .font(.headline)
                .foregroundColor(.white)

            Picker("公開設定", selection: $viewModel.visibility) {
                ForEach(Visibility.allCases, id: \.self) { visibility in
                    Text(visibility.displayName).tag(visibility)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.2))
            )
        }
    }

    // MARK: - Original Images Save Section

    private var originalImagesSaveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保存オプション")
                .font(.headline)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $viewModel.saveOriginalImages) {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundColor(.white.opacity(0.8))
                        Text("オリジナル画像も保存する")
                            .foregroundColor(.white)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.39, green: 0.58, blue: 0.93)))

                Text("オンにすると、ギャラリーで編集前後の比較ができます")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
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
        }
    }

    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: {
                Task {
                    do {
                        try await viewModel.savePost()
                    } catch {
                        // エラーは既にviewModel.errorMessageに設定されている
                    }
                }
            }) {
                HStack {
                    if viewModel.isUploading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(viewModel.isUploading ? "投稿中..." : "投稿")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(viewModel.isUploading ? 0.15 : 0.25))
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(.white.opacity(0.5), lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
            }
            .disabled(viewModel.isUploading)
            
            if viewModel.isUploading {
                ProgressView(value: viewModel.uploadProgress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .white))
            }
            
            Button(action: {
                Task {
                    do {
                        try await viewModel.saveDraft()
                        // 下書き保存成功のメッセージを表示（簡易版）
                    } catch {
                        // エラーは既にviewModel.errorMessageに設定されている
                    }
                }
            }) {
                Text("下書き保存")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.9))
            }
            .disabled(viewModel.isUploading)
        }
    }
    
    // MARK: - Helper Methods
    
    private func addLocation() async {
        do {
            let location = try await locationService.getCurrentLocation()
            let geocode = try await locationService.reverseGeocode(location: location)
            
            let locationData = Location(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                city: geocode.city,
                prefecture: geocode.prefecture
            )
            
            viewModel.setLocation(locationData)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX,
                                     y: bounds.minY + result.frames[index].minY),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var frames: [CGRect] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if currentX + size.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                
                frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }
            
            size = CGSize(width: maxWidth, height: currentY + lineHeight)
        }
    }
}

// MARK: - Map View

struct MapView: View {
    @Binding var selectedLandmark: MKMapItem?
    let onLandmarkSelected: (MKMapItem?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503), // 東京
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )
    
    private let locationService: LocationServiceProtocol
    
    init(
        selectedLandmark: Binding<MKMapItem?>,
        onLandmarkSelected: @escaping (MKMapItem?) -> Void,
        locationService: LocationServiceProtocol = LocationService()
    ) {
        self._selectedLandmark = selectedLandmark
        self.onLandmarkSelected = onLandmarkSelected
        self.locationService = locationService
    }
    
    var body: some View {
        NavigationView {
            VStack {
                // 検索バー
                HStack {
                    TextField("ランドマークを検索", text: $searchText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onSubmit {
                            Task {
                                await searchLandmarks()
                            }
                        }
                    
                    Button("検索") {
                        Task {
                            await searchLandmarks()
                        }
                    }
                }
                .padding()
                
                // 地図表示
                Map(coordinateRegion: $region, annotationItems: searchResults.map { MapItemWrapper(item: $0) }) { wrapper in
                    MapAnnotation(coordinate: wrapper.item.placemark.coordinate) {
                        Button(action: {
                            selectedLandmark = wrapper.item
                            onLandmarkSelected(wrapper.item)
                        }) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundColor(.red)
                                .font(.title)
                        }
                    }
                }
                
                // 検索結果リスト
                if !searchResults.isEmpty {
                    List(searchResults, id: \.self) { item in
                        Button(action: {
                            selectedLandmark = item
                            onLandmarkSelected(item)
                        }) {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "不明")
                                    .font(.headline)
                                if let address = item.placemark.title {
                                    Text(address)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
            .navigationTitle("ランドマーク選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func searchLandmarks() async {
        guard !searchText.isEmpty else { return }
        
        do {
            let results = try await locationService.searchLandmarks(query: searchText, region: region)
            searchResults = results
        } catch {
            // エラーハンドリング（簡易版）
            print("ランドマーク検索エラー: \(error)")
        }
    }
}

// MARK: - MapItemWrapper

struct MapItemWrapper: Identifiable {
    let id = UUID()
    let item: MKMapItem
}

// MARK: - Color Circle

struct ColorCircle: View {
    let colorHex: String
    
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(hexToColor(colorHex))
                .frame(width: 40, height: 40)
                .overlay(
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            Text(colorHex)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    private func hexToColor(_ hex: String) -> Color {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        return Color(red: r, green: g, blue: b)
    }
}

struct PostInfoView_Previews: PreviewProvider {
    static var previews: some View {
        PostInfoView(
            images: [],
            editedImages: [],
            editSettings: EditSettings(),
            userId: nil
        )
    }
}

