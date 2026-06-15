//
//  FeedbackView.swift ☁️⭐️
//  Soramoyou
//
//  アプリ内フィードバック送信画面（設定 → ご意見・ご要望）
//  Firestore `feedback` コレクションに保存。アプリの世界観に合わせたグラスデザイン。
//

import SwiftUI

/// フィードバック入力・送信画面
struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = FeedbackViewModel()

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: DesignTokens.Colors.daySkyGradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    if viewModel.didSubmit {
                        successView
                    } else {
                        formView
                    }
                }
            }
            .navigationTitle("ご意見・ご要望")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { dismiss() }
                        .foregroundColor(.white)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Form

    private var formView: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text("アプリへのご意見・ご要望・不具合報告をお送りください。いただいた声は今後の改善に活かします。")
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textSecondary)

            // 種別
            VStack(alignment: .leading, spacing: 6) {
                Text("種類")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                Picker("種類", selection: $viewModel.category) {
                    ForEach(FeedbackCategory.allCases) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                .pickerStyle(.segmented)
            }

            // 本文（直接束縛 — インライン Binding(get:set:) は実機で入力が壊れるため使わない）
            VStack(alignment: .leading, spacing: 6) {
                Text("内容")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                TextField("不具合の状況や、こうなったら嬉しい等を書いてください…",
                          text: $viewModel.message, axis: .vertical)
                    .font(.system(size: 15, design: .rounded))
                    .lineLimit(5...12)
                    .disabled(viewModel.isSending)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
                            )
                    )

                // 文字数
                Text("\(viewModel.message.count)/\(viewModel.maxLength)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(viewModel.message.count > viewModel.maxLength ? .red : DesignTokens.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .monospacedDigit()
            }

            // エラー表示
            if let error = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                }
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(.red.opacity(0.9))
            }

            // 送信ボタン
            Button {
                Task { await viewModel.submit() }
            } label: {
                HStack {
                    if viewModel.isSending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                        Text("送信する")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            canSubmit
                            ? LinearGradient(colors: [DesignTokens.Colors.skyBlue, DesignTokens.Colors.selectionAccent], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
                        )
                )
            }
            .disabled(!canSubmit || viewModel.isSending)
        }
        .padding()
    }

    /// 送信可能か（空でなく上限内）
    private var canSubmit: Bool {
        let trimmed = viewModel.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && viewModel.message.count <= viewModel.maxLength
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(colors: [DesignTokens.Colors.skyBlue, DesignTokens.Colors.selectionAccent], startPoint: .top, endPoint: .bottom)
                )

            Text("送信しました")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textPrimary)

            Text("貴重なご意見をありがとうございます。\n今後の改善に活かします。")
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                dismiss()
            } label: {
                Text("閉じる")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(colors: [DesignTokens.Colors.skyBlue, DesignTokens.Colors.selectionAccent], startPoint: .leading, endPoint: .trailing))
                    )
            }
            .padding(.top, DesignTokens.Spacing.md)
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

#Preview {
    FeedbackView()
}
