//
//  PostPhotoViewer.swift ⭐️
//  Soramoyou
//
//  投稿の詳細の写真をタップすると開く、全画面の写真ビューア
//  1.18.0 PR-H「5b: 投稿の詳細の写真を全画面で見る」
//
//  詳細（HomeView.swift の PostDetailView）のカルーセルの写真を 1 回タップすると、
//  その 1 枚だけを黒い背景の全画面で開く。
//  - 2 本の指でつまんで広げる（ピンチ）と、最大 4 倍まで大きくできる
//  - 大きくしている間は、指 1 本で写真をずらせる（写真の端が画面の内側へ入りこむところまでは、ずらさない）
//  - 等倍のときに指 1 本で下へ引っぱると閉じる（引っぱった距離か、指を離したときの勢いで決める）
//  - 右上の ✕ でも閉じる。VoiceOver では「2 本指で Z を書く」操作（エスケープ）でも閉じる
//
//  決めたこと（利用者の決定 2026-10-28）:
//  - 複数枚の投稿でも、ビューアの中ではめくらない（タップした 1 枚だけを見せる）
//  - 開いたことを計装する（`post_photo_viewer_opened`・何枚目か／全部で何枚か。UID は送らない）
//    → 送るのは詳細の側（PostDetailView の `openPhotoViewer`）。ここは parameters の形だけを持つ
//  - 2 回タップでの拡大は付けない（PR-H の仕様）
//
//  計算（拡大率・ずらしの上限・閉じるかどうか など）は `PostPhotoViewerMath` に切り出して、
//  単体テスト（`PostPhotoViewerMathTests`）で固定する。View（`PostPhotoViewer`）は、その計算の結果を
//  描くことと、指の動きを受け取ることだけを持つ。
//
//  ピンチとずらしの書き方は、そらともの投稿の詳細（SoratomoSkyDetailView の `zoomableImage`）を手本にしている。
//  ただし手本は、ずらしを画面の端で止めていない（指を離すまで、生の値で描いている）。
//  ここでは**描く値にも上限・下限を掛ける**ので、写真が画面の外へ飛んでいくことがない。
//

import Kingfisher
import SwiftUI

// MARK: - ビューアに渡すもの

/// 全画面のビューアで開く 1 枚（`fullScreenCover(item:)` に渡す）
///
/// `fullScreenCover(item:)` は `Identifiable` を要求するので、写真の情報に番号を付けて包む。
struct PostPhotoViewerItem: Identifiable {
    /// カルーセルの何ページ目か（0 始まり。1 枚目は 0）
    let id: Int
    /// 開く写真の情報
    let imageInfo: ImageInfo
}

// MARK: - 計算（テストする）

/// 全画面のビューアの計算をまとめたもの（どれも入力だけで答えが決まる＝単体テストで固定する）
enum PostPhotoViewerMath {
    // MARK: - 定数

    /// 拡大率の下限（等倍より小さくしない）
    static let minScale: CGFloat = 1
    /// 拡大率の上限（そらともの投稿の詳細 SoratomoSkyDetailView と同じ 4 倍）
    static let maxScale: CGFloat = 4
    /// これだけ下へ引っぱってから指を離したら閉じる（pt）
    static let dismissDistance: CGFloat = 120
    /// 引っぱりが短くても、指を離したときの勢いで、ここまで進みそうなら閉じる（pt）
    static let dismissPredictedDistance: CGFloat = 240
    /// 引っぱっている間に写真を縮めていく距離（ここまで引くと一番小さくなり、それより先は縮めない・pt）
    static let dismissShrinkDistance: CGFloat = 400
    /// 引っぱっている間の、一番小さい大きさ（等倍に掛ける。0.85 = 85%）
    static let dismissMinScale: CGFloat = 0.85

    // MARK: - ドラッグの使い道

    /// 指のドラッグを何に使うか
    enum DragMode {
        /// 大きくしている写真をずらす
        case pan
        /// 下へ引っぱって閉じる
        case dismiss
        /// 何もしない（等倍でピンチしている最中。2 本の指が下へ動いただけで閉じてしまわないようにする）
        case ignore
    }

