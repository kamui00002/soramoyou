//
//  GalleryDetailView.swift
//  Soramoyou
//
//  Created on 2025-01-19.
//

import SwiftUI
import Kingfisher

struct GalleryDetailView: View {
    let post: Post
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = GalleryDetailViewModel()
    @State private var showingOriginalImage = false

    // オリジナル画像が利用可能かどうか
    private var hasOriginalImages: Bool {
        post.originalImages != nil && !(post.originalImages?.isEmpty ?? true)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 投稿者情報
                    if let user = viewModel.author {
                        authorSection(user: user)
                    } else if viewModel.isLoadingAuthor {
                        HStack {
                            ProgressView()
                            Text("投稿者情報を読み込み中...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    }

                    // 画像表示（編集前後切り替え対応）
                    imageSection

                    // 編集前後切り替えボタン
                    if hasOriginalImages {
                        toggleButton
                    }

                    // 編集設定表示
                    if let editSettings = post.editSettings {
                        editSettingsSection(editSettings: editSettings)
                    }

                    // 投稿情報
                    postInfoSection

                    // 空の種類・時間帯・色温度
                    skyInfoSection

                    // 統計情報
                    statsSection
                }
                .padding()
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("投稿詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                Task {
                    await viewModel.loadAuthor(userId: post.userId)
                }
            }
        }
    }

    // MARK: - Image Section

    private var imageSection: some View {
        Group {
            if showingOriginalImage, let originalImages = post.originalImages, let firstOriginal = originalImages.first {
                // オリジナル画像を表示
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "photo")
                            .foregroundColor(.orange)
                        Text("編集前")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)
                    }

