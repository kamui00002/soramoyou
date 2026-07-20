//
//  ShareCardView.swift
//  Soramoyou
//
//  空カード共有パック ⭐️: 投稿写真を外部SNS（Instagram/X）に「そのまま出せる完成品」として
//  書き出すための正方形（1080×1080）共有カード。
//
//  デザイン方針（docs/ui-spec.md 準拠）: 写真が主役・余白を活かす。
//  下部に撮影日・場所を小さく上品に、右下に控えめな「そらもよう」透かし（既定ON・8割白）。
//  場所は既定でON/OFFが変わる（呼び出し側 ShareCardExportView が投稿の visibility から決める）。
//
//  🔧 レビュー修正 (2026-07-20): 書き出し経路の Display P3 保全を再設計。
//  旧実装は写真込みの View 全体を ImageRenderer でラスタライズしていたため、
//  ImageRenderer 内部の合成パイプラインで Display P3 の広色域が sRGB へ劣化していた
//  （既存パイプラインが死守している規約に反する。参考: StorageService.encodeJPEG /
//  ImageCompositor.composeToUIImage / SkyCollageCompositor.composeToUIImage は
//  いずれも「写真は最後まで CIImage のまま扱い、最終書き出しは CIContextPool の
//  Display P3 + .RGBAh に委ねる」という同じ規約を守っている）。
//
//  そのため `renderedImage()`（書き出し経路）だけを次の方式に作り直した:
//  - 写真本体は最後まで CIImage のまま扱い、1080×1080 への配置（fill/fit）は
//    CILanczosScaleTransform で行う（ImageCompositor / SkyCollageCompositor と同じ手法。
//    `composite` / `placedScaled` 相当のヘルパーは意図的にこのファイル内へ複製する
//    ＝ SkyCollageCompositor が ImageCompositor から複製しているのと同じ方針）。
//  - 日付・場所・透かしの文字とグラデーション地だけを「透明背景」の SwiftUI View として
//    ImageRenderer でラスタライズする（テキスト・グラデーションは sRGB で十分。
//    写真とは別レイヤなので広色域を汚さない）。
//  - 両者を CISourceOverCompositing で重ね、CIContextPool（Display P3 + .RGBAh）経由で
//    最終 UIImage 化する。
//
//  画面プレビュー用の `body` は従来どおり SwiftUI ネイティブ（Image(uiImage:)）のままでよい
//  （画面表示はどうせ端末の表示パイプラインで sRGB 相当になるため、CI 化の恩恵が薄い）。
//  ただし fill/fit の分岐ロジック（下記）は body 側にも同様に必要。
//
//  気分フレーム（frameId）付き投稿の分岐について:
//  投稿保存時点で PostViewModel.composeMoodFrameIfNeeded が写真にフレーム（余白＋下部の
//  キャプションプレート）を焼き込み済み。このプレートは写真の「下端」にあるため、正方形へ
//  aspect-fill すると縦位置の写真ではプレートが中央クロップで完全に消える（座標計算上
//  プレート100%消失を実証済み）。そのため frameId 付き投稿は aspect-fill ではなく
//  aspect-fit ＋ 写真自身の拡大ぼかしを背景にする（Instagram 等でおなじみの手法）。
//  frameId なしの投稿は従来どおり aspect-fill。
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

struct ShareCardView: View {
    /// カードの一辺（pt）。renderedImage() では px と一致させ、body 側では scale=1.0 相当で扱う。
    static let cardSize: CGFloat = 1080