    /// 拡大率を、下限（等倍）と上限（4 倍）の中に収める
    /// - Parameter scale: 収める前の拡大率
    /// - Returns: 1〜4 の中に収めた拡大率
    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minScale), maxScale)
    }

    /// 今のドラッグを何に使うかを決める
    ///
    /// - 大きくしている（等倍より大きい）→ ずらす（ピンチ中でも、指の動きに写真がついてくるほうが自然なので、ずらす）
    /// - 等倍でピンチの最中 → 何もしない（2 本の指の動きを「閉じる引っぱり」と取り違えない）
    /// - 等倍 → 下へ引っぱって閉じる
    /// - Parameters:
    ///   - scale: 確定している拡大率（ピンチ中の変化は掛けない値）
    ///   - isPinching: ピンチの最中か
    /// - Returns: ドラッグの使い道
    static func dragMode(scale: CGFloat, isPinching: Bool) -> DragMode {
        if scale > minScale {
            return .pan
        }
        return isPinching ? .ignore : .dismiss
    }

    // MARK: - 大きさ

    /// 写真の縦横比（幅 ÷ 高さ）を出す
    ///
    /// 古い投稿など、幅か高さが 0（以下）で記録されているときは比を出せないので nil を返す
    /// （0 で割ると無限大になり、写真の枠が壊れるため）。
    /// - Parameters:
    ///   - width: 写真の幅（ImageInfo の width）
    ///   - height: 写真の高さ（ImageInfo の height）
    /// - Returns: 縦横比。出せないときは nil
    static func aspectRatio(width: Int, height: Int) -> CGFloat? {
        guard width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }

    /// 写真を、入れ物（画面）の中に全体が収まる一番大きな大きさにする（aspect fit）
    ///
    /// - 写真のほうが入れ物より横長 → 幅を入れ物に合わせ、高さを比から決める
    /// - 写真のほうが入れ物より縦長 → 高さを入れ物に合わせ、幅を比から決める
    /// - 縦横比が分からない（nil）→ 入れ物の大きさのまま（中の画像は SwiftUI の `.aspectRatio(.fit)` で収める）
    ///
    /// 縦向き・横向きのどちらでも、入れ物の大きさが変われば答えも変わる（回転したら計算し直す）。
    /// - Parameters:
    ///   - aspectRatio: 写真の縦横比（幅 ÷ 高さ）
    ///   - containerSize: 入れ物の大きさ
    /// - Returns: 写真を描く大きさ
    static func fittedSize(aspectRatio: CGFloat?, in containerSize: CGSize) -> CGSize {
        guard let aspectRatio, aspectRatio > 0,
              containerSize.width > 0, containerSize.height > 0
        else {
            return containerSize
        }
        let containerRatio = containerSize.width / containerSize.height
        if aspectRatio > containerRatio {
            // 入れ物より横長: 幅いっぱい（上下に黒い余白ができる）
            return CGSize(width: containerSize.width, height: containerSize.width / aspectRatio)
        } else {
            // 入れ物より縦長（または同じ比）: 高さいっぱい（左右に黒い余白ができる）
            return CGSize(width: containerSize.height * aspectRatio, height: containerSize.height)
        }
    }

    // MARK: - ずらし

    /// ずらしの量を、写真の端が画面の内側へ入りこまない範囲に収める
    ///
    /// 写真は画面のまん中を中心に大きくなるので、片側にはみ出している長さは
    /// 「(写真の大きさ × 拡大率 − 画面の大きさ) ÷ 2」。これが片側にずらせる上限になる。
    /// はみ出していない向き（写真のほうが小さい）は上限が 0＝その向きにはずらさない。
    /// 等倍のときは、写真が画面に収まっているので、どちらの向きにもずらさない（0 になる）。
    /// - Parameters:
    ///   - offset: 収める前のずらしの量
    ///   - scale: 今の拡大率
    ///   - contentSize: 等倍のときの写真の大きさ（`fittedSize` の答え）
    ///   - containerSize: 入れ物（画面）の大きさ
    /// - Returns: 収めたずらしの量
    static func clampedOffset(_ offset: CGSize, scale: CGFloat, contentSize: CGSize, containerSize: CGSize) -> CGSize {
        let maxX = max(0, (contentSize.width * scale - containerSize.width) / 2)
        let maxY = max(0, (contentSize.height * scale - containerSize.height) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }

    // MARK: - 下へ引っぱって閉じる

    /// 指を離したときに閉じるかどうか
    ///
    /// - 下へ 120pt 以上引っぱっていたら閉じる
    /// - 引っぱりが短くても、下向きで、離したときの勢いで 240pt 先まで進みそうなら閉じる（さっと払う操作）
    /// - 上へ引っぱったときは閉じない（下向きだけ。上へ払っても閉じない）
    /// - Parameters:
    ///   - translationHeight: 指を離したときの縦の引っぱりの量（下が正）
    ///   - predictedEndTranslationHeight: 勢いから見積もった、止まるまでの縦の量（下が正。DragGesture の `predictedEndTranslation`）
    /// - Returns: 閉じるなら true
    static func shouldDismiss(translationHeight: CGFloat, predictedEndTranslationHeight: CGFloat) -> Bool {
        translationHeight >= dismissDistance
            || (translationHeight > 0 && predictedEndTranslationHeight >= dismissPredictedDistance)
    }

    /// 下へ引っぱっている間の写真の大きさ（等倍に掛ける）
    ///
    /// 引っぱるほど少しずつ小さくして、「このまま離すと閉じる」ことが見て分かるようにする。
    /// 0pt で 1（そのまま）、400pt で 0.85 になるまでまっすぐ小さくし、それより先は 0.85 のまま。
    /// 上へ引っぱったときは小さくしない（1 のまま）。
    /// - Parameter translationHeight: 縦の引っぱりの量（下が正）
    /// - Returns: 0.85〜1 の大きさ
    static func dismissDragScale(translationHeight: CGFloat) -> CGFloat {
        let progress = min(max(translationHeight, 0), dismissShrinkDistance) / dismissShrinkDistance
        return 1 - (1 - dismissMinScale) * progress
    }

    // MARK: - 計装

    /// 計装 `post_photo_viewer_opened` の parameters
    ///
    /// - 送るのは「何枚目を開いたか」と「全部で何枚か」だけ。UID・投稿 ID など、人や投稿を特定できる値は送らない。
    /// - 何枚目を開くかは、「ビューアの中でもめくれるようにするか」を後で決める材料にする（利用者の決定 2026-10-28）。
    /// - Parameters:
    ///   - imageIndex: 開いた写真の番号（カルーセルのページの番号＝0 始まり。1 枚目は 0）
    ///   - imageCount: 投稿の写真の枚数
    /// - Returns: 送る parameters
    static func openedEventParameters(imageIndex: Int, imageCount: Int) -> [String: Int] {
        ["image_index": imageIndex, "image_count": imageCount]
    }
}

