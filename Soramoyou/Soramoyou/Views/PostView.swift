//
//  PostView.swift ⭐️
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SkyCamera
import SwiftUI

struct PostView: View {
    @StateObject private var viewModel: PhotoSelectionViewModel
    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var showEditView = false
    /// 広角合成(.panorama)のプレビュー画面の表示フラグ。
    @State private var showStitch = false
    /// 広角合成の「撮り方のコツ」ガイド（写真を選ぶ前に読める導線）の表示フラグ。
    @State private var showStitchGuide = false
    /// 合成が完了した広角画像（stitch 画面を閉じた後に EditView へ渡す）。
    @State private var pendingStitched: UIImage?
    /// 投稿モード（通常/配置写真/広角合成）。配置写真・広角合成は4枚固定・ログイン必須。
    @State private var postKind: PostKind = .single
    /// 空カメラ（アプリ内カメラ）の表示フラグ。
    @State private var showCamera = false
    /// 空カメラの権限が無いときに出す案内アラートの表示フラグ。
    @State private var showCameraDeniedAlert = false
    /// 撮影した1枚（カメラが閉じ切ってから編集画面へ渡すため、いったんここで預かる）。
    @State private var pendingCaptured: (image: UIImage, info: ExternalEditInfo)?
    /// 編集画面へ引き継ぐ写真の出どころ（計装のみ）。ライブラリから選び直したら .library に戻る。
    @State private var photoSource: PhotoSource = .library

