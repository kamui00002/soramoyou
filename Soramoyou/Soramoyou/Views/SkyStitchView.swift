// ⭐️ SkyStitchView.swift
// 広角合成(v2)のプレビュー画面（無料）
//
//  Created on 2026-06-10.
//
//  UX:
//    合成中 → 成功プレビュー（この仕上がりで保存）→ onStitched に合成画像を渡して閉じる。
//    失敗時は撮り直し誘導のみ。
//  onStitched で受け取った1枚を呼び出し側(PostView)が通常の投稿パイプライン(EditView→PostInfoView→
//  savePost postKind=.panorama)へ流す。
//

import SwiftUI

struct SkyStitchView: View {
    /// 合成元の写真（2枚以上）
    let images: [UIImage]
    /// 合成が完了したときに、合成済み1枚を呼び出し側へ渡す。
    let onStitched: (UIImage) -> Void

    @StateObject private var viewModel: SkyStitchViewModel
    @Environment(\.dismiss) private var dismiss

    /// 撮り方のコツ（ヘルプシート）の表示状態
    @State private var showHelp = false

    /// 注入用 init（#Preview / テストで stub の viewModel を渡す）。
    init(images: [UIImage], onStitched: @escaping (UIImage) -> Void, viewModel: SkyStitchViewModel) {
        self.images = images
        self.onStitched = onStitched
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    /// 通常 init（本番）。@MainActor 文脈で SkyStitchViewModel() を生成する。
    @MainActor
    init(images: [UIImage], onStitched: @escaping (UIImage) -> Void) {
        self.init(images: images, onStitched: onStitched, viewModel: SkyStitchViewModel())
    }

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

                VStack(spacing: 16) {
                    shootingHint
                    content
                }
                .padding()
            }
            .navigationTitle("広角合成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                // 撮り方のコツ（図解）をいつでも開ける。
                // 「?」アイコンは意味が伝わりにくいので、テキストで明示する。
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("撮り方のコツ") { showHelp = true }
                        .accessibilityLabel("撮り方のコツ")
                }
            }
            .task {
                // 初回表示で合成を開始（idle のときだけ）
                if case .idle = viewModel.state {
                    await viewModel.runStitch(images)
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showHelp) {
            SkyStitchHelpView(onClose: { showHelp = false })
        }
    }

    /// 撮り方の案内（上下左右に振って重ねて4枚＝4隅撮り）。
    /// 重なりが大きいほど黒のない領域（内接矩形）が大きく取れる＝ワイドに仕上がる。
    private var shootingHint: some View {
        Text("上下左右に少しずつ振って、重ねながら4枚。重ねるほど広く仕上がります")
            .font(.caption)
            .foregroundColor(.white.opacity(0.85))
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .stitching:
            loadingCard(message: "空をつなげています…")
        case .previewReady(let image):
            previewCard(image: image)
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

    private func previewCard(image: UIImage) -> some View {
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

            Text("順番は自動でつなげました")
                .font(.caption)
                .foregroundColor(.white.opacity(0.85))

            Button(action: {
                // 合成画像を呼び出し側へ橋渡しし、本画面を閉じる
                onStitched(image)
                dismiss()
            }) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("この仕上がりで保存")
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
        }
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
                // runStitch 冒頭で .stitching に遷移するので、明示リセットは不要。
                Task { await viewModel.runStitch(images) }
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

// MARK: - Preview

#Preview("プレビュー成功") {
    let placeholder = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).image { ctx in
        UIColor.systemTeal.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
    }
    return SkyStitchView(
        images: [placeholder, placeholder],
        onStitched: { _ in },
        viewModel: SkyStitchViewModel(
            stitch: { _ in SkyStitchResult(status: .ok, image: placeholder) }
        )
    )
}