// MARK: - 全画面のビューア

/// 投稿の写真を全画面で見せるビューア
///
/// ## 使い方（詳細の側）
/// ```swift
/// .fullScreenCover(item: $photoViewerItem) { item in
///     PostPhotoViewer(imageInfo: item.imageInfo)
/// }
/// ```
struct PostPhotoViewer: View {
    // MARK: - Properties

    /// 全画面で見せる写真（詳細でタップした 1 枚）
    let imageInfo: ImageInfo

    /// ビューアを閉じる（fullScreenCover を下ろす）
    @Environment(\.dismiss) private var dismiss
    /// 端末の「視差効果を減らす」が ON か（ON なら、引っぱり中に縮めない・戻すときに動かさない）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 確定した拡大率（1 = 等倍）
    @State private var zoomScale: CGFloat = PostPhotoViewerMath.minScale
    /// ピンチ中の拡大率の変化（指を離すと 1 に戻り、`zoomScale` に掛けて確定する）
    @GestureState private var pinchScale: CGFloat = 1
    /// 確定したずらしの量（大きくしている間だけ使う）
    @State private var panOffset: CGSize = .zero
    /// ドラッグ中のずらしの量（指を離すと 0 に戻り、`panOffset` に足して確定する）
    @GestureState private var dragOffset: CGSize = .zero
    /// 等倍のときの、閉じるための引っぱりの量
    ///
    /// `@GestureState` にしないのは、閉じるときに「指を離したその位置のまま」閉じたいため。
    /// `@GestureState` は指を離した瞬間に勝手に 0 へ戻るので、写真がまん中へ戻ってから閉じる動きになってしまう。
    /// その代わり、閉じない終わり方（戻す・ピンチに変わった）では、自分で 0 に戻す。
    @State private var dismissDrag: CGSize = .zero

    // MARK: - Init

