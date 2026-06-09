// ⭐️ SkyStitchView.swift
// 広角合成(v2)のプレビュー＋課金画面
//
//  Created on 2026-06-10.
//
//  「成功時のみ課金」UX:
//    合成中 → 成功プレビュー（ここで初めて購入ボタンを出す）→ 購入成功で onStitched に合成画像を渡す。
//    失敗時は撮り直し誘導のみで購入ボタンを出さない（料金は発生しない旨を明示）。
//  onStitched で受け取った1枚を呼び出し側(PostView)が通常の投稿パイプライン(EditView→PostInfoView→
//  savePost postKind=.panorama)へ流す。
//

import SwiftUI

struct SkyStitchView: View {
    /// 合成元の写真（2枚以上）
    let images: [UIImage]
    /// 合成＋購入が完了したときに、合成済み1枚を呼び出し側へ渡す。
    let onStitched: (UIImage) -> Void

    @StateObject private var viewModel = SkyStitchViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.68, green: 0.85, blue: 0.90),
                        Color(red: 0.53, green: 0.81, blue: 0.98),
                        Color(red: 0.39, green: 0.58, blue: 0.93)
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                content
                    .padding()
            }
            .navigationTitle("広角合成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task {
                // 初回表示で合成を開始（idle のときだけ）
                if case .idle = viewModel.state {
                    await viewModel.runStitch(images)
                }
            }
            .task(id: isPurchased) {
                // 購入完了したら合成画像を呼び出し側へ橋渡しし、本画面を閉じる
                if let image = purchasedImage {
                    onStitched(image)
                    dismiss()
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    /// 購入完了状態か（.task(id:) のトリガ用）
    private var isPurchased: Bool {
        if case .purchased = viewModel.state { return true }
        return false
    }

    private var purchasedImage: UIImage? {
        if case .purchased(let img) = viewModel.state { return img }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .stitching:
            loadingCard(message: "空をつなげています…")
        case .previewReady(let image):
            previewCard(image: image)
        case .purchasing:
            loadingCard(message: "購入処理中…")
        case .purchased(let image):
            // 橋渡しは .task(id:) で行う。一瞬の表示。
            previewCard(image: image, purchasing: true)
        case .failed(let message):
            failedCard(message: message)
        }
    }

    private func loadingCard(message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.3)
            Text(message)
                .font(.headline)
                .foregroundColor(.white)
        }
    }

    private func previewCard(image: UIImage, purchasing: Bool = false) -> some View {
        VStack(spacing: 16) {
            Text("プレビュー")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            Text("この仕上がりで保存できます")
                .font(.caption)
                .foregroundColor(.white.opacity(0.85))

            Button(action: {
                Task { await viewModel.purchaseAndProceed() }
            }) {
                HStack {
                    Image(systemName: "sparkles")
                    Text(purchaseButtonTitle)
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.25))
                        .background(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.5), lineWidth: 1))
                )
            }
            .disabled(purchasing)

            Text("合成できなかった場合は料金は発生しません")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
        }
    }

    /// 価格が取れていれば「この仕上がりで保存（¥xxx）」、無ければ汎用文言。
    private var purchaseButtonTitle: String {
        if let price = viewModel.displayPrice {
            return "この仕上がりで保存（\(price)）"
        }
        return "この仕上がりで保存"
    }

    private func failedCard(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.9))
            Text(message)
                .font(.body)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Button(action: {
                Task {
                    viewModel.retry()
                    await viewModel.runStitch(images)
                }
            }) {
                Text("もう一度ためす")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.25)))
            }
            Button("写真を選び直す") { dismiss() }
                .foregroundColor(.white.opacity(0.9))
        }
    }
}
