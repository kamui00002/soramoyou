//  SkyStitcher.swift ⭐️
//  Soramoyou / Rendering/Stitching/
//
//  4方向ガイド撮影 → OpenCV cv::Stitcher(PANORAMA) で端末内広角合成（無料・サーバー不要）。
//  - C++/OpenCV は SkyStitcherBridge.mm に閉じ込め、Swift へは UIImage と status enum だけ公開。
//  - 出力は「投稿フローの1枚目」になる広角 UIImage（.up）。後段 PostInfoView 合流点へ渡せば
//    既存の mood/caption焼き込み・P3エンコード・skyType付与・アップロードが全部タダで乗る。
//  - OpenCV 未リンク時（SORAMOYOU_OPENCV 未定義）は .unavailable を返すスタブ。導入前でもビルド緑。

import UIKit

/// 合成結果ステータス（撮り直し誘導文言を Swift 側で出し分けるための分類）
enum SkyStitchStatus: Equatable {
    case ok                       // 合成成功
    case needMoreImages           // 入力不足 / 特徴マッチ不足（撮り直し: もっと重ねる）
    case homographyEstFailed      // 変換推定失敗（手ブレ等）
    case cameraParamsAdjustFailed // カメラ内部パラメータ調整失敗
    case unavailable              // OpenCV 未リンク（ビルド構成不備。実行時には出ない想定）
    case failed(code: Int)        // その他（OpenCV status をそのまま保持）
}

struct SkyStitchResult {
    let status: SkyStitchStatus
    let image: UIImage?           // status == .ok のときのみ非 nil
}

/// 空写真の広角合成器（薄い Swift ファサード）。重い処理なので非 UI スレッドから呼ぶこと。
enum SkyStitcher {

    /// 2〜N枚の空写真を1枚の広角に合成する。
    /// - Note: stitch 結果は独立アーティファクト。将来 enhance/upscale(M3) を呼び出し側で
    ///         合成と焼き込みの間に差し込めるよう、注入は呼び出し側責務にする。
    static func stitch(_ images: [UIImage]) -> SkyStitchResult {
        guard images.count >= 2 else {
            return SkyStitchResult(status: .needMoreImages, image: nil)
        }
        #if SORAMOYOU_OPENCV
        let bridge = SkyStitcherBridge.stitch(images)
        let status = Self.map(bridge.statusCode)
        return SkyStitchResult(status: status, image: status == .ok ? bridge.image : nil)
        #else
        return SkyStitchResult(status: .unavailable, image: nil)
        #endif
    }

    #if SORAMOYOU_OPENCV
    /// cv::Stitcher::Status (Int) → Swift enum。OK=0, ERR_NEED_MORE_IMGS=1,
    /// ERR_HOMOGRAPHY_EST_FAIL=2, ERR_CAMERA_PARAMS_ADJUST_FAIL=3。
    /// スタブの番兵 -999 も .unavailable へ落として契約を一貫させる。
    private static func map(_ code: Int) -> SkyStitchStatus {
        switch code {
        case 0:    return .ok
        case 1:    return .needMoreImages
        case 2:    return .homographyEstFailed
        case 3:    return .cameraParamsAdjustFailed
        case -999: return .unavailable
        default:   return .failed(code: code)
        }
    }
    #endif
}