    /// `@State` などの private のプロパティがあると、自動で作られる init が private になり、
    /// ほかのファイル（HomeView.swift）から呼べなくなるため、init を書いておく。
    /// - Parameter imageInfo: 全画面で見せる写真
    init(imageInfo: ImageInfo) {
        self.imageInfo = imageInfo
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 背景: 黒（写真だけに目が行くように。安全領域の外＝ノッチやホームの線の所まで塗る）
            Color.black
                .ignoresSafeArea()

            // 写真: 画面の全部（ノッチやホームの線の下まで）を入れ物にして、縦横どちらの向きでも全体が収まる大きさで描く
            GeometryReader { geometry in
                photoLayer(containerSize: geometry.size)
            }
            .ignoresSafeArea()

            // ✕: 安全領域の内側に置く（ノッチやステータスバーの所に重ならないように、ignoresSafeArea を付けない層）
            closeButton
        }
        // 写真に集中できるよう、上の時刻や電池の表示を隠す
        .statusBarHidden(true)
        // VoiceOver の「2 本指で Z を書く」操作（エスケープ）で閉じる（✕ を探さなくても閉じられる）
        .accessibilityAction(.escape) {
            dismiss()
        }
    }

    // MARK: - 写真

    /// 写真の層（拡大・ずらし・引っぱりを反映して描き、指の操作を受け取る）
    ///
    /// - Parameter containerSize: 入れ物（画面全体）の大きさ
    private func photoLayer(containerSize: CGSize) -> some View {
        // 等倍のときの写真の大きさ（画面に全体が収まる一番大きな大きさ）
        let contentSize = PostPhotoViewerMath.fittedSize(
            aspectRatio: PostPhotoViewerMath.aspectRatio(width: imageInfo.width, height: imageInfo.height),
            in: containerSize
        )
        // 描く拡大率: ピンチ中は、確定した拡大率に変化を掛け、1〜4 倍に収める（生の値で描かない）
        let scale = PostPhotoViewerMath.clampedScale(zoomScale * pinchScale)
        // 描くずらし: 確定した量にドラッグ中の量を足し、写真の端が画面の内側へ入りこまない範囲に収める（生の値で描かない）
        let pan = PostPhotoViewerMath.clampedOffset(
            CGSize(width: panOffset.width + dragOffset.width, height: panOffset.height + dragOffset.height),
            scale: scale,
            contentSize: contentSize,
            containerSize: containerSize
        )
        // 下へ引っぱっている間の縮み（「視差効果を減らす」が ON のときは縮めない）
        let pullScale = reduceMotion ? 1 : PostPhotoViewerMath.dismissDragScale(translationHeight: dismissDrag.height)

        return photo
            .frame(width: contentSize.width, height: contentSize.height)
            // VoiceOver: 写真を 1 つの画像としてまとめて読む
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("空の写真")
            .accessibilityAddTraits(.isImage)
            .scaleEffect(scale * pullScale)
            // 引っぱりの量は、ずらしとは別に足す（等倍のときだけ 0 でない。指にそのままついてくる）
            .offset(x: pan.width + dismissDrag.width, y: pan.height + dismissDrag.height)
            // GeometryReader は中身を左上に寄せるので、入れ物いっぱいの枠に入れてまん中に置く。
            // この枠全体で指を受けるので、写真の外（黒い余白）をつまんでも・引っぱっても効く
            .frame(width: containerSize.width, height: containerSize.height)
            .contentShape(Rectangle())
            // ピンチで大きく・小さくする
            .gesture(pinchGesture(contentSize: contentSize, containerSize: containerSize))
            // ドラッグ 1 本で、大きくしている間は「ずらす」・等倍のときは「下へ引っぱって閉じる」（ピンチと同時に受ける）
            .simultaneousGesture(dragGesture(contentSize: contentSize, containerSize: containerSize))
            // 回転して入れ物の大きさが変わったら、拡大・ずらし・引っぱりを戻す
            // （ずらしの上限は入れ物の大きさで決まるので、前の向きの値のままだと位置がおかしくなる）
            .onChange(of: containerSize) { _ in
                resetZoomAndDrag()
            }
    }

    /// 写真そのもの（詳細と同じ読み方＝同じキャッシュの鍵なので、詳細で読み終えた写真はすぐ出る）
    @ViewBuilder
    private var photo: some View {
        // 公開は URL、公開以外は Storage のパスで読む（判定は PostImageSource・詳細の PostDetailImageView と同じ）
        if let image = KFImage.post(PostImageSource.resolve(imageInfo, prefersThumbnail: false)) {
            image
                .placeholder {
                    // 黒い背景の上でも見えるよう、白いくるくるにする
                    ProgressView()
                        .tint(.white)
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // 読めない写真（詳細の側で開かないようにしているので、ふつうはここに来ない）
            Image(systemName: "photo")
                .font(.system(size: 44))
                .foregroundColor(.gray)
        }
    }

    // MARK: - ✕ ボタン

    /// 右上の ✕（44pt の丸・押すと閉じる）
    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                // 指で押しやすい大きさ（44pt）にする
                .frame(width: 44, height: 44)
                // 白い写真の上でも ✕ が見えるよう、半透明の黒い丸を敷く
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.5))
                )
        }
        .accessibilityLabel("閉じる")
        .padding(.top, 8)
        .padding(.trailing, 16)
    }

    // MARK: - 操作

    /// ピンチの最中か
    ///
    /// ピンチの間だけ `pinchScale` が 1 からずれる（指を離すと 1 に戻る）ので、それで見分ける。
    private var isPinching: Bool {
        pinchScale != 1
    }

    /// 今のドラッグの使い道（拡大率とピンチの最中かで決める）
    private var currentDragMode: PostPhotoViewerMath.DragMode {
        PostPhotoViewerMath.dragMode(scale: zoomScale, isPinching: isPinching)
    }

    /// 「戻す」ときの動き（「視差効果を減らす」が ON なら動かさず一瞬で戻す）
    private var snapBackAnimation: Animation? {
        Motion.animation(.spring(response: 0.3, dampingFraction: 0.85), reduceMotion: reduceMotion)
    }

    /// ピンチの操作（指を離したら拡大率を確定し、ずらしの量を新しい拡大率の範囲に収め直す）
    /// - Parameters:
    ///   - contentSize: 等倍のときの写真の大きさ
    ///   - containerSize: 入れ物（画面）の大きさ
    private func pinchGesture(contentSize: CGSize, containerSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let newScale = PostPhotoViewerMath.clampedScale(zoomScale * value)
                zoomScale = newScale
                if newScale <= PostPhotoViewerMath.minScale {
                    // 等倍に戻った: ずらしも戻す（等倍では写真が画面に収まっているので、ずらす意味がない）
                    panOffset = .zero
                } else {
                    // 大きいまま: 小さくした分だけ上限も狭まるので、収め直す（描く値は収めてあるので見た目は動かない）
                    panOffset = PostPhotoViewerMath.clampedOffset(
                        panOffset,
                        scale: newScale,
                        contentSize: contentSize,
                        containerSize: containerSize
                    )
                }
            }
    }

    /// ドラッグの操作（大きくしている間は「ずらす」・等倍のときは「下へ引っぱって閉じる」）
    ///
    /// 使い道は、動くたびに `PostPhotoViewerMath.dragMode` で決め直す。
    /// - Parameters:
    ///   - contentSize: 等倍のときの写真の大きさ
    ///   - containerSize: 入れ物（画面）の大きさ
    private func dragGesture(contentSize: CGSize, containerSize: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in
                // 大きくしている間だけ、指の動きをずらしの量にする（それ以外のときは 0 のまま）
                state = currentDragMode == .pan ? value.translation : .zero
            }
            .onChanged { value in
                if currentDragMode == .dismiss {
                    // 等倍: 写真を指にそのままついてこさせる
                    dismissDrag = value.translation
                } else if dismissDrag != .zero {
                    // 引っぱりの途中でピンチが始まった（または大きくなった）: 引っぱりをやめて、写真をまん中へ戻す
                    withAnimation(snapBackAnimation) {
                        dismissDrag = .zero
                    }
                }
            }
            .onEnded { value in
                switch currentDragMode {
                case .pan:
                    // ずらしの量を確定する（画面の内側へ入りこまない範囲に収めてから持つ）
                    panOffset = PostPhotoViewerMath.clampedOffset(
                        CGSize(
                            width: panOffset.width + value.translation.width,
                            height: panOffset.height + value.translation.height
                        ),
                        scale: zoomScale,
                        contentSize: contentSize,
                        containerSize: containerSize
                    )
                case .dismiss:
                    // 閉じるかどうかの距離は、指の動きそのもの（value.translation）でなく、
                    // 「閉じる引っぱり」として受け取った量（dismissDrag）で見る。
                    // 大きくした写真をピンチで等倍まで戻しながら指を離したとき、ピンチの終わりが先に届くと
                    // ここが .dismiss になる。そのドラッグは「ずらし」だったので dismissDrag は 0＝閉じない。
                    // ふつうの引っぱりでは、dismissDrag は直前の指の動きと同じ値なので、結果は変わらない。
                    if PostPhotoViewerMath.shouldDismiss(
                        translationHeight: dismissDrag.height,
                        predictedEndTranslationHeight: value.predictedEndTranslation.height
                    ) {
                        // 閉じる: 引っぱったその位置のまま閉じる（まん中へ戻してから閉じない）
                        dismiss()
                    } else {
                        // 閉じない: 写真をまん中へ戻す
                        withAnimation(snapBackAnimation) {
                            dismissDrag = .zero
                        }
                    }
                case .ignore:
                    // ピンチの最中に指を離した: 引っぱりが残っていたら戻す
                    withAnimation(snapBackAnimation) {
                        dismissDrag = .zero
                    }
                }
            }
    }

    /// 拡大・ずらし・引っぱりを、開いたときの状態に戻す（回転したとき）
    private func resetZoomAndDrag() {
        zoomScale = PostPhotoViewerMath.minScale
        panOffset = .zero
        dismissDrag = .zero
    }
}
