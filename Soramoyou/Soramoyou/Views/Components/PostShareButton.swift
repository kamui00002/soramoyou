//
//  PostShareButton.swift ⭐️
//  Soramoyou
//
//  カードのシェア（共有）のボタン
//  1.18.0 PR-H「4: カードのシェアのボタンを動かす」
//
//  これまでカード（PostCard）のシェアのアイコンは、見た目だけで押しても何も起きなかった。
//  投稿の詳細の「共有」（PostDetailView の `shareCurrentImage`）と同じ処理で動くようにする:
//  1 枚目の画像を本体の大きさで取ってきて（公開以外は Storage のパスで読む）、iOS の共有シートを出す。
//
//  判断（連打を捨てる・画像が無いとき・失敗したとき・計装を送るか）は `PostShareModel` に切り出して単体テストで固定し
//  （`PostShareModelTests`）、View（`PostShareButton`）は見た目と表示（シート・アラート）だけを持つ薄い部品にする
//  （PostReactionButtons と同じ考え方）。
//
//  ⚠️ 詳細の `shareCurrentImage`（HomeView.swift の PostDetailView）はこの部品へ寄せず、そのまま残している。
//     「1 枚目を本体の大きさで・公開以外は Storage のパスで」の決まりを変えるときは、両方を直すこと。
//

import SwiftUI
import UIKit

// MARK: - 計装の差し替え口

/// シェアの計装の送り先（テストでは記録するだけの偽物を渡す）
///
/// LikeManager の `LikeEventLogging` と同じ形。
/// `LoggingService.shared` を直に呼ぶと、送ったかどうかをテストで確かめられないため。
protocol PostShareEventLogging: AnyObject {
    func logEvent(_ name: String, parameters: [String: Any]?)
}

/// 本番は LoggingService（PostHog・Firebase Analytics の両方に送る）。署名はそのまま合う
extension LoggingService: PostShareEventLogging {}

// MARK: - 押したときの処理（判断）

/// カードのシェアのボタンを押したときの処理と、表示に使う状態
///
/// ボタン（`PostShareButton`）がカード 1 枚ごとに 1 つ持つ（`@StateObject`）。
/// 最低 iOS 16 なので `@Observable` は使えず、`ObservableObject` にしている。
@MainActor
final class PostShareModel: ObservableObject {
    // MARK: - Properties

    /// 画像を取ってきている途中か（この間はボタンの場所にくるくるを出し、もう一度押しても何もしない）
    @Published private(set) var isPreparing = false
    /// 共有シートに渡す画像（取ってきた 1 枚目）
    @Published var shareImages: [UIImage] = []
    /// 共有シートを出しているか
    @Published var isShareSheetPresented = false
    /// 失敗したときにアラートで出す文（nil ならアラートを出さない）
    @Published var errorMessage: String?

    /// 画像の取り先（本番は ImageDownloadService.shared・テストは差し替える）
    private let downloader: ImageDownloadServiceProtocol
    /// 計装の送り先（本番は LoggingService.shared・テストは記録するだけの偽物）
    private let logger: PostShareEventLogging

    init(downloader: ImageDownloadServiceProtocol = ImageDownloadService.shared,
         logger: PostShareEventLogging = LoggingService.shared)
    {
        self.downloader = downloader
        self.logger = logger
    }

    // MARK: - Methods

    /// 投稿の 1 枚目を取ってきて、共有シートを出す
    ///
    /// 詳細の「共有」（PostDetailView の `shareCurrentImage`）と同じ流れ:
    /// 1. 1 枚目が無ければ「共有する画像がありません」を出して終わる
    /// 2. 1 枚目を本体の大きさで取る（`PostImageSource.resolve(…, prefersThumbnail: false)`。
    ///    公開以外は URL が残っていても Storage のパスで読む＝URL 側の C-2）
    /// 3. 取れたら共有シートを出す・失敗したら `error.userFriendlyMessage` をアラートで出す
    ///
    /// 計装 `post_share_sheet_opened` は**共有シートを出せたときだけ**送る（画像が無い・失敗したときは送らない）。
    /// 共有シートの中で実際にどこかへ送ったかまでは数えない＝「シートを開いた」までの数。
    /// - Parameters:
    ///   - post: 共有する投稿
    ///   - source: 計装の source（どの画面のカードか。いいねの source と同じ値。nil なら source を付けずに送る＝検索の画面）
    func share(post: Post, source: String?) async {
        // 取ってきている途中の 2 回目は何もしない（連打で画像を 2 回取りに行かない・共有シートを 2 回出そうとしない）
        guard !isPreparing else { return }
        isPreparing = true
        // 成功・画像なし・失敗のどれで抜けても、くるくるを必ず下ろす
        defer { isPreparing = false }

        guard let imageInfo = post.images.first else {
            errorMessage = "共有する画像がありません"
            return
        }

        do {
            let image = try await downloader.downloadImage(from: PostImageSource.resolve(imageInfo, prefersThumbnail: false))
            shareImages = [image]
            isShareSheetPresented = true
            logger.logEvent("post_share_sheet_opened", parameters: Self.eventParameters(source: source))
        } catch {
            // 権限の拒否（フォローを外された後など）・通信の失敗は、ImageDownloadService が
            // 「画像のダウンロードに失敗しました」などの日本語の文にまとめて投げてくる。計装は送らない。
            errorMessage = error.userFriendlyMessage
        }
    }

