//
//  DraftsView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import Kingfisher

struct DraftsView: View {
    @StateObject private var viewModel = DraftsViewModel()
    @State private var selectedDraft: Draft?
    @State private var showingDeleteConfirmation = false
    @State private var draftToDelete: Draft?
    
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

                if viewModel.isLoading && viewModel.drafts.isEmpty {
                    // 初回読み込み中
                    VStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("読み込み中...")
                            .foregroundColor(.white)
                    }
                } else if viewModel.drafts.isEmpty {
                    // 下書きがない場合
                    emptyDraftsView
                } else {
                    // 下書き一覧
                    draftsList
                }
            }
            .navigationTitle("下書き")
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !viewModel.drafts.isEmpty {
                        EditButton()
                            .foregroundColor(.white)
                    }
                }
            }
            .onAppear {
                Task {
                    await viewModel.loadDrafts()
                }
            }
            .refreshable {
                await viewModel.loadDrafts()
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
            .alert("下書きを削除", isPresented: $showingDeleteConfirmation) {
                Button("キャンセル", role: .cancel) {
                    draftToDelete = nil
                }
                Button("削除", role: .destructive) {
                    if let draft = draftToDelete {
                        Task {
                            await viewModel.deleteDraft(draft)
                        }
                    }
                    draftToDelete = nil
                }
            } message: {
                Text("この下書きを削除しますか？")
            }
            .sheet(item: $selectedDraft) { draft in
                DraftDetailView(draft: draft)
            }
        }
    }
    
    // MARK: - Empty Drafts View
    
    private var emptyDraftsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.6))
            Text("下書きがありません")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
            Text("投稿画面で下書きを保存できます")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
    }
    
    // MARK: - Drafts List
    
    private var draftsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.drafts) { draft in
                    DraftRow(draft: draft)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.white.opacity(0.2))
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(.white.opacity(0.3), lineWidth: 1)
                                )
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedDraft = draft
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                draftToDelete = draft
                                showingDeleteConfirmation = true
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                }
            }
            .padding()
        }
    }
}

// MARK: - Draft Row

struct DraftRow: View {
    let draft: Draft
    