                    GalleryDetailImageView(imageInfo: firstOriginal)
                }
            } else if let firstImage = post.images.first {
                // 編集後の画像を表示
                VStack(alignment: .leading, spacing: 8) {
                    if hasOriginalImages {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundColor(.blue)
                            Text("編集後")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                        }
                    }

                    GalleryDetailImageView(imageInfo: firstImage)
                }
            }
        }
    }

    // MARK: - Toggle Button

    private var toggleButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.3)) {
                showingOriginalImage.toggle()
            }
        }) {
            HStack {
                Image(systemName: showingOriginalImage ? "slider.horizontal.3" : "photo")
                Text(showingOriginalImage ? "編集後を表示" : "編集前を表示")
            }
            .font(.body)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: showingOriginalImage ? [Color.blue, Color.blue.opacity(0.8)] : [Color.orange, Color.orange.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
        }
    }

    // MARK: - Edit Settings Section

    private func editSettingsSection(editSettings: EditSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.blue)
                Text("編集設定")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                // 適用フィルター
                if let filter = editSettings.appliedFilter {
                    editSettingRow(icon: "camera.filters", label: "フィルター", value: filter.displayName)
                }

                // 各編集パラメータ
                if let brightness = editSettings.brightness, brightness != 0 {
                    editSettingRow(icon: "sun.max", label: "明るさ", value: formatValue(brightness))
                }

                if let contrast = editSettings.contrast, contrast != 0 {
                    editSettingRow(icon: "circle.lefthalf.filled", label: "コントラスト", value: formatValue(contrast))
                }

                if let saturation = editSettings.saturation, saturation != 0 {
                    editSettingRow(icon: "drop.fill", label: "彩度", value: formatValue(saturation))
                }

                if let exposure = editSettings.exposure, exposure != 0 {
                    editSettingRow(icon: "plusminus.circle", label: "露出", value: formatValue(exposure))
                }

                if let highlight = editSettings.highlight, highlight != 0 {
                    editSettingRow(icon: "sun.max.fill", label: "ハイライト", value: formatValue(highlight))
                }

                if let shadow = editSettings.shadow, shadow != 0 {
                    editSettingRow(icon: "shadow", label: "シャドウ", value: formatValue(shadow))
                }

                if let warmth = editSettings.warmth, warmth != 0 {
                    editSettingRow(icon: "thermometer", label: "暖かみ", value: formatValue(warmth))
                }

                if let sharpness = editSettings.sharpness, sharpness != 0 {
                    editSettingRow(icon: "triangle", label: "シャープネス", value: formatValue(sharpness))
                }

                if let vignette = editSettings.vignette, vignette != 0 {
                    editSettingRow(icon: "viewfinder", label: "ビネット", value: formatValue(vignette))
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
        }
    }

    private func editSettingRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.secondary)
            Text(label)
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .foregroundColor(.blue)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }

    private func formatValue(_ value: Float) -> String {
        let percentage = Int(value * 100)
        return percentage >= 0 ? "+\(percentage)%" : "\(percentage)%"
    }

    // MARK: - Post Info Section

    private var postInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // キャプション
            if let caption = post.caption {
                Text(caption)
                    .font(.body)
            }

            // ハッシュタグ
            if let hashtags = post.hashtags, !hashtags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(hashtags, id: \.self) { hashtag in
                            Text("#\(hashtag)")
                                .font(.body)
                                .foregroundColor(.blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(12)
                        }
                    }
                }
            }

            // 位置情報
            if let location = post.location {
                HStack {
                    Image(systemName: "location.fill")
                        .foregroundColor(.blue)
                    if let city = location.city, let prefecture = location.prefecture {
                        Text("\(prefecture) \(city)")
                            .font(.body)
                    }
                    if let landmark = location.landmark {
                        Text("（\(landmark)）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Sky Info Section

    private var skyInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let skyType = post.skyType {
                Label(skyType.displayName, systemImage: "cloud.fill")
                    .font(.body)
            }
            if let timeOfDay = post.timeOfDay {
                Label(timeOfDay.displayName, systemImage: "clock.fill")
                    .font(.body)
            }
            if let colorTemperature = post.colorTemperature {
                Label("\(colorTemperature)K", systemImage: "thermometer")
                    .font(.body)
            }
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        HStack(spacing: 24) {
            Label("\(post.likesCount)", systemImage: "heart.fill")
                .font(.headline)
            Label("\(post.commentsCount)", systemImage: "bubble.right.fill")
                .font(.headline)
        }
        .foregroundColor(.secondary)
    }

    // MARK: - Author Section

    private func authorSection(user: User) -> some View {
        HStack(spacing: 12) {
            // プロフィール画像
            if let photoURL = user.photoURL, let url = URL(string: photoURL) {
                KFImage(url)
                    .placeholder {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(
                                Image(systemName: "person.fill")
                                    .foregroundColor(.gray)
                            )
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 50, height: 50)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundColor(.gray)
                    )
            }

            // ユーザー情報
            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName ?? "ユーザー")
                    .font(.headline)

                if let email = user.email {
                    Text(email)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Gallery Detail Image View

struct GalleryDetailImageView: View {
    let imageInfo: ImageInfo

    var body: some View {
        // フルサイズ画像を表示
        if let imageURL = URL(string: imageInfo.url) {
            KFImage(imageURL)
                .placeholder {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            ProgressView()
                        )
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .cornerRadius(12)
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 300)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                )
                .cornerRadius(12)
        }
    }
}

// MARK: - Gallery Detail ViewModel

@MainActor
class GalleryDetailViewModel: ObservableObject {
    @Published var author: User?
    @Published var isLoadingAuthor = false
    @Published var errorMessage: String?

    private let firestoreService: FirestoreServiceProtocol

    init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.firestoreService = firestoreService
    }

    func loadAuthor(userId: String) async {
        isLoadingAuthor = true
        errorMessage = nil

        do {
            author = try await firestoreService.fetchUser(userId: userId)
        } catch {
            errorMessage = "投稿者情報の取得に失敗しました: \(error.localizedDescription)"
        }

        isLoadingAuthor = false
    }
}

struct GalleryDetailView_Previews: PreviewProvider {
    static var previews: some View {
        GalleryDetailView(post: Post(
            id: "preview",
            userId: "user1",
            images: [ImageInfo(url: "https://example.com/image.jpg", width: 100, height: 100, order: 0)],
            editSettings: EditSettings(brightness: 0.2, contrast: 0.1, saturation: -0.1, appliedFilter: .warm)
        ))
    }
}
