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
/// `EditViewModel.personalDefaultCandidatePool` を優先順に描画し、既に採用した画像と
/// 見た目で区別できる（`PersonalDefaultThumbnailComparer.isVisuallyDistinct`）候補だけを
/// 横スクロールカードとして採用していく。タップした候補は即座に
/// `applyPersonalDefaultCandidate(_:displayIndex:)` で適用してシートを閉じる。
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

    /// 見た目で選別した後の**採用済み**候補と、実際に描画したサムネイル画像のペア。
    /// これがそのままカードとして表示される「最終リスト」であり、表示順＝配列順＝
    /// `applyPersonalDefaultCandidate(_:displayIndex:)` に渡す `displayIndex` になる。
    /// 候補と画像を1つの配列に持つことで、辞書 + プール参照方式だと起きがちな
    /// 「選別後の候補と画像の対応ズレ」を構造的に防ぐ。
    @State private var acceptedCandidates: [(candidate: PersonalDefaultCandidate, image: UIImage)] = []
    /// サムネイル生成中フラグ（末尾 ProgressView の表示用）
    @State private var isGeneratingThumbnails = false
    /// サムネイル生成の世代トークン（race condition 回避）。
    /// `Style2DPadView.regeneratePresetThumbnails()` と同じパターン:
    /// `ImageService.resizeImage` が detached continuation でキャンセル不能なため、
    /// 「結果反映前に自分の世代が最新か」を確認する世代制を最後の防衛線として使う。
    @State private var thumbnailGeneration: Int = 0
    /// 計装（`personal_default_candidates_shown`）を一度だけ送るためのフラグ。
    /// 選別完了時（`regenerateCandidateThumbnails()` の末尾）に一度だけ送るため、
    /// `.task` が同一シートインスタンスで複数回走った場合の二重送信を防ぐ
    /// （`PostInfoView.hasGeneratedFallback` と同じ流儀）。
    @State private var hasLoggedShown = false

    // MARK: - Body

    var body: some View {
        NavigationView {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(acceptedCandidates.enumerated()), id: \.element.candidate.id) { index, entry in
                        candidateCard(entry.candidate, image: entry.image, displayIndex: index)
                    }
                    if isGeneratingThumbnails {
                        ProgressView()
                            .tint(.white.opacity(0.5))
                            .frame(width: thumbDisplaySize, height: thumbDisplaySize)
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
    }

    // MARK: - カード

    /// 採用済み候補 1 件分のカード（サムネイル + ラベル）。
    /// タップで即座に候補を適用してシートを閉じる
    /// （選び直したくなった場合は既存の編集画面 Undo が受け皿になる想定）。
    private func candidateCard(_ candidate: PersonalDefaultCandidate, image: UIImage, displayIndex: Int) -> some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            viewModel.applyPersonalDefaultCandidate(candidate, displayIndex: displayIndex)
            dismiss()
        }) {
            VStack(spacing: 8) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: thumbDisplaySize, height: thumbDisplaySize)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(candidate.label)
                    .font(.caption)
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.label) を適用")
    }

    // MARK: - サムネイル生成 + 描画後の見た目選別

    /// 候補プールを優先順に描画し、見た目で区別できる候補だけを `acceptedCandidates` へ採用していく。
    ///
    /// 従来（プール導入前）は「候補一覧をそのまま全部描画して表示する」だけだったが、
    /// `PersonalDefaultCandidateProvider.candidatePool(from:)` がレシピの数値差だけで
    /// 重複排除した打ち切りなしのプール（最大11件程度）を返すようになったため、
    /// 「レシピは違うが描画すると見た目はほぼ同じ」候補まで並んでしまう。これを防ぐため、
    /// ここで実際に描画してから `PersonalDefaultThumbnailComparer.isVisuallyDistinct` で
    /// 見た目の重複を判定し、選ばれた候補だけをカードとして表示する。
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

        // 2. 既存の採用リストをクリアし生成中フラグを立てる
        acceptedCandidates = []
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

        // 6. プールを優先順に順次描画し、見た目で区別できる候補だけ採用する（並列 GPU 生成はしない）。
        for candidate in viewModel.personalDefaultCandidatePool {
            // 採用数が上限に達したら、プールを最後まで見ずに打ち切る。
            guard acceptedCandidates.count < PersonalDefaultCandidateProvider.maxCandidateCount else { break }
            // 各候補描画前に世代+キャンセルチェック
            guard isStillCurrent(), !Task.isCancelled else { return }

            let recipe = candidate.recipe.mergingPhotoSpecificFields(
                from: viewModel.editRecipe,
                includeSkyCorrection: false
            )

            do {
                let thumb = try await imageService.applyEditRecipe(recipe, to: smallImage)
                // 結果反映前にも世代チェック
                guard isStillCurrent(), !Task.isCancelled else { return }

                let acceptedImages = acceptedCandidates.map(\.image)
                if PersonalDefaultThumbnailComparer.isVisuallyDistinct(thumb, from: acceptedImages) {
                    acceptedCandidates.append((candidate: candidate, image: thumb))
                }
                // 区別できない（見た目が既採用と同じ）候補は捨てて次のプール要素へ進む。
            } catch {
                // 個別候補の描画失敗は捨てて次の候補へ（既存挙動を維持）
                continue
            }
        }

        // 7. 選別完了時点で「実際に表示された件数・種類」を計装する。
        //    onAppear 即時ではなく、選別が終わったこの時点で 1 回だけ送る
        //    （プール全体ではなく、見た目選別後の実際の表示件数・種類を送るため）。
        //    defer に置かないのは、世代切れ・ベース画像取得失敗などの早期 return でも
        //    発火してしまい「表示していないものを表示した」と誤記録するのを避けるため。
        guard isStillCurrent(), !Task.isCancelled, !hasLoggedShown else { return }
        hasLoggedShown = true
        let kinds = acceptedCandidates.map(\.candidate.kind.analyticsValue)
        LoggingService.shared.logEvent("personal_default_candidates_shown", parameters: [
            "candidate_count": kinds.count,
            "candidate_kinds": kinds.joined(separator: ","),
            // プール件数（選別前の母数）。「N件から M件に絞られた」を運用で追えるようにするため。
            "pool_size": viewModel.personalDefaultCandidatePool.count,
        ])
    }
}

// MARK: - Preview

#Preview {
    // モックの EditViewModel を使ったプレビュー。
    // `EditViewModel.init()` は images が空だと loadEquippedTools()（内部で
    // refreshPersonalDefaultAvailability() を呼ぶ）を起動しないため、呼ばないと
    // personalDefaultCandidatePool が空のまま＝候補ゼロで何も描画されない。
    // ここで明示的に呼び、履歴ゼロ→固定プリセット全件がプールに入る状態にする。
    // ⚠️ ただし images が空のため `currentTransformedImageForThumbnails()` が nil を返し、
    // `regenerateCandidateThumbnails()` は描画前に早期 return する
    // （＝ acceptedCandidates は空のまま。このプレビューはカードもプレースホルダも
    // 描画されない空のシートになる。実機の見た目を確認したい場合は images 付きの
    // EditViewModel を渡すこと）。
    let vm = EditViewModel()
    vm.refreshPersonalDefaultAvailability()
    return PersonalDefaultCandidateSheet(viewModel: vm)
}
