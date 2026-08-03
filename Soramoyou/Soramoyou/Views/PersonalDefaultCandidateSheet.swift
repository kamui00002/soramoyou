// ⭐️ PersonalDefaultCandidateSheet.swift
// 「AIで自動編集」候補選択シート（柱1 v2）
//
// 従来の「AIで自動編集」ボタン（過去編集履歴全体の加重平均レシピ1本を即適用）を、
// 複数の編集パターン（あなたの定番 / 空タイプ別の定番 / 固定プリセット）から選んで
// 適用する方式に変えるための候補シート。
// タップ＝即適用（選び直しは既存 Undo が受け皿）という設計は、既存の
// `FilterButton`（EditView.swift）の慣習に合わせている。
//
//  そらもよう - 空を撮る、空を集める

import SwiftUI
import UIKit

// MARK: - PersonalDefaultCandidateSheet

/// 「AIで自動編集」候補選択シート本体。
///
/// `EditViewModel.personalDefaultCandidates` を横スクロールカードで並べ、
/// タップした候補を即座に `applyPersonalDefaultCandidate(_:)` で適用してシートを閉じる。
struct PersonalDefaultCandidateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: EditViewModel

    /// 候補サムネイルを生成するための ImageService。
    /// `EditViewModel` 内の imageService は private のため、`Style2DPadView` と同様に
    /// このシート専用の独自インスタンスを保持する。
    private let imageService: ImageServiceProtocol = ImageService()

    // MARK: - レイアウト定数

    /// カードのサムネイル一辺サイズ（pt）
    private let thumbDisplaySize: CGFloat = 140
    /// サムネイル生成時のピクセルサイズ（高 DPI 用）
    private let thumbGenerateSize = CGSize(width: 300, height: 300)

    // MARK: - 状態

    /// 生成済み候補サムネイルのキャッシュ。キー: `PersonalDefaultCandidate.id`
    @State private var candidateThumbnails: [String: UIImage] = [:]
    /// サムネイル生成中フラグ（UI のプレースホルダ表示用）
    @State private var isGeneratingThumbnails = false
    /// サムネイル生成の世代トークン（race condition 回避）。
    /// `Style2DPadView.regeneratePresetThumbnails()` と同じパターン:
    /// `ImageService.resizeImage` が detached continuation でキャンセル不能なため、
    /// 「結果反映前に自分の世代が最新か」を確認する世代制を最後の防衛線として使う。
    @State private var thumbnailGeneration: Int = 0

    // MARK: - Body

    var body: some View {
        NavigationView {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(viewModel.personalDefaultCandidates) { candidate in
                        candidateCard(candidate)
                    }
                }
                .padding(20)
            }
            .background(Color.black)
            .navigationTitle("パターンを選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") { dismiss() }
                        .foregroundColor(.white)
                }
            }
        }
        .navigationViewStyle(.stack)
        // 編集画面系（EditView / LivingSkySheet 等）が黒背景基調のため、トーンを揃える
        .preferredColorScheme(.dark)
        .task {
            await regenerateCandidateThumbnails()
        }
        .onAppear {
            // パーソナルAI編集の利用計装（柱1 v2 主要操作）。
            // PII を含まない安定文字列（`analyticsValue`）のみを送る。
            let kinds = viewModel.personalDefaultCandidates.map(\.kind.analyticsValue)
            LoggingService.shared.logEvent("personal_default_candidates_shown", parameters: [
                "candidate_count": kinds.count,
                "candidate_kinds": kinds.joined(separator: ","),
            ])
        }
    }

    // MARK: - カード

    /// 候補 1 件分のカード（サムネイル + ラベル）。
    /// タップで即座に候補を適用してシートを閉じる
    /// （選び直したくなった場合は既存の編集画面 Undo が受け皿になる想定）。
    private func candidateCard(_ candidate: PersonalDefaultCandidate) -> some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            viewModel.applyPersonalDefaultCandidate(candidate)
            dismiss()
        }) {
            VStack(spacing: 8) {
                candidateThumbnail(candidate)
                Text(candidate.label)
                    .font(.caption)
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.label) を適用")
    }

    /// サムネイル本体（生成済みならプレビュー画像、生成前は角丸プレースホルダ + ProgressView）。
    @ViewBuilder
    private func candidateThumbnail(_ candidate: PersonalDefaultCandidate) -> some View {
        ZStack {
            // 角丸の背景（画像未生成時のプレースホルダ兼用）
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.08))
                .frame(width: thumbDisplaySize, height: thumbDisplaySize)

            if let image = candidateThumbnails[candidate.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: thumbDisplaySize, height: thumbDisplaySize)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if isGeneratingThumbnails {
                ProgressView()
                    .tint(.white.opacity(0.5))
            }
        }
    }

    // MARK: - サムネイル生成

    /// 全候補分のサムネイルを非同期・逐次で生成する。
    ///
    /// - ベース画像は `viewModel.currentTransformedImageForThumbnails()`（向き正規化＋回転・反転
    ///   焼き込み済み）を使う。生画像をそのまま使うと `cropRectNorm` の切り出し基準
    ///   （回転・反転適用後の画像）とズレてしまうため。
    /// - 各候補は `mergingPhotoSpecificFields(from:includeSkyCorrection:)` で現在編集中の写真の
    ///   クロップ・トーンカーブ・ダイナミックレンジを合成してから描画する。
    ///   `includeSkyCorrection: false` にしているのは、このサムネイルは空マスクなし
    ///   （`applyEditRecipe(_:to:)` の skyMask 省略オーバーロード）で描画するため、
    ///   `skyCorrectionIntensity` を転写しても効果が反映されず
    ///   「レシピ上は補正が効いているのに見た目は変わらない」食い違いを生むのを避ける設計
    ///   （`EditRecipe.mergingPhotoSpecificFields` のコメント参照）。
    /// - `Style2DPadView.regeneratePresetThumbnails()` と同じ世代トークン方式で
    ///   race condition を防ぐ。このシートは開いている間ずっと同一画像を対象にするため、
    ///   `.task(id:)` ではなくシート表示ごとに 1 回だけ起動する単純な `.task` で足りる。
    @MainActor
    private func regenerateCandidateThumbnails() async {
        // 1. 自分の世代番号を払い出す（インクリメント）
        thumbnailGeneration &+= 1
        let myGeneration = thumbnailGeneration

        // 2. 既存キャッシュをクリアし生成中フラグを立てる
        candidateThumbnails = [:]
        isGeneratingThumbnails = true

        /// 自分が最新世代でなければ何もしない（古いタスクの状態書き換え防止）
        func isStillCurrent() -> Bool {
            myGeneration == thumbnailGeneration
        }

        // 完了時のクリーンアップ: 自分が最新世代の時だけフラグを下ろす
        defer {
            if isStillCurrent() {
                isGeneratingThumbnails = false
            }
        }

        // 3. ベース画像を取得（回転・反転焼き込み済み、クロップ・フィルター未適用）
        guard let baseImage = viewModel.currentTransformedImageForThumbnails() else { return }

        // 4. 共通の低解像度リサイズ画像を 1 度だけ生成
        let smallImage: UIImage
        do {
            smallImage = try await imageService.resizeImage(baseImage, maxSize: thumbGenerateSize)
        } catch {
            // リサイズ失敗時は元画像をそのまま使う（高画質だが遅くなる）
            smallImage = baseImage
        }

        // 5. リサイズ完了直後に世代チェック（resizeImage はキャンセル不能なので
        //    ここまで完走しているが、その間にシートが閉じられていれば離脱）
        guard isStillCurrent(), !Task.isCancelled else { return }

        // 6. 各候補を順次適用（並列 GPU 生成はしない）
        for candidate in viewModel.personalDefaultCandidates {
            // 各候補適用前に世代+キャンセルチェック
            guard isStillCurrent(), !Task.isCancelled else { return }

            let recipe = candidate.recipe.mergingPhotoSpecificFields(
                from: viewModel.editRecipe,
                includeSkyCorrection: false
            )

            do {
                let thumb = try await imageService.applyEditRecipe(recipe, to: smallImage)
                // 結果反映前にも世代チェック
                guard isStillCurrent(), !Task.isCancelled else { return }
                candidateThumbnails[candidate.id] = thumb
            } catch {
                // 個別候補の生成失敗は無視（プレースホルダ表示で継続）
                continue
            }
        }
    }
}

// MARK: - Preview

#Preview {
    // モックの EditViewModel を使ったプレビュー
    let vm = EditViewModel()
    return PersonalDefaultCandidateSheet(viewModel: vm)
}