    let post: Post
    let image: UIImage
    let showWatermark: Bool
    /// 位置情報（撮影地）を表示するか。既定値は呼び出し側（ShareCardExportView）が
    /// 投稿の visibility から決める（プライバシー安全側: public 投稿のみ既定ON）。
    let showLocation: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }()

    /// 撮影日優先（無ければ投稿日）
    private var dateText: String {
        Self.dateFormatter.string(from: post.capturedAt ?? post.createdAt)
    }

    /// 「都道府県 市区町村」表記（既存の投稿詳細表示と同じ規約）
    private var locationText: String? {
        guard let location = post.location else { return nil }
        if let prefecture = location.prefecture, let city = location.city {
            return "\(prefecture) \(city)"
        }
        return location.city ?? location.prefecture
    }

    /// フレーム焼き込み済み投稿か（aspect-fill だと下部プレートが消えるため fit+ぼかし背景に分岐）
    private var hasBakedFrame: Bool { post.frameId != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            photoLayerView
            overlayLayerView
        }
        .frame(width: Self.cardSize, height: Self.cardSize)
        .clipShape(Rectangle())
    }

    // MARK: - Photo Layer（画面プレビュー用・SwiftUI ネイティブ）

    @ViewBuilder
    private var photoLayerView: some View {
        if hasBakedFrame {
            // 気分フレーム付き投稿: 背景に写真自身の拡大ぼかし、前景を aspect-fit で
            // 全体（下部プレート込み）を欠けさせない。
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.cardSize, height: Self.cardSize)
                .blur(radius: 40)
                .clipShape(Rectangle())
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.cardSize, height: Self.cardSize)
        } else {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.cardSize, height: Self.cardSize)
                .clipShape(Rectangle())
        }
    }

    // MARK: - Overlay Layer（グラデーション地＋テキスト）
    //
    // 書き出し経路（renderedImage）では、この View だけを透明背景で単独ラスタライズして
    // 写真レイヤ（CIImage）に CISourceOverCompositing で重ねる。そのため `.frame` で
    // 明示的に cardSize×cardSize を確保しておく必要がある（単独レンダリング時のサイズ確定用）。

    private var overlayLayerView: some View {
        ZStack(alignment: .bottom) {
            // 単独ラスタライズ時（書き出し経路）に ZStack のレイアウト基準サイズを
            // 明示的に cardSize×cardSize へ固定するためのアンカー（透明・不可視）。
            // これが無いと、写真レイヤ（濃色サイズの Image）という「大きな兄弟」を持たない
            // 単独レンダリングでは ZStack の実効サイズがコンテンツの自然サイズへ縮み、
            // .bottom 揃えの基準となる下端がキャンバス下端よりかなり上に来てしまう
            // （実機検証で確認: グラデーション/テキストが中央寄りに浮いてしまう不具合）。
            Color.clear
                .frame(width: Self.cardSize, height: Self.cardSize)

            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.cardSize * 0.30)

            bottomInfoRow
                .padding(.horizontal, 48)
                .padding(.bottom, 40)
        }
        .frame(width: Self.cardSize, height: Self.cardSize)
    }

    // MARK: - Bottom Info Row

    private var bottomInfoRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(dateText)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                if showLocation, let locationText {
                    Text(locationText)
                        .font(.system(size: 22, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if showWatermark {
                // 主張しすぎない透かし（8割白・小さめ）
                Text("そらもよう")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }
}

// MARK: - Rendering（書き出し経路・Display P3 保全）

extension ShareCardView {
    /// カードを実寸（cardSize × cardSize px）でラスタライズする。
    ///
    /// 写真は最後まで CIImage のまま扱い、CIContextPool（Display P3 + .RGBAh）で最終化する。
    /// 透明背景の文字レイヤだけ ImageRenderer で sRGB ラスタライズし、
    /// CISourceOverCompositing で写真の上に重ねる。
    /// - Note: `ImageRenderer` は @MainActor 前提。`scale = 1.0` に固定することで
    ///   デバイスの画面スケール(2x/3x)に関わらず出力ピクセルサイズを `cardSize` と一致させる。
    @MainActor
    static func renderedImage(post: Post, image: UIImage, showWatermark: Bool, showLocation: Bool) -> UIImage? {
        guard let photoLayer = photoCILayer(post: post, image: image) else { return nil }

        // 文字＋グラデーションだけを透明背景で単独ラスタライズ（写真を含まないので P3 劣化は無関係）
        let overlayView = ShareCardView(post: post, image: image, showWatermark: showWatermark, showLocation: showLocation)
            .overlayLayerView
        let overlayRenderer = ImageRenderer(content: overlayView)
        overlayRenderer.scale = 1.0
        overlayRenderer.isOpaque = false
        guard let overlayCGImage = overlayRenderer.uiImage?.cgImage else { return nil }
        let overlayLayer = CIImage(cgImage: overlayCGImage)

        let pool = CIContextPool.shared
        let canvas = CGRect(x: 0, y: 0, width: cardSize, height: cardSize)
        let composited = composite(overlayLayer, over: photoLayer)
        guard let outputCGImage = pool.ciContext.createCGImage(
            composited,
            from: canvas,
            format: .RGBAh,
            colorSpace: pool.outputColorSpace
        ) else {
            return nil
        }
        return UIImage(cgImage: outputCGImage)
    }

    // MARK: - Photo Layer（書き出し用・CIImage のまま Display P3 を保つ）

    /// 写真を 1080×1080 キャンバスへ配置した CIImage を返す（失敗時 nil）。
    /// frameId 付き投稿は aspect-fit＋ぼかし背景、それ以外は aspect-fill（body と同じ分岐）。
    private static func photoCILayer(post: Post, image: UIImage) -> CIImage? {
        guard let cgImage = image.cgImage else { return nil }
        // orientation は CIImage.oriented で適用する（withNormalizedOrientation は
        // UIGraphicsImageRenderer 経由で sRGB 化されうるため、この合成経路では使わない。
        // cf. UIImage+NormalizedOrientation.swift の CGImagePropertyOrientation extension コメント）。
        let oriented = CIImage(cgImage: cgImage)
            .oriented(CGImagePropertyOrientation(image.imageOrientation))
        let base = oriented.transformed(
            by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY)
        )
        let pw = base.extent.width, ph = base.extent.height
        guard pw > 0, ph > 0 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: cardSize, height: cardSize)

        if post.frameId != nil {
            let background = blurredFillLayer(base, pw: pw, ph: ph, canvas: canvas)
            let foreground = fitLayer(base, pw: pw, ph: ph, canvas: canvas)
            return composite(foreground, over: background).cropped(to: canvas)
        } else {
            return fillLayer(base, pw: pw, ph: ph, canvas: canvas).cropped(to: canvas)
        }
    }

    /// 写真を canvas 中央へ配置する（fill=true: 短辺基準で埋める／false: 長辺基準で収める）。
    /// cf. SkyCollageCompositor.fittedPhoto と同じ手法（意図的な複製）。
    private static func placedScaled(_ base: CIImage, pw: CGFloat, ph: CGFloat, canvas: CGRect, fill: Bool) -> CIImage {
        let scale = fill ? max(canvas.width / pw, canvas.height / ph) : min(canvas.width / pw, canvas.height / ph)
        let scaler = CIFilter.lanczosScaleTransform()
        scaler.inputImage = base
        scaler.scale = Float(scale)
        scaler.aspectRatio = 1
        guard let scaled0 = scaler.outputImage else { return base }
        // 出力原点が動くケースに備えて再正規化
        let scaled = scaled0.transformed(
            by: CGAffineTransform(translationX: -scaled0.extent.minX, y: -scaled0.extent.minY)
        )
        let sw = scaled.extent.width, sh = scaled.extent.height
        let tx = canvas.minX + (canvas.width - sw) / 2
        let ty = canvas.minY + (canvas.height - sh) / 2
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
    }

    private static func fillLayer(_ base: CIImage, pw: CGFloat, ph: CGFloat, canvas: CGRect) -> CIImage {
        placedScaled(base, pw: pw, ph: ph, canvas: canvas, fill: true)
    }

    private static func fitLayer(_ base: CIImage, pw: CGFloat, ph: CGFloat, canvas: CGRect) -> CIImage {
        placedScaled(base, pw: pw, ph: ph, canvas: canvas, fill: false)
    }

    /// fill スケール＋ぼかしの背景層。
    /// clamp → blur → crop の順（縁の細い帯を防ぐ定石。cf. HeuristicSkyMaskProvider.smoothAndSharpenEdges /
    /// SkyReplacementCompositor.feather の SKY-002 修正と同じ理由。旧順序（blur 後に clamp）は
    /// 縁のピクセルが透明にフォールバックし、細い暗い帯が出る）。
    private static func blurredFillLayer(_ base: CIImage, pw: CGFloat, ph: CGFloat, canvas: CGRect) -> CIImage {
        let filled = placedScaled(base, pw: pw, ph: ph, canvas: canvas, fill: true)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = filled.clampedToExtent()
        blur.radius = 48
        return (blur.outputImage ?? filled).cropped(to: canvas)
    }

    /// 上レイヤを下レイヤに source-over で重ねる。
    /// cf. ImageCompositor.composite / SkyCollageCompositor.composite（意図的な複製）。
    private static func composite(_ top: CIImage, over bottom: CIImage) -> CIImage {
        let filter = CIFilter.sourceOverCompositing()
        filter.inputImage = top
        filter.backgroundImage = bottom
        return filter.outputImage ?? bottom
    }
}

#Preview {
    let previewSide: CGFloat = 320
    return ShareCardView(
        post: Post(
            id: "preview",
            userId: "u",
            images: [],
            location: Location(latitude: 35.66, longitude: 139.70, city: "渋谷区", prefecture: "東京都"),
            capturedAt: Date(),
            createdAt: Date()
        ),
        image: UIImage(systemName: "photo.fill") ?? UIImage(),
        showWatermark: true,
        showLocation: true
    )
    .frame(width: ShareCardView.cardSize, height: ShareCardView.cardSize)
    .scaleEffect(previewSide / ShareCardView.cardSize)
    .frame(width: previewSide, height: previewSide)
}