    var body: some View {
        HStack(spacing: 12) {
            // サムネイル画像
            draftThumbnail
            
            // 下書き情報
            VStack(alignment: .leading, spacing: 4) {
                // キャプションまたはプレースホルダー
                if let caption = draft.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.body)
                        .lineLimit(2)
                } else {
                    Text("キャプションなし")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .italic()
                }
                
                // ハッシュタグ
                if let hashtags = draft.hashtags, !hashtags.isEmpty {
                    Text(hashtags.prefix(3).map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundColor(.blue)
                        .lineLimit(1)
                }
                
                // 更新日時
                Text(formatDate(draft.updatedAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // 編集済みアイコン
            if draft.editedImages != nil || draft.editSettings != nil {
                Image(systemName: "pencil.circle.fill")
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var draftThumbnail: some View {
        Group {
            // 編集済み画像があればそれを使用、なければ元画像
            let imageInfo = draft.editedImages?.first ?? draft.images.first
            
            if let imageInfo = imageInfo, !imageInfo.url.isEmpty, let url = URL(string: imageInfo.url) {
                KFImage(url)
                    .placeholder {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay(
                                ProgressView()
                            )
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipped()
                    .cornerRadius(8)
            } else {
                // ローカル画像の場合（下書きではURLが空の可能性がある）
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                    )
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: date)
    }
}

// MARK: - Draft Detail View

struct DraftDetailView: View {
    let draft: Draft
    @Environment(\.dismiss) private var dismiss
    @State private var loadedImages: [UIImage] = []
    @State private var isLoadingImages = false
    @State private var showEditView = false
    @State private var showPostInfoView = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            ZStack {
                if isLoadingImages {
                    ProgressView("画像を読み込み中...")
                } else if loadedImages.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "photo")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        Text("画像を読み込めませんでした")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        if let errorMessage = errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            // 下書き情報
                            draftInfoSection
                            
                            // アクションボタン
                            actionButtons
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("下書き")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadDraftImages()
            }
            .fullScreenCover(isPresented: $showEditView) {
                EditView(images: loadedImages, userId: draft.userId)
            }
            .fullScreenCover(isPresented: $showPostInfoView) {
                PostInfoView(
                    images: loadedImages,
                    editedImages: [],
                    editSettings: draft.editSettings ?? EditSettings(),
                    userId: draft.userId
                )
            }
            .alert("エラー", isPresented: .constant(errorMessage != nil)) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                }
            }
        }
    }
    
    private var draftInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 画像プレビュー
            if let firstImage = loadedImages.first {
                Image(uiImage: firstImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 300)
                    .cornerRadius(12)
            }
            
            // キャプション
            if let caption = draft.caption, !caption.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("キャプション")
                        .font(.headline)
                    Text(caption)
                        .font(.body)
                }
            }
            
            // ハッシュタグ
            if let hashtags = draft.hashtags, !hashtags.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ハッシュタグ")
                        .font(.headline)
                    Text(hashtags.map { "#\($0)" }.joined(separator: " "))
                        .font(.body)
                        .foregroundColor(.blue)
                }
            }
            
            // 位置情報
            if let location = draft.location {
                VStack(alignment: .leading, spacing: 4) {
                    Text("位置情報")
                        .font(.headline)
                    if let city = location.city, let prefecture = location.prefecture {
                        Text("\(prefecture) \(city)")
                            .font(.body)
                    }
                }
            }
            
            // 公開設定
            VStack(alignment: .leading, spacing: 4) {
                Text("公開設定")
                    .font(.headline)
                Text(draft.visibility.displayName)
                    .font(.body)
            }
            
            // 編集済みかどうか
            if draft.editedImages != nil || draft.editSettings != nil {
                HStack {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundColor(.blue)
                    Text("編集済み")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
        }
    }
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            // 編集画面へ
            Button(action: {
                showEditView = true
            }) {
                HStack {
                    Image(systemName: "pencil")
                    Text("編集画面で続ける")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .cornerRadius(12)
            }
            
            // 投稿情報入力画面へ
            Button(action: {
                showPostInfoView = true
            }) {
                HStack {
                    Image(systemName: "info.circle")
                    Text("投稿情報入力画面へ")
                }
                .font(.headline)
                .foregroundColor(.blue)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)
            }
        }
    }
    
    private func loadDraftImages() {
        isLoadingImages = true
        errorMessage = nil
        
        // 下書きの画像URLから画像を読み込む
        // 注意: 下書きには画像のURLが含まれていない可能性があるため、
        // 実際の実装では、下書き保存時に画像をStorageに保存し、URLを保持する必要がある
        // ここでは、画像URLが存在する場合のみ読み込む
        
        let imageUrls = draft.editedImages?.map { $0.url } ?? draft.images.map { $0.url }
        
        guard !imageUrls.isEmpty else {
            errorMessage = "下書きに画像が含まれていません"
            isLoadingImages = false
            return
        }
        
        // 画像を非同期で読み込む
        Task {
            var images: [UIImage] = []
            
            for urlString in imageUrls {
                guard !urlString.isEmpty,
                      let url = URL(string: urlString) else {
                    continue
                }
                
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let image = UIImage(data: data) {
                        images.append(image)
                    }
                } catch {
                    // 画像の読み込みに失敗した場合、エラーを記録
                    await MainActor.run {
                        errorMessage = "画像の読み込みに失敗しました: \(error.localizedDescription)"
                    }
                }
            }
            
            await MainActor.run {
                loadedImages = images
                isLoadingImages = false
                
                if images.isEmpty {
                    errorMessage = "画像を読み込めませんでした"
                }
            }
        }
    }
}

struct DraftsView_Previews: PreviewProvider {
    static var previews: some View {
        DraftsView()
    }
}

