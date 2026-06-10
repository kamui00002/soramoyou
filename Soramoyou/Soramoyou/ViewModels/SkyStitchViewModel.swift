// ⭐️ SkyStitchViewModel.swift
// 広角合成(v2)の状態機械 — 合成→プレビュー→投稿パイプラインへ橋渡し（無料）
//
//  Created on 2026-06-10.
//
//  フロー（無料）:
//    ① 4枚を SkyStitcher で合成（重いので非UIスレッド）
//    ② .ok ＝ 合成プレビューを表示。失敗時は撮り直し誘導
//    ③ ユーザーがプレビューを見て納得 → 合成済み1枚を投稿パイプライン
//       (EditView→PostInfoView→savePost postKind=.panorama) へ
//
//  ※ 課金（StoreKit/PaymentService）は当初 v2 を有料にする想定で実装したが、
//    OpenCV の実出荷サイズ増が小さい（+約1.7MB）こと・IAP の運用コストが価値を上回ることから
//    広角合成は無料化した。PaymentService 一式は将来の「AI 補正」課金で再利用するため温存する。
//
//  テスト容易性のため stitch を注入可能にする（viewmodel.md / swift-test.md 準拠）。
//

import SwiftUI
import os.log

@MainActor
final class SkyStitchViewModel: ObservableObject {

    /// フロー状態。previewReady は合成済み画像を保持する。
    enum State {
        case idle
        case stitching
        case previewReady(UIImage)   // 合成成功・保存待ち
        case failed(String)          // 失敗（撮り直し誘導）
    }

    @Published private(set) var state: State = .idle

    /// 撮り方（横パン / 4隅）。既定は 4隅（ユーザーが実際に行う2×2撮影）。
    /// 変更時は呼び出し側(View)が runStitch を呼び直して繋ぎ直す。
    @Published var style: SkyStitchStyle = .grid

    private let stitch: @Sendable ([UIImage], SkyStitchStyle) -> SkyStitchResult
    private let logger = Logger(subsystem: "com.soramoyou", category: "SkyStitchViewModel")

    init(
        stitch: @escaping @Sendable ([UIImage], SkyStitchStyle) -> SkyStitchResult = { SkyStitcher.stitch($0, style: $1) }
    ) {
        self.stitch = stitch
    }

    // MARK: - 合成

    /// 4枚（2枚以上）を合成する。重い処理なので非UIスレッドで実行し、結果でプレビュー or 撮り直し誘導。
    func runStitch(_ images: [UIImage]) async {
        state = .stitching
        let stitchFn = stitch
        let style = self.style
        let result = await Task.detached(priority: .userInitiated) { stitchFn(images, style) }.value

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

        // 合成の成功/失敗ファネルを計装（PII なし・列挙のみ）。
        let succeeded: Bool = { if case .previewReady = state { return true } else { return false } }()
        LoggingService.shared.logEvent("stitch_completed", parameters: [
            "succeeded": succeeded,
            "status": Self.statusLabel(result.status),
            "input_count": images.count,
            "style": style.rawValue
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

}
