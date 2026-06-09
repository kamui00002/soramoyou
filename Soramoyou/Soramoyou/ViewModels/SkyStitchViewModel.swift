// ⭐️ SkyStitchViewModel.swift
// 広角合成(v2)の状態機械 — 合成→プレビュー→「成功時のみ課金」→投稿パイプラインへ橋渡し
//
//  Created on 2026-06-10.
//
//  「成功時のみ課金」フロー:
//    ① 4枚を SkyStitcher で合成（重いので非UIスレッド）
//    ② .ok ＝ 合成プレビューを表示。失敗時は撮り直し誘導し、課金画面に到達させない
//    ③ ユーザーがプレビューを見て納得 → 購入（既に購入済みなら課金スキップ）
//    ④ 購入成功 → 合成済み1枚を投稿パイプライン(EditView→PostInfoView→savePost postKind=.panorama)へ
//
//  テスト容易性のため payment と stitch を注入可能にする（viewmodel.md / swift-test.md 準拠）。
//

import SwiftUI
import os.log

@MainActor
final class SkyStitchViewModel: ObservableObject {

    /// フロー状態。previewReady/purchased は合成済み画像を保持する。
    enum State {
        case idle
        case stitching
        case previewReady(UIImage)   // 合成成功・購入待ち
        case purchasing
        case purchased(UIImage)      // 購入完了・パイプラインへ橋渡し可能
        case failed(String)          // 失敗（料金は発生しない旨を文言で示す）
    }

    @Published private(set) var state: State = .idle

    private let payment: PaymentServiceProtocol
    private let stitch: @Sendable ([UIImage]) -> SkyStitchResult
    private let logger = Logger(subsystem: "com.soramoyou", category: "SkyStitchViewModel")

    init(
        payment: PaymentServiceProtocol = PaymentService.shared,
        stitch: @escaping @Sendable ([UIImage]) -> SkyStitchResult = { SkyStitcher.stitch($0) }
    ) {
        self.payment = payment
        self.stitch = stitch
    }

    /// 価格表示（未ロード時は nil → UI 側でフォールバック文言）。
    var displayPrice: String? { payment.displayPrice(for: SkyStitchProduct.panorama) }

    /// 合成済み画像（previewReady / purchased のとき）。
    var stitchedImage: UIImage? {
        switch state {
        case .previewReady(let img), .purchased(let img): return img
        default: return nil
        }
    }

    // MARK: - 合成

    /// 4枚（2枚以上）を合成する。重い処理なので非UIスレッドで実行し、結果でプレビュー or 撮り直し誘導。
    func runStitch(_ images: [UIImage]) async {
        state = .stitching
        let stitchFn = stitch
        let result = await Task.detached(priority: .userInitiated) { stitchFn(images) }.value

        switch result.status {
        case .ok:
            if let image = result.image {
                state = .previewReady(image)
            } else {
                state = .failed("合成結果を取得できませんでした。写真を選び直してお試しください")
            }
        case .needMoreImages:
            state = .failed("写真の重なりが足りません。少しずつ重ねて撮った写真でお試しください")
        case .homographyEstFailed, .cameraParamsAdjustFailed:
            state = .failed("うまく繋げませんでした。手ブレを抑え、重ねて撮り直してください")
        case .unavailable:
            state = .failed("この端末では広角合成を利用できません")
        case .failed:
            state = .failed("合成に失敗しました。写真を選び直してお試しください")
        }

        // 合成の成功/失敗ファネルを計装（IAP 本番化前から動くので今取らないと backfill 不可・PII なし）。
        let succeeded: Bool = { if case .previewReady = state { return true } else { return false } }()
        LoggingService.shared.logEvent("stitch_completed", parameters: [
            "succeeded": succeeded,
            "status": Self.statusLabel(result.status),
            "input_count": images.count
        ])
    }

    /// 計装用の status ラベル（PII なし・列挙のみ）。
    private static func statusLabel(_ status: SkyStitchStatus) -> String {
        switch status {
        case .ok:                       return "ok"
        case .needMoreImages:           return "need_more_images"
        case .homographyEstFailed:      return "homography_failed"
        case .cameraParamsAdjustFailed: return "camera_params_failed"
        case .unavailable:              return "unavailable"
        case .failed:                   return "failed"
        }
    }

    // MARK: - 課金（成功時のみ）

    /// プレビュー確認後の購入。previewReady のときのみ実行。
    /// - 既に購入済み（非消耗型）なら課金せず解放。
    /// - キャンセル/失敗時はプレビューへ戻す（料金は発生しない）。
    func purchaseAndProceed() async {
        guard case .previewReady(let image) = state else { return }
        // 連打ガード: await を挟む前に即 .purchasing へ遷移し、2回目以降の guard を弾く。
        state = .purchasing

        // 非消耗型: 既に購入済みなら課金せず機能解放（二重課金防止）
        if await payment.isEntitled(to: SkyStitchProduct.panorama) {
            state = .purchased(image)
            return
        }

        do {
            let outcome = try await payment.purchase(productID: SkyStitchProduct.panorama)
            switch outcome {
            case .success:
                state = .purchased(image)
            case .userCancelled:
                state = .previewReady(image)   // 料金なしでプレビューへ戻す
            case .pending:
                state = .failed("購入は承認待ちです。完了後にもう一度お試しください（料金はまだ発生しません）")
            }
        } catch {
            logger.error("purchase 失敗: \(error.localizedDescription, privacy: .public)")
            state = .failed("購入に失敗しました（料金は発生していません）。\(error.userFriendlyMessage)")
        }
    }

}