    init() {
        // 認証状態に応じて最大選択数を設定
        // 実際の認証状態は環境オブジェクトから取得するため、初期値は10に設定
        _viewModel = StateObject(wrappedValue: PhotoSelectionViewModel(maxSelectionCount: 10))
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

                VStack(spacing: 0) {
                    ZStack {
                        if viewModel.selectedImages.isEmpty {
                            // 写真選択画面
                            photoSelectionView
                        } else {
                            // 選択された写真のプレビュー
                            photoPreviewView
                        }
                    }
                    
                    // 画面下部に固定表示されるバナー広告
                    BannerAdContainer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    GradientTitleView(title: "投稿", fontSize: 20)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .sheet(isPresented: $viewModel.isShowingImagePicker) {
                ImagePicker(
                    selectedImages: $viewModel.selectedImages,
                    pickedMetadata: $viewModel.pickedMetadata,
                    maxSelectionCount: maxSelectionCount,
                    onSelectionComplete: {
                        viewModel.isShowingImagePicker = false
                        // ライブラリから選び直したら出どころは .library に戻す（計装の取り違え防止）。
                        photoSource = .library
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
            .fullScreenCover(isPresented: $showEditView, onDismiss: {
                // 編集画面から戻ったら選択をクリア
                viewModel.clearSelection()
            }) {
                EditView(
                    images: viewModel.selectedImages,
                    userId: authViewModel.currentUser?.id,
                    externalEditInfos: viewModel.pickedMetadata,
                    postKind: postKind,
                    photoSource: photoSource
                )
            }
            // 広角合成(v2): 合成プレビュー。閉じた後、合成済み1枚で EditView を開く。
            .fullScreenCover(isPresented: $showStitch, onDismiss: {
                if let stitched = pendingStitched {
                    pendingStitched = nil
                    viewModel.selectedImages = [stitched]   // 合成済み1枚を投稿パイプラインへ
                    // 合成画像は端末内で生成した新規画像で、特定の素材 1 枚に紐づかない。
                    // 素材 1 枚目の外部編集情報（EXIF 撮影日時を含む）を合成画像に付けないよう空にする。
                    viewModel.pickedMetadata = []
                    showEditView = true
                }
            }) {
                SkyStitchView(images: viewModel.selectedImages) { stitched in
                    // 合成完了（保存ボタン）→ 合成画像を保持して stitch 画面を閉じる（onDismiss で EditView へ）
                    pendingStitched = stitched
                    showStitch = false
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            updateMaxSelectionCount()
        }
        .onChange(of: authViewModel.isAuthenticated) { _ in
            // ログアウトで配置写真が使えなくなったら通常モードへ戻す（無効な選択を残さない）
            if !availableKinds.contains(postKind) {
                postKind = .single
            }
            updateMaxSelectionCount()
        }
    }
    
    /// 配置写真・広角合成は「ちょうど4枚」が要件（判定は PostKind.isComposite に集約）。
    private var requiresFourPhotos: Bool {
        postKind.isComposite
    }

    /// 選択可能枚数。4枚モードは 4 固定（ピッカー生成前に確定が必須）。
    private var maxSelectionCount: Int {
        if requiresFourPhotos { return 4 }
        return authViewModel.isAuthenticated ? 10 : 3
    }

    private func updateMaxSelectionCount() {
        viewModel.updateMaxSelectionCount(maxSelectionCount)
    }

    /// 投稿モードを切り替える。
    /// モードで枚数上限が変わり、PHPicker の selectionLimit は生成時に固定されるため、
    /// ここで必ず updateMaxSelectionCount を呼んでピッカーを開く前に確定させる（重要）。
    private func selectMode(_ kind: PostKind) {
        guard postKind != kind else { return }
        postKind = kind
        updateMaxSelectionCount()
        LoggingService.shared.logEvent("post_mode_selected", parameters: ["mode": kind.rawValue])
    }

    /// 空カメラを開く。権限が拒否・制限されているときは既存の作法どおり
    /// 「設定を開く」付きのアラートへ倒す（アプリからは権限を戻せないため）。
    private func startCamera() {
        switch SkyCameraAvailability.authorization {
        case .denied, .restricted:
            showCameraDeniedAlert = true
            // 開けなかったことも分母として残す（権限で離脱した人数が見えるように）。
            CameraCaptureService.log(
                event: .opened(authorization: SkyCameraAvailability.authorization)
            )
        case .authorized, .notDetermined:
            // ⚠️ 前回の撮影が「閉じる」と競合して預かり箱に残っていた場合、
            //    次に開いて閉じた瞬間に古い写真で編集画面が開いてしまう。開く前に必ず空にする。
            pendingCaptured = nil
            // 未決定の場合のシステムプロンプトは SkyCameraView 側で出す
            //（プレビューを見せながら要求した方が許可率が高い）。
            showCamera = true
        }
    }

    /// 選べる投稿モード（配置写真・広角合成はログイン必須＝未ログインでは通常のみ）。
    private var availableKinds: [PostKind] {
        authViewModel.isAuthenticated ? [.single, .collage, .panorama] : [.single]
    }

    /// 4枚モードで「ちょうど4枚」を満たしているか。
    private var isPhotoCountReady: Bool {
        !requiresFourPhotos || viewModel.selectedImages.count == 4
    }

    /// プレビューで「この写真たちがどうなるか」を伝えるヒント（通常モードは無し）。
    private var previewModeHint: String? {
        switch postKind {
        case .collage:  return "この4枚をタイル状に並べて1枚にします"
        case .panorama: return "この4枚を1枚の広い空に合成します（上下左右に少しずつ振って、重ねて撮るのがコツ）"
        case .single:   return nil
        }
    }

    // MARK: - モード別の表示文言

    private var modeIconName: String {
        switch postKind {
        case .collage:  return "square.grid.2x2"
        case .panorama: return "pano"
        case .single:   return "photo.on.rectangle"
        }
    }

    private var modeTitle: String {
        switch postKind {
        case .collage:  return "配置写真をつくる"
        case .panorama: return "広角合成をつくる"
        case .single:   return "写真を選択"
        }
    }

    private var modeDescription: String {
        switch postKind {
        case .collage:  return "好きな空を4枚選んで1枚に並べます。同じ空の朝・昼・夕・夜で「空の一日」も（合成はしません）"
        case .panorama: return "上下左右に少しずつ振って、重ねながら撮った空4枚を、1枚の広い空に合成します（順番は自動）"
        case .single:   return "空の写真を選択して投稿しましょう"
        }
    }

    /// モード別のアクセントカラー（選択チップの淡い色分け用・主役は写真なので控えめに）。
    private func modeAccent(_ kind: PostKind) -> Color {
        switch kind {
        case .single:   return Color(red: 0.39, green: 0.58, blue: 0.93)  // 空の青
        case .collage:  return Color(red: 0.30, green: 0.70, blue: 0.60)  // タイル＝青緑
        case .panorama: return Color(red: 0.95, green: 0.62, blue: 0.36)  // 横長＝夕焼けオレンジ
        }
    }

    /// モード別アイコン（チップ用・「並べる」と「横に繋ぐ」を形で区別）。
    private func modeChipIcon(_ kind: PostKind) -> String {
        switch kind {
        case .single:   return "photo"
        case .collage:  return "square.grid.2x2"
        case .panorama: return "pano"
        }
    }
    
    // MARK: - Photo Selection View
    
    private var photoSelectionView: some View {
        VStack(spacing: 24) {
            // 投稿モード選択（配置写真・広角合成はログイン必須＝未ログインでは表示しない）
            if availableKinds.count > 1 {
                HStack(spacing: 8) {
                    ForEach(availableKinds) { kind in
                        PostModeChip(
                            title: kind.displayName,
                            icon: modeChipIcon(kind),
                            accent: modeAccent(kind),
                            isSelected: postKind == kind,
                            action: { selectMode(kind) }
                        )
                    }
                }
                .padding(.horizontal)
                // segmented Picker を自作チップに置換したため、VoiceOver のグループ文脈を明示的に補う
                // （各チップは .isSelected トレイトを保持。.contain で子要素を個別操作可能なまま束ねる）。
                .accessibilityElement(children: .contain)
                .accessibilityLabel("投稿モード")
            }

            Image(systemName: modeIconName)
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.8))

            Text(modeTitle)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            Text(modeDescription)
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // 広角合成モードのときだけ、写真を選ぶ「前」に読める撮り方ガイドへの導線。
            // 合成画面（撮影後）の「？」では遅い、という声を受けて中央に置く。
            if postKind == .panorama {
                Button(action: { showStitchGuide = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle")
                        Text("撮り方のコツ")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(.white.opacity(0.18))
                            .overlay(Capsule().stroke(.white.opacity(0.45), lineWidth: 1))
                    )
                }
                // sheet はボタン自身に付与する。
                // body 直下の .sheet×1 + .fullScreenCover×2 と同じ階層に重ねると
                // 表示状態の取り違え（stale-state）で誤った画面が出ることがあるため、ここで局所化する。
                .sheet(isPresented: $showStitchGuide) {
                    SkyStitchHelpView(onClose: { showStitchGuide = false })
                }
                .accessibilityHint("広角合成の撮り方ガイドを開きます")
            }

            Button(action: {
                // ライブラリから選び直したら出どころは .library に戻す（計装の取り違え防止）。
                photoSource = .library
                viewModel.startPhotoSelection()
            }) {
                HStack {
                    Image(systemName: "photo.on.rectangle")
                    Text("写真を選択")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.25))
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(.white.opacity(0.5), lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
            }
            .padding(.horizontal)

            // 空カメラ（アプリ内カメラ）への導線。
            // 単写モードのときだけ出す（配置写真・広角合成は複数枚が前提のため）。
            // 背面カメラが無い環境（シミュレータ）では導線ごと隠す。
            if postKind == .single && SkyCameraAvailability.isAvailable {
                Button(action: { startCamera() }) {
                    HStack {
                        Image(systemName: "camera.fill")
                        Text("撮る")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.white.opacity(0.18))
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(.white.opacity(0.45), lineWidth: 1)
                            )
                    )
                }
                .padding(.horizontal)
                .accessibilityHint("グリッドと水平線ガイド付きのカメラで空を撮ります")
                // ⚠️ cover と alert は body 直下ではなく**このボタンに局所付与**する。
                //    body 直下には既に .sheet×1 + .fullScreenCover×2 があり、同じ階層に重ねると
                //    表示状態の取り違え（stale-state）で誤った画面が出ることがあるため。
                .fullScreenCover(isPresented: $showCamera, onDismiss: {
                    // カメラが閉じ切ってから編集画面を開く（cover の二重表示を避ける）。
                    // 広角合成の合成プレビュー経路（body 直下の showStitch）と同じ作法。
                    if let captured = pendingCaptured {
                        pendingCaptured = nil
                        viewModel.selectedImages = [captured.image]
                        // selectedImages と pickedMetadata は index 対応の並列配列。1枚ずつ積む。
                        viewModel.pickedMetadata = [captured.info]
                        photoSource = .camera
                        showEditView = true
                    }
                }) {
                    SkyCameraView(
                        onCapture: { capture in
                            // ⚠️ ここは `Task {}` で包まない。包むと呼び出し元がすぐ戻ってしまい、
                            //    保存の最中に閉じるボタンが有効になって撮れた 1 枚が消える。
                            //    `async` のまま await されることで、処理中は撮影中扱いが続く。
                            // 写真ライブラリ保存・計装・向きの焼き込みはサービスに任せる。
                            if let processed = await CameraCaptureService.process(capture: capture) {
                                pendingCaptured = processed
                            }
                            showCamera = false
                        },
                        onCancel: { showCamera = false },
                        onEvent: { event in CameraCaptureService.log(event: event) }
                    )
                }
                .alert("カメラを使えません", isPresented: $showCameraDeniedAlert) {
                    Button("設定を開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("設定アプリの「そらもよう」からカメラへのアクセスを許可してください。")
                }
            }

            VStack(spacing: 8) {
                Text("選択可能な枚数")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                
                Text(requiresFourPhotos
                     ? "ちょうど4枚を選んでください"
                     : (authViewModel.isAuthenticated ? "最大10枚" : "最大3枚（ログインで10枚まで）"))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))

                if postKind == .single && !authViewModel.isAuthenticated {
                    Text("配置写真・広角合成はログインで使えます")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.top)
        }
        .padding()
    }
    
    // MARK: - Photo Preview View
    
    private var photoPreviewView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // この写真たちが「どうなるか」をモード別に明示（並べる / 横に繋ぐ の取り違え防止）
                if let hint = previewModeHint {
                    HStack(spacing: 8) {
                        Image(systemName: modeChipIcon(postKind))
                            .font(.system(size: 16))
                        Text(hint)
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(modeAccent(postKind).opacity(0.35))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.3), lineWidth: 1))
                    )
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                // 選択された写真のグリッド表示
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(Array(viewModel.selectedImages.enumerated()), id: \.offset) { index, image in
                        PhotoPreviewItem(
                            image: image,
                            index: index,
                            onRemove: {
                                viewModel.removeImage(at: index)
                            }
                        )
                    }
                }
                .padding()
                
                // 4枚モードで枚数不足のときのガイド
                if requiresFourPhotos && !isPhotoCountReady {
                    Text("ちょうど4枚を選んでください（今 \(viewModel.selectedImages.count) 枚）")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal)
                }

                // アクションボタン
                VStack(spacing: 12) {
                    Button(action: {
                        // 広角合成は合成プレビューへ。それ以外は編集画面へ。
                        if postKind == .panorama {
                            showStitch = true
                        } else {
                            showEditView = true
                        }
                    }) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("次へ")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.white.opacity(0.25))
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(.white.opacity(0.5), lineWidth: 1)
                                )
                        )
                        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
                    }
                    .disabled(viewModel.isLoading || viewModel.selectedImages.isEmpty || !isPhotoCountReady)
                    
                    Button(action: {
                        viewModel.clearSelection()
                    }) {
                        Text("選択をクリア")
                            .font(.body)
                            .foregroundColor(.white.opacity(0.9))
                    }
                    
                    Button(action: {
                        viewModel.startPhotoSelection()
                    }) {
                        Text("写真を追加")
                            .font(.body)
                            .foregroundColor(.white)
                    }
                    .disabled(viewModel.selectedImages.count >= maxSelectionCount)
                }
                .padding()
            }
        }
    }
}

// MARK: - Photo Preview Item

struct PhotoPreviewItem: View {
    let image: UIImage
    let index: Int
    let onRemove: () -> Void
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 150)
                .clipped()
                .cornerRadius(8)
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
            }
            .padding(8)
        }
    }
}

// MARK: - Post Mode Chip

/// 投稿モード選択チップ（通常／配置写真／広角合成）。
/// アイコン＋ラベル＋選択時の淡いアクセント色で、モードの違いを「色だけに頼らず」伝える。
struct PostModeChip: View {
    let title: String
    let icon: String
    let accent: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.75))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? accent.opacity(0.85) : .white.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.white.opacity(0.55) : Color.white.opacity(0.25), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .accessibilityLabel("\(title)モード")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct PostView_Previews: PreviewProvider {
    static var previews: some View {
        PostView()
            .environmentObject(AuthViewModel())
    }
}


