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
/// 上部の空タイプ切替（`selectedSkyType`）で選んだ空タイプ向けに
/// `EditViewModel.personalDefaultCandidatePool(for:)` を優先順に描画し、既に採用した画像と
/// 見た目で区別できる（`PersonalDefaultThumbnailComparer.isVisuallyDistinct`）候補だけを
/// 横スクロールカードとして採用していく。タップした候補は即座に
/// `applyPersonalDefaultCandidate(_:displayIndex:skyType:)` で適用してシートを閉じる。
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

    /// 現在選択中の空タイプ（空タイプ切替UI・G7）。
    /// nil は「切替UIを出す条件を満たさない、または『あなたの定番』側にフォールバックする」を意味する
    /// （`viewModel.personalDefaultCandidatePool(for:)` の nil 挙動に準拠）。
    @State private var selectedSkyType: SkyType?
    /// 見た目で選別した後の**採用済み**候補と、実際に描画したサムネイル画像のペア。
    /// これがそのままカードとして表示される「最終リスト」であり、表示順＝配列順＝
    /// `applyPersonalDefaultCandidate(_:displayIndex:skyType:)` に渡す `displayIndex` になる。
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
    /// 計装（`personal_default_candidates_shown`）を「空タイプごとに1回」だけ送るための既送信キー集合
    /// （G7: 単一 Bool フラグだったものを、空タイプ切替に対応するため Set に変更）。
    /// キーは `SkyType.rawValue`（未選択は `"none"`）。同じ空タイプに戻ってきたときの二重送信を防ぎつつ、
    /// 初めて見る空タイプに切り替えたときは改めて1回送る。
    @State private var loggedShownSkyTypeKeys: Set<String> = []

    /// 初期選択の空タイプは「サンプル数が最多の空タイプ」（`viewModel.selectableSkyTypes.first`）。
    /// 選べる空タイプが1つも無ければ nil（＝先頭候補は「あなたの定番」へフォールバックする）。
    /// シートが開かれる時点（＝「AIで自動編集」ボタンが表示できている時点）で
    /// `refreshPersonalDefaultAvailability()` は既に実行済みのため、初期値として素直に読める。
    init(viewModel: EditViewModel) {
        self.viewModel = viewModel
        _selectedSkyType = State(initialValue: viewModel.selectableSkyTypes.first)
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                skyTypeSwitcher
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
        // G7: 空タイプを切り替えるたびにサムネイルを再生成するため .task(id:) に変更
        // （導入前は「このシートは開いている間ずっと同一空タイプ扱い」だったため単発 .task で
        //  足りたが、切替UIの追加でその前提が崩れたため id 付きに変えて切替のたびに再起動する）。
        .task(id: selectedSkyType) {
            await regenerateCandidateThumbnails()
        }
    }

    // MARK: - 空タイプ切替（G7）

    /// 空タイプ切替の表示可否。
    ///
    /// ⚠️ 仕様は「`selectableSkyTypes` が空 かつ『あなたの定番』も作れない場合は出さない」だが、
    /// ここでは意図的に `viewModel.selectableSkyTypes.isEmpty` のみを条件にしている（狭める方向の
    /// 差分＝安全側の deviation）。理由: 切替UIの5ボタンは常に `selectableSkyTypes` の中身だけで
    /// 選択可否（グレー/選択可）が決まるため、「あなたの定番」が別途作れるかどうかに関わらず、
    /// `selectableSkyTypes` が空なら5ボタン全てが選べずグレーになる（例: 晴れ2件+夕焼け2件＝
    /// 計4件で全体の『あなたの定番』は成立するが、空タイプ別ではどちらも
    /// `minimumSamples`=3 未満で1つも選べない）。この状態で仕様どおり両条件のANDにすると
    /// 「5個グレーのボタンだけが並ぶ」を防ぎきれない。`selectableSkyTypes.isEmpty` 単独判定は
    /// 仕様の非表示条件を包含する superset（ANDが真ならこちらも必ず真）であり、かつ
    /// 「意味のない全グレーUI」を確実に防げるため、こちらを単一ソースとして採用した。
    private var showsSkyTypeSwitcher: Bool {
        !viewModel.selectableSkyTypes.isEmpty
    }

    @ViewBuilder
    private var skyTypeSwitcher: some View {
        if showsSkyTypeSwitcher {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(SkyType.allCases, id: \.self) { skyType in
                        skyTypeToggleButton(skyType)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .background(Color.white.opacity(0.15))
        }
    }

    /// 空タイプ切替ボタン1件。`viewModel.selectableSkyTypes` に含まれない空タイプは
    /// disabled + グレー表示にし、「履歴が溜まれば選べるようになる」ことが伝わるようにする。
    private func skyTypeToggleButton(_ skyType: SkyType) -> some View {
        let isSelectable = viewModel.selectableSkyTypes.contains(skyType)
        let isSelected = selectedSkyType == skyType
        return Button {
            guard isSelectable, selectedSkyType != skyType else { return }
            selectedSkyType = skyType
            // 空タイプ切替が実際に使われているかを運用で見るための計装（G7）。
            // 初期選択（init時点のデフォルト）はここを通らないため、ユーザーが実際に
            // タップして切り替えた操作だけが送られる。
            LoggingService.shared.logEvent("personal_default_sky_type_changed", parameters: [
                "sky_type": skyType.rawValue,
            ])
        } label: {
            Text(skyType.displayName)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundColor(isSelectable ? (isSelected ? .black : .white) : .white.opacity(0.3))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? Color.white : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        .accessibilityLabel(isSelectable ? "\(skyType.displayName)の定番に切り替え" : "\(skyType.displayName)は履歴不足のため選べません")
    }

    // MARK: - カード

    /// 採用済み候補 1 件分のカード（サムネイル + ラベル）。
    /// タップで即座に候補を適用してシートを閉じる
    /// （選び直したくなった場合は既存の編集画面 Undo が受け皿になる想定）。
    private func candidateCard(_ candidate: PersonalDefaultCandidate, image: UIImage, displayIndex: Int) -> some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            viewModel.applyPersonalDefaultCandidate(candidate, displayIndex: displayIndex, skyType: selectedSkyType)
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
    ///   race condition を防ぐ。G7 で空タイプ切替UIを追加したことで「このシートは開いている間
    ///   ずっと同一画像・同一候補プールを対象にする」という前提が崩れ、切替のたびに
    ///   このメソッドを再起動する必要が生まれた（呼び出し元は `.task(id: selectedSkyType)`）。
    ///   切替を連打した場合に古い空タイプ向けの生成結果が新しい表示を上書きしないよう、
    ///   世代トークンの重要度はむしろ導入前より上がっている。
    @MainActor
    private func regenerateCandidateThumbnails() async {
        // 0. このタスクが対象とする空タイプをここで1回だけ捕捉する（G7）。
        //    以降の await をまたいでも `selectedSkyType`（@State の最新値）を読み直さない。
        //    読み直すと、生成が完了するまでの間にユーザーが別の空タイプへ切り替えていた場合、
        //    「夕焼け向けに開始した生成が朝焼けとしてログされる」ような属性のズレが起きる
        //    （世代トークンは「古い結果で状態を上書きしない」ことは守るが、ログの sky_type 属性までは
        //    守ってくれないため、別途キャプチャが要る）。
        let targetSkyType = selectedSkyType

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

        // 6. 選択中の空タイプ向けプールを取得し（G7: skyType: nil 相当の後方互換プロパティではなく
        //    空タイプ別のプールを都度取得する）、優先順に順次描画して見た目で区別できる候補だけ
        //    採用する（並列 GPU 生成はしない）。1回だけ取得して使い回すことで pool_size ログとも
        //    同じ値を使う（呼び出しごとに結果が変わらない純関数だが、意図を明確にするため）。
        let pool = viewModel.personalDefaultCandidatePool(for: targetSkyType)
        for candidate in pool {
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
        // G7: 二重送信ガードは「空タイプごとに1回」に変わった（同じ空タイプへ戻ってきた場合は
        //    送らないが、まだ見ていない空タイプに切り替えたときは改めて1回送る）。
        let shownKey = targetSkyType?.rawValue ?? "none"
        guard isStillCurrent(), !Task.isCancelled, !loggedShownSkyTypeKeys.contains(shownKey) else { return }
        loggedShownSkyTypeKeys.insert(shownKey)
        let kinds = acceptedCandidates.map(\.candidate.kind.analyticsValue)
        LoggingService.shared.logEvent("personal_default_candidates_shown", parameters: [
            "candidate_count": kinds.count,
            "candidate_kinds": kinds.joined(separator: ","),
            // プール件数（選別前の母数）。「N件から M件に絞られた」を運用で追えるようにするため。
            "pool_size": pool.count,
            "sky_type": shownKey,
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
