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

/// 撮り方（合成チューニングの切り替え）。横パンと4隅(2×2 面合成)でワープ/クロップを変える。
/// - pan : 左→右に重ねた横パン。円筒ワープ + 内接矩形クロップ（地平線が反りにくく、四隅の黒帯を除去）。
/// - grid: 上下左右(4隅)に振った面合成。球面ワープ + 許容70%クロップ（黒翼を削りつつ上下の内容を残す）。
enum SkyStitchStyle: String, CaseIterable, Identifiable {
    case pan
    case grid

    var id: String { rawValue }

    /// 表示名（撮り方セレクタ用）
    var displayName: String {
        switch self {
        case .pan:  return "横パン"
        case .grid: return "4隅"
        }
    }

    /// ブリッジに渡すワープ種別（0=球面 / 1=円筒。2=平面は未使用・将来チューニング候補）。
    /// pan=円筒（横パンで地平線が反りにくい）、grid=球面（上下左右の回転に強い＝全象限を残す）。
    var warperCode: Int { self == .pan ? 1 : 0 }
    /// ブリッジに渡すクロップ種別（0=なし / 1=内接矩形 / 4=許容70%）。
    /// pan=内接矩形（四隅の黒帯を除去）、grid=許容70%（球面の黒翼を削りつつ地上・空を最大限残す。実写4枚で確定）。
    var cropCode: Int { self == .pan ? 1 : 4 }
}

/// 空写真の広角合成器（薄い Swift ファサード）。重い処理なので非 UI スレッドから呼ぶこと。
enum SkyStitcher {

    /// 2〜N枚の空写真を1枚の広角に合成する。
    /// - Parameter style: 撮り方（既定 .pan＝横パン）。4隅(2×2)は .grid を渡す。
    /// - Note: stitch 結果は独立アーティファクト。将来 enhance/upscale(M3) を呼び出し側で
    ///         合成と焼き込みの間に差し込めるよう、注入は呼び出し側責務にする。
    static func stitch(_ images: [UIImage], style: SkyStitchStyle = .pan) -> SkyStitchResult {
        guard images.count >= 2 else {
            return SkyStitchResult(status: .needMoreImages, image: nil)
        }
        #if SORAMOYOU_OPENCV
        let bridge = SkyStitcherBridge.stitch(images, warper: style.warperCode, crop: style.cropCode)
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