    /// 計装 `post_share_sheet_opened` の parameters
    ///
    /// - 送るのは source だけ。UID・投稿 ID など、人や投稿を特定できる値は送らない。
    /// - source が nil（検索の画面のカード）のときは、**空の辞書**を渡す（source のキーを入れない）。
    ///   nil でなく空の辞書にしたのは、「辞書を作って、あれば足す」の一本道にして読みやすくするため。
    ///   LoggingService.logEvent は nil も空の辞書も同じように通す（`sanitizeParameters`）。
    /// - Parameter source: 計装の source
    /// - Returns: 送る parameters
    private static func eventParameters(source: String?) -> [String: Any] {
        var parameters: [String: Any] = [:]
        if let source {
            parameters["source"] = source
        }
        return parameters
    }
}

// MARK: - シェアのボタン

/// カードのシェア（共有）のボタン
///
/// ## 使い方
/// ```swift
/// PostShareButton(post: post, source: "home_card")
/// ```
///
/// - 押すと軽い触覚（`.tap`）→ 1 枚目を取ってきて共有シートを出す（処理は `PostShareModel`）。
/// - 取ってきている間は、アイコンの場所にくるくる（ProgressView）を出し、ボタンを押せなくする。
/// - 詳細のような全画面のくるくる（PostDetailView の `savingOverlay`・`isSaving`）はカードでは使わない。
///   詳細は「共有」がメニューの中にあり、押すとメニューがすぐ閉じてボタンの上に何も出せないので全画面に出している。
///   カードのボタンは押した場所に見えたままなので、その場でくるくるを出せば足りる。
///   また、カードは何枚も並ぶ一覧の中にあり、全画面を覆うと画像を取ってくる数秒の間スクロールまで止まってしまう。
struct PostShareButton: View {
    // MARK: - Properties

    /// 共有する投稿
    let post: Post
    /// 計装 post_share_sheet_opened の source（どの画面のカードか。nil なら source なしで送る＝検索の画面）
    var source: String?

    /// 押したときの処理と表示の状態（カード 1 枚ごとに 1 つ持つ）
    @StateObject private var model = PostShareModel()

    // MARK: - Body

    var body: some View {
        Button {
            Haptics.play(.tap)
            Task { await model.share(post: post, source: source) }
        } label: {
            label
        }
        // 隣のコメントボタンと同じ（押したときに色を変えない）
        .buttonStyle(.plain)
        // 取ってきている間は押せない（2 回目を捨てる本体は PostShareModel の guard。ここは見た目と手ごたえのため）
        .disabled(model.isPreparing)
        .accessibilityLabel("共有")
        .sheet(isPresented: $model.isShareSheetPresented) {
            ImageShareSheet(images: model.shareImages)
        }
        // 詳細の「共有」の失敗と同じ形（タイトルに文、OK だけ）
        .alert(model.errorMessage ?? "", isPresented: isErrorPresented) {
            Button("OK") {}
        }
    }

    // MARK: - Label

    /// ボタンの中身（普段は今までと同じアイコン・取ってきている間はくるくる）
    ///
    /// ⚠️ 準備中と普段で枠の大きさを変えないため、アイコンは準備中も置いたまま透明にし、
    ///    くるくるはアイコンの上に重ねる（`.overlay`）。overlay は枠の大きさに影響しないので、
    ///    くるくるが少し大きくても、同じ行のいいね・コメントの位置やカードの高さはずれない。
    private var label: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DesignTokens.Colors.textTertiary)
            .opacity(model.isPreparing ? 0 : 1)
            .overlay {
                if model.isPreparing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: DesignTokens.Colors.textTertiary))
                        .controlSize(.small)
                }
            }
    }

    // MARK: - Private

    /// アラートを出すか（errorMessage があるあいだ出す・閉じたら errorMessage を nil に戻す）
    private var isErrorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.errorMessage = nil
                }
            }
        )
    }
}
