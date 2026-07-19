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
    /// 投稿情報入力画面へ渡すペイロード。
    /// `fullScreenCover(item:)` で提示することで、編集済み画像が確実に生成された後にのみ
    /// 画面が構築されるようにする（`isPresented` 方式だと SwiftUI が画像未生成のタイミングで
    /// PostInfoView を構築し、編集が反映されない素通し画像になる不具合があった）。
    @State private var postInfoPayload: PostInfoPayload?
    /// 最終画像の生成中フラグ（「次へ」連打による多重生成を防ぐ）
    @State private var isGeneratingFinal = false
    /// 編集ツール設定画面の表示フラグ
    @State private var showEditToolsSettings = false
    /// Living Sky（空を動かす）プレビューシートの表示フラグ。
    /// 元々はプロトタイプ確認用に #if DEBUG 限定で使っていたが、本番導線化に伴い常時使用する。
    @State private var showLivingSkySheet = false
    /// Living Sky 初回コーチマークの既読フラグ。
    /// `WhatsNewContent` の永続化キー群と同じ流儀で UserDefaults に永続化し、
    /// 一度タップ or ボタン押下で消したら以後表示しない。
    @AppStorage(WhatsNewContent.hasSeenLivingSkyCoachMarkKey) private var hasSeenLivingSkyCoachMark = false
    /// 回転スライダーの値（リアルタイム用）
    @State private var rotationSliderValue: Double = 0
    /// 「空を整える」Before/After 比較: 長押し中は true になり、オリジナル画像を表示する。
    @State private var isComparingSkyCorrectionOriginal = false

    private let userId: String?
    private let originalImages: [UIImage]
    /// 各画像の外部編集情報（写真Appバッジ表示用）⭐️ Issue #4
    private let externalEditInfos: [ExternalEditInfo?]
    /// 再編集（投稿済み画像の上書き更新）コンテキスト。非nil＝既存投稿を編集して上書き保存する。
    private let editingContext: PostEditingContext?
    /// 投稿種別（通常/配置写真/広角合成）。入口モードから引き継ぎ PostInfoView へ渡す。
    private let postKind: PostKind

    init(
        images: [UIImage],
        userId: String?,
        externalEditInfos: [ExternalEditInfo?] = [],
        initialRecipe: EditRecipe? = nil,
        editingContext: PostEditingContext? = nil,
        postKind: PostKind = .single
    ) {
        self.userId = userId
        self.originalImages = images
        self.externalEditInfos = externalEditInfos
        self.editingContext = editingContext
        self.postKind = postKind
        // initialRecipe: レシピ共有（他の投稿のレシピで編集）/ 再編集 から起動された場合の初期レシピ
        _viewModel = StateObject(wrappedValue: EditViewModel(
            images: images,
            userId: userId,
            initialRecipe: initialRecipe
        ))
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Apple Photos風の黒背景
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 画像プレビュー
                    imagePreviewView
                        // Living Sky（空を動かす）ボタン＋初回コーチマーク。
                        // ⚠️ 2026-07-18 一時撤収: 動きモデルを9バージョン検証したが実機の知覚品質が
                        //    出荷水準に達しなかったため、導線を DEBUG 限定へ再ゲートする
                        //    （経緯と将来方針=ML版: docs/research/living-sky-research-2026-07-part2-synthesis.md）。
                        //    エンジン・シェーダ・シート等のコード資産は全て温存（DEBUGで引き続き検証可能）。
                        // ⚠️ navigationBarTrailing に置くと項目数が5個になり iOS 26 が
                        // オーバーフローメニューに折りたたむため、toolbar には置かない（過去の教訓）。
#if DEBUG
                        .overlay(alignment: .bottom) {
                            livingSkyOverlay
                        }
#endif

                    // 「あなたの定番」適用ボタン（柱1 v1）— 見つけやすいよう編集コントロール直上に配置
                    if viewModel.hasPersonalDefault {
                        personalDefaultBar
                    }

                    // 「空を整える」ワンタップ空補正バー
                    skyCorrectionBar

                    // 編集コントロール（3タブ構成）
                    editControlsView
                }
            }
            .navigationTitle("編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        // Undo ボタン
                        Button(action: {
                            viewModel.undo()
                        }) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.body)
                        }
                        .disabled(!viewModel.canUndo)
                        .foregroundColor(viewModel.canUndo ? .white : .gray)

                        // Redo ボタン
                        Button(action: {
                            viewModel.redo()
                        }) {
                            Image(systemName: "arrow.uturn.forward")
                                .font(.body)
                        }
                        .disabled(!viewModel.canRedo)
                        .foregroundColor(viewModel.canRedo ? .white : .gray)

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
                            // 生成中の連打を防ぐ。generateFinalImages は isLoading を立てないため、
                            // 専用フラグでガードしないと重い画像生成が多重起動し、postInfoPayload が
                            // 複数回差し替わって PostInfoView が再構築される恐れがある。
                            guard !isGeneratingFinal else { return }
                            isGeneratingFinal = true
                            Task { @MainActor in
                                defer { isGeneratingFinal = false }
                                do {
                                    let finalImages = try await viewModel.generateFinalImages()
                                    // 画像生成完了後にペイロードをセット。これが nil でなくなった
                                    // ときだけ fullScreenCover が PostInfoView を構築する。
                                    postInfoPayload = PostInfoPayload(
                                        editedImages: finalImages,
                                        editSettings: viewModel.editSettings,
                                        editRecipe: viewModel.editRecipe
                                    )
                                } catch {
                                    viewModel.errorMessage = error.userFriendlyMessage
                                }
                            }
                        }
                        // ⭐️ レビュー指摘3対応: 空マスク生成中（isGeneratingSkyMask）も
                        // 無効化する。生成中に「次へ」を押すと、まだ確定していないマスクの
                        // 状態で書き出しが走ってしまう恐れがあるため。
                        .disabled(viewModel.isLoading || isGeneratingFinal || viewModel.isGeneratingSkyMask)
                        .foregroundColor(.white)
                    }
                }
            }
            .sheet(isPresented: $showEditToolsSettings, onDismiss: {
                Task {
                    await viewModel.loadEquippedTools()
                }
            }) {
                EditToolsSettingsView()
            }
            // Living Sky（空を動かす）: 現在の編集済みプレビュー画像を渡す。
            // 未生成（読み込み中など）の場合は元画像にフォールバックする。
            // ⚠️ 2026-07-18 一時撤収に伴い DEBUG 限定（上の overlay 側コメント参照）。
#if DEBUG
            .sheet(isPresented: $showLivingSkySheet) {
                if let sourceImage = viewModel.displayPreviewImage ?? viewModel.currentImage {
                    LivingSkySheet(sourceImage: sourceImage)
                }
            }
#endif
            .alert("エラー", isPresented: Binding(errorMessage: $viewModel.errorMessage)) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                }
            }
            .fullScreenCover(item: $postInfoPayload) { payload in
                NavigationView {
                    PostInfoView(
                        images: originalImages,
                        editedImages: payload.editedImages,
                        editSettings: payload.editSettings,
                        editRecipe: payload.editRecipe,
                        userId: userId,
                        externalEditInfos: externalEditInfos,
                        editingContext: editingContext,
                        postKind: postKind
                    )
                }
                .navigationViewStyle(.stack)
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .onAppear {
            Task {
                await viewModel.loadEquippedTools()
            }
        }
    }

    // MARK: - あなたの定番バー（柱1 v1）

    /// 「あなたの定番」を適用する目立つボタン。
    /// ツールバーのアイコンでは見つけにくかったため、編集コントロール直上に大きく配置する。
    /// コーパスに十分な学習データがあるときだけ表示する。
    private var personalDefaultBar: some View {
        Button {
            viewModel.applyPersonalDefault()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                Text("AIで自動編集")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: DesignTokens.Colors.accentGradient,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            )
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.sm)
        .accessibilityLabel("AIで自動編集")
    }

    // MARK: - 空を整えるバー（ワンタップ空補正） ⭐️

    /// 空補正が未適用（`skyCorrectionIntensity` が nil/0）なら「空を整える」ボタンを、
    /// 適用済みなら強度スライダーを表示する。
    @ViewBuilder
    private var skyCorrectionBar: some View {
        // ⭐️ レビュー指摘5対応: しきい値判定を viewModel.isSkyCorrectionActive に一元化
        // （FilterGraphBuilder.neutralValueThreshold と同じ運用値を使う単一ソース）。
        if viewModel.isSkyCorrectionActive {
            skyCorrectionSliderBar
        } else {
            skyCorrectionButtonBar
        }
    }

    /// 「空を整える」ワンタップボタン。タップすると空マスクを生成し、見つかれば強度 0.7 で適用する。
    private var skyCorrectionButtonBar: some View {
        Button {
            Task {
                await viewModel.applySkyCorrection()
            }
        } label: {
            HStack(spacing: 6) {
                if viewModel.isGeneratingSkyMask {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "cloud.sun")
                }
                Text("空を整える")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Color.white.opacity(0.15)))
        }
        .disabled(viewModel.isGeneratingSkyMask)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.sm)
        .accessibilityLabel("空を整える")
    }

    /// 空補正の強度スライダー（0...1）。長押しで Before/After 比較ができる旨は
    /// プレビュー画像側（`skyCorrectionCompareOverlay`）で処理する。
    private var skyCorrectionSliderBar: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "cloud.sun.fill")
                    .foregroundColor(.white.opacity(0.8))
                Text("空を整える")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                Text("\(Int(viewModel.skyCorrectionIntensityValue * 100))%")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .monospacedDigit()

                Button {
                    viewModel.removeSkyCorrection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                }
                .accessibilityLabel("空補正を解除")
            }

            Slider(
                value: Binding(
                    get: { viewModel.skyCorrectionIntensityValue },
                    set: { viewModel.updateSkyCorrectionIntensityRealtime($0) }
                ),
                in: 0...1,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        viewModel.finalizeSkyCorrectionIntensity()
                    }
                }
            )
            .tint(.white)
            .accentColor(.white)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.sm)
    }

    // MARK: - Image Preview View

    private var imagePreviewView: some View {
        ZStack {
            // Apple Photos風の黒背景
            Color.black

            // 切り取りタブでは「クロップ前」のオリジナル画像 + 矩形オーバーレイを表示
            // それ以外は「編集後プレビュー」を表示
            if selectedTab == .crop {
                cropEditorPreview
            } else {
                normalPreviewContent
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

    // MARK: - Preview Content Helpers

    @ViewBuilder
    private var normalPreviewContent: some View {
        if viewModel.isLoading && !viewModel.isEditingRealtime {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
        } else if let displayImage = viewModel.displayPreviewImage {
            // ⭐️ レビュー指摘4対応: 空補正 Before/After 比較の対象は「未編集の元画像」
            // （viewModel.currentImage）ではなく、「現在のレシピから skyCorrectionIntensity
            // だけ nil にした状態」（viewModel.skyCorrectionCompareImage、同じ変換・クロップ
            // 経路でレンダリング済み）にする。長押し開始時に viewModel.prepareSkyCorrectionCompareImage()
            // が生成する（skyCorrectionCompareOverlay の onChange 参照）。未生成（読み込み中）
            // の間は現在のプレビューにフォールバックする。
            let shownImage = (isComparingSkyCorrectionOriginal ? viewModel.skyCorrectionCompareImage : nil) ?? displayImage
            Image(uiImage: shownImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(HDRDynamicRangeModifier())
                .overlay(skyCorrectionCompareOverlay)
        } else if let currentImage = viewModel.currentImage {
            Image(uiImage: currentImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(HDRDynamicRangeModifier())
        } else {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
        }
    }

    /// 「空を整える」適用中のみ有効な Before/After 比較用の透明ボタン。
    /// DragGesture/LongPressGesture ではなく ButtonStyle の isPressed で長押しを検知することで、
    /// 他のジェスチャー（画像切替ボタン等）との競合を避ける（HomeView.CardButtonStyle と同じ設計判断）。
    @ViewBuilder
    private var skyCorrectionCompareOverlay: some View {
        // ⭐️ レビュー指摘5対応: しきい値判定を viewModel.isSkyCorrectionActive に一元化。
        if viewModel.isSkyCorrectionActive {
            Button(action: {}) {
                Color.clear
            }
            .buttonStyle(SkyCorrectionCompareButtonStyle(isComparing: $isComparingSkyCorrectionOriginal))
            .accessibilityLabel("長押しで補正前の画像を表示")
            // ⭐️ レビュー指摘8対応: 長押しジェスチャーは VoiceOver 利用時に実行しづらいため、
            // ローターから呼べる明示的なアクションとして同じトグル操作を提供する。
            .accessibilityAction(named: "補正前と比較") {
                isComparingSkyCorrectionOriginal.toggle()
            }
            // ⭐️ レビュー指摘4対応: 比較 ON への切り替わり（長押し開始 or アクセシビリティ
            // アクション経由のトグル ON）のたびに 1 回だけ「補正前」画像を生成する。
            .onChange(of: isComparingSkyCorrectionOriginal) { isComparing in
                if isComparing {
                    Task {
                        await viewModel.prepareSkyCorrectionCompareImage()
                    }
                }
            }
        }
    }

    /// 切り取り編集モードのプレビュー（クロップ前の画像 + ドラッグ可能な矩形オーバーレイ）
    ///
    /// 🔧 2026-04-24 修正 (ultrareview bug_003):
    /// currentImage ではなく currentImageForCrop（applyTransform 適用済み）を使う。
    /// こうしないと回転・反転を行った後にトリミングすると、UI で選んだ領域と最終出力で
    /// 切り出される領域がまったく違う場所になる。
    @ViewBuilder
    private var cropEditorPreview: some View {
        if let image = viewModel.currentImageForCrop {
            GeometryReader { geo in
                cropEditorBody(image: image, geoSize: geo.size)
            }
        } else {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
        }
    }

    /// GeometryReader の中身を分離（複雑な let 宣言を含むため）
    private func cropEditorBody(image: UIImage, geoSize: CGSize) -> some View {
        let imageAspect = image.size.width / max(image.size.height, 1)
        let viewAspect  = geoSize.width / max(geoSize.height, 1)
        let drawWidth: CGFloat
        let drawHeight: CGFloat
        if imageAspect > viewAspect {
            drawWidth  = geoSize.width
            drawHeight = geoSize.width / imageAspect
        } else {
            drawHeight = geoSize.height
            drawWidth  = geoSize.height * imageAspect
        }
        let imageRect = CGRect(
            x: (geoSize.width  - drawWidth)  / 2,
            y: (geoSize.height - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )

        return ZStack(alignment: .topLeading) {
            Color.black

            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: drawWidth, height: drawHeight)
                .position(x: geoSize.width / 2, y: geoSize.height / 2)
                .modifier(HDRDynamicRangeModifier())

            CropOverlayView(
                imageRect: imageRect,
                cropRectNorm: Binding(
                    get: { viewModel.editRecipe.cropRectNorm ?? CGRect(x: 0, y: 0, width: 1, height: 1) },
                    set: { newValue in
                        viewModel.updateCropRect(newValue, finalize: false)
                    }
                ),
                aspectRatio: viewModel.cropAspectRatio.ratio,
                onEditEnd: {
                    if let rect = viewModel.editRecipe.cropRectNorm {
                        viewModel.updateCropRect(rect, finalize: true)
                    }
                }
            )
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
        .background(Color.black)
    }

    // MARK: - Tab Content View

    @ViewBuilder
    private var tabContentView: some View {
        switch selectedTab {
        case .filter:
            filterContentView
        case .adjustment:
            adjustmentContentView
        case .style:
            styleContentView
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
                        // 切り取りタブ遷移時、クロップ矩形が未設定 or フル画面のままだと
                        // オーバーレイ（白枠・ハンドル）が画像の端に重なって視認できないため、
                        // 少し内側にインセットした既定矩形をセットして「トリミング UI がある」
                        // ことをユーザーに伝える。
                        if tab == .crop {
                            viewModel.ensureVisibleCropRect()
                        }
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
        .background(Color.black)
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
            // ツール選択中の表示
            if let tool = selectedTool {
                if tool == .curves {
                    // カーブ調整ツール: ToneCurveView を表示
                    toneCurveEditorView
                } else {
                    improvedSliderView(tool: tool)
                }
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
                                    // 現在の値をスライダーに反映（有効範囲にクランプ）
                                    let raw = viewModel.editSettings.value(for: tool) ?? 0
                                    let range = tool.sliderRange
                                    sliderValue = min(max(raw, range.lowerBound), range.upperBound)
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
        }
        .frame(minHeight: selectedTool == .curves ? 280 : (selectedTool != nil ? 180 : 100))
    }

    // MARK: - Tone Curve Editor View

    /// カーブ調整ツール用のトーンカーブエディター
    private var toneCurveEditorView: some View {
        VStack(spacing: 8) {
            // ヘッダー
            HStack {
                Text(EditTool.curves.displayName)
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // ToneCurveView（Binding でリアルタイム更新、ドラッグ終了時に Undo 履歴へ積む）
            ToneCurveView(
                points: Binding(
                    get: { viewModel.editRecipe.toneCurvePoints ?? ToneCurvePoints() },
                    set: { newPoints in
                        // ドラッグ開始時のスナップショットをキャプチャ（Undo 用）
                        viewModel.capturePreDragSnapshot()
                        viewModel.editRecipe.toneCurvePoints = newPoints
                        // スライダーと同じスロットリング付き高速プレビュー経路を走らせる
                        // （毎フレーム generatePreview を叩くとフル解像度の同期レンダが詰まり
                        //  画面が固まって見える不具合を回避）
                        viewModel.triggerRealtimePreview()
                    }
                ),
                onEditEnd: {
                    viewModel.finalizeToolValue(for: .curves)
                }
            )
            .frame(height: 220)
            .padding(.horizontal)
        }
    }

    // MARK: - Improved Slider View (目盛り付き)

    private func improvedSliderView(tool: EditTool) -> some View {
        VStack(spacing: 8) {
            // ヘッダー（ツール名・現在値・リセット）
            HStack {
                Text(tool.displayName)
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                // 現在値の表示
                Text(formatSliderValue(sliderValue))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
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
                // 目盛り（片側スライダのツールでは 0 を左端に寄せた見た目に）
                TickMarksView(isBidirectional: tool.sliderRange.lowerBound < 0)

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
                    in: tool.sliderRange,
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
        .background(Color.black)
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

    // MARK: - Style Content View (2D スタイルパッド) ⭐️

    /// 「スタイル」タブのコンテンツ: 2D パッドで「トーン × カラー」を同時調整
    ///
    /// - 単独で `Style2DPadView` を表示するシンプル構成
    /// - 既存の adjustmentContentView と違ってツール装備（5〜8 個選択）の影響を受けない
    ///   常時利用可能な機能
    private var styleContentView: some View {
        Style2DPadView(viewModel: viewModel)
            .padding(.horizontal)
    }

    // MARK: - Crop Content View (切り取り)

    private var cropContentView: some View {
        VStack(spacing: 16) {
            // 回転スライダー
            VStack(spacing: 8) {
                HStack {
                    Text("回転")
                        .font(.headline)
                        .foregroundColor(.white)

                    Spacer()

                    Text(String(format: "%.1f°", rotationSliderValue))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
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

    // MARK: - Living Sky Overlay（本番UI）

    /// Living Sky ボタン＋初回コーチマークをまとめたオーバーレイ本体。
    /// Metal 非対応端末（`LivingSkyEngine.isSupported == false`）ではボタンごと非表示にする
    /// （設計書§1「Metal 必須: kernel ロード失敗時はフォールバックせず機能を非表示」）。
    ///
    /// @ViewBuilder のサブビューに分割しているのは、EditView.body 直下に条件分岐や複雑な
    /// 修飾子チェーンを増やすと型チェックが爆発する（プロジェクト既知の "unable to type-check" 罠）
    /// のを避けるため。
    @ViewBuilder
    private var livingSkyOverlay: some View {
        if LivingSkyEngine.isSupported {
            VStack(spacing: 8) {
                if !hasSeenLivingSkyCoachMark {
                    livingSkyCoachMark
                }
                livingSkyButton
            }
            .padding(.bottom, 20)
            // 消える/現れるときは控えめなフェードのみ（バウンシーな演出は使わない）。
            .animation(.easeInOut(duration: 0.3), value: hasSeenLivingSkyCoachMark)
        }
    }

    /// Living Sky シートを開くカプセルボタン（風アイコン＋「空を動かす」ラベル）。
    /// 既存の丸ボタン（旧 DEBUG 版）と同トーンの半透明黒背景を踏襲する。
    private var livingSkyButton: some View {
        Button {
            // コーチマークを表示中にボタンを直接押した場合も「既読」として消す
            // （吹き出し自身をタップした場合と同じ扱い＝仕様どおり両方が既読条件）。
            hasSeenLivingSkyCoachMark = true
            showLivingSkySheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wind")
                Text("空を動かす")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.5))
            .clipShape(Capsule())
            // 横長写真ではプレビュー枠の下部が黒帯（レターボックス）になり、半透明黒の
            // カプセルが背景に溶けて輪郭が消える（シミュレータ目視で確認）。写真の上でも
            // 黒帯の上でも成立するよう、白の細枠でカプセルの輪郭を常時確保する。
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        }
        .accessibilityLabel("空を動かす")
    }

    /// Living Sky 初回コーチマーク（吹き出し）。ボタンの直上に表示する。
    /// 吹き出し自身をタップしても「既読」として消える。
    private var livingSkyCoachMark: some View {
        VStack(spacing: 0) {
            Text("空が動く写真を作れるようになりました！")
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.75))
                .cornerRadius(10)
                // カプセルボタンと同じ理由（黒帯上で輪郭が消える）で吹き出しにも白の細枠を付ける。
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))

            // 吹き出しの尻尾（下向き三角）
            LivingSkyCoachMarkTail()
                .fill(Color.black.opacity(0.75))
                .frame(width: 14, height: 7)
        }
        .transition(.opacity)
        .onTapGesture {
            hasSeenLivingSkyCoachMark = true
        }
    }

}

// MARK: - Living Sky Coach Mark Tail（吹き出しの尻尾）

/// Living Sky コーチマークの吹き出し用「尻尾」の下向き三角形。
/// プロジェクト内に類似シェイプが無かったため、この用途専用の最小限実装として追加する。
private struct LivingSkyCoachMarkTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - HDR Dynamic Range Modifier

/// Phase 1 #L: EDR（Extended Dynamic Range）対応の View 変換子。
/// iOS 17+ で `.allowedDynamicRange(.high)` を適用し、HDR 写真を XDR ディスプレイで
/// 「光るハイライト」として表示する。対応端末以外では自動的に SDR にフォールバックする。
private struct HDRDynamicRangeModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.allowedDynamicRange(.high)
        } else {
            content
        }
    }
}

// MARK: - Sky Correction Compare Button Style ⭐️
// DragGesture/LongPressGesture の代わりに ButtonStyle を使用し、他のジェスチャーとの競合を回避
// （HomeView.CardButtonStyle と同じ設計判断）

/// 「空を整える」の Before/After 比較用ボタンスタイル。
/// 押している間だけ `isComparing` を true にし、離すと false に戻る（=長押し検知）。
private struct SkyCorrectionCompareButtonStyle: ButtonStyle {
    @Binding var isComparing: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            // ⚠️ アプリのデプロイターゲットは iOS 16 のため、iOS 17+ 限定の
            // 2引数版 onChange ではなく旧来の1引数版を使う（他ファイルの onChange と同じ流儀）。
            .onChange(of: configuration.isPressed) { pressed in
                isComparing = pressed
            }
    }
}

// MARK: - Tick Marks View (目盛り)

struct TickMarksView: View {
    /// 両側スライダ（-1.0...+1.0）かどうか
    ///
    /// false のとき 0...+1.0 の片側スライダとして扱い、
    /// 強調ティック（長い白線）を中央ではなく左端に配置する。
    var isBidirectional: Bool = true

    /// 目盛りの数（21本: -100〜+100 または 0〜+100、5%刻み）
    private let tickCount = 21

    var body: some View {
        GeometryReader { _ in
            HStack(spacing: 0) {
                ForEach(0..<tickCount, id: \.self) { index in
                    let highlightIndex = isBidirectional ? tickCount / 2 : 0
                    let isHighlightTick = index == highlightIndex

                    Rectangle()
                        .fill(isHighlightTick ? Color.white : Color.white.opacity(0.3))
                        .frame(width: isHighlightTick ? 2 : 1,
                               height: isHighlightTick ? 16 : 8)

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
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        }) {
            VStack(spacing: DesignTokens.Spacing.sm) {
                ZStack {
                    // 選択時のグロー
                    if isSelected {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                            .fill(DesignTokens.Colors.selectionAccent.opacity(0.3))
                            .frame(width: 68, height: 68)
                            .blur(radius: 8)
                    }

                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                        .fill(
                            isSelected
                                ? LinearGradient(
                                    colors: DesignTokens.Colors.accentGradient,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.1), Color.white.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                        )
                        .frame(width: 60, height: 60)
                        .overlay(
                            Text(displayName.prefix(2))
                                .font(.system(size: DesignTokens.Typography.captionSize, weight: .bold, design: .rounded))
                                .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                                .stroke(
                                    isSelected
                                        ? Color.white.opacity(0.5)
                                        : Color.white.opacity(0.15),
                                    lineWidth: 1
                                )
                        )
                        .shadow(isSelected ? DesignTokens.Shadow.medium : DesignTokens.Shadow.soft)
                }

                Text(displayName)
                    .font(.system(size: DesignTokens.Typography.smallCaptionSize, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(DesignTokens.Animation.bouncySpring, value: isSelected)
    }
}

// MARK: - Tool Button

struct ToolButton: View {
    let tool: EditTool
    let isSelected: Bool
    let hasValue: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        }) {
            VStack(spacing: 6) {
                ZStack {
                    // 選択時のグロー
                    if isSelected {
                        Circle()
                            .fill(DesignTokens.Colors.selectionAccent.opacity(0.3))
                            .frame(width: 52, height: 52)
                            .blur(radius: 6)
                    }

                    Circle()
                        .fill(
                            isSelected
                                ? DesignTokens.Colors.selectionAccent.opacity(0.2)
                                : (hasValue ? DesignTokens.Colors.sunsetOrange.opacity(0.15) : Color.white.opacity(0.1))
                        )
                        .frame(width: 46, height: 46)
                        .overlay(
                            Image(systemName: iconName(for: tool))
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(
                                    isSelected
                                        ? DesignTokens.Colors.selectionAccent
                                        : (hasValue ? DesignTokens.Colors.sunsetOrange : .white.opacity(0.6))
                                )
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    isSelected
                                        ? DesignTokens.Colors.selectionAccent.opacity(0.5)
                                        : (hasValue ? DesignTokens.Colors.sunsetOrange.opacity(0.3) : Color.white.opacity(0.15)),
                                    lineWidth: 1
                                )
                        )

                    // 値がある場合のインジケーター
                    if hasValue && !isSelected {
                        Circle()
                            .fill(DesignTokens.Colors.sunsetOrange)
                            .frame(width: 8, height: 8)
                            .offset(x: 18, y: -18)
                    }
                }

                Text(tool.displayName)
                    .font(.system(size: DesignTokens.Typography.tabLabelSize, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundColor(
                        isSelected
                            ? DesignTokens.Colors.selectionAccent
                            : .white.opacity(0.6)
                    )
                    .lineLimit(1)
                    .frame(width: 60)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.08 : 1.0)
        .animation(DesignTokens.Animation.bouncySpring, value: isSelected)
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

// MARK: - PostInfoPayload

/// EditView から PostInfoView へ渡す編集結果のペイロード。
///
/// `fullScreenCover(item:)` で使うため `Identifiable` に準拠する。
/// 編集済み画像が生成されてから初めて生成されるため、PostInfoView は
/// 常に空でない `editedImages` を受け取れる（素通し画像になる不具合の根本対策）。
struct PostInfoPayload: Identifiable {
    let id = UUID()
    let editedImages: [UIImage]
    let editSettings: EditSettings
    let editRecipe: EditRecipe
}

// MARK: - Preview

struct EditView_Previews: PreviewProvider {
    static var previews: some View {
        EditView(images: [], userId: nil)
    }
}
