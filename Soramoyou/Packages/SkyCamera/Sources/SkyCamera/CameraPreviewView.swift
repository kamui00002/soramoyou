// ⭐️ カメラプレビュー（AVCaptureVideoPreviewLayer を SwiftUI に載せる）
import AVFoundation
import SwiftUI
import UIKit

/// `AVCaptureVideoPreviewLayer` を自前の layer として持つ UIView。
/// レイヤーを「view の上に載せる」のではなく「view そのもののレイヤーにする」ことで、
/// リサイズ時のズレ（レイアウトとレイヤーの frame 不一致）が構造的に起きないようにしている。
public final class CameraPreviewUIView: UIView {

    public override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    /// 型を確定させた参照（`layerClass` を上書きしているので強制キャストで安全）。
    public var previewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }

    /// タップ（点 AF/AE）のコールバック。引数はデバイス座標（0...1）。
    var onTap: ((CGPoint) -> Void)?

    /// 長押し（AE/AF ロック）のコールバック。引数はデバイス座標（0...1）。
    var onLongPress: ((CGPoint) -> Void)?

    /// iOS 17+ で適用したいプレビューの回転角（`RotationCoordinator` 由来）。
    ///
    /// ⚠️ **覚えておいて後からも適用する**のが肝。層のコネクションはセッションに入力が
    ///    追加されるまで出来上がらず、`makeUIView` の時点（＝構成前）ではまだ nil。
    ///    その瞬間に届いた角度を捨てるだけだと、**横持ちのままカメラを開いたとき**に
    ///    角度変化が一度も起きず、既定の縦向きで固まる。
    var desiredRotationAngle: CGFloat? {
        didSet { applyDesiredRotationAngle() }
    }

    /// 覚えている回転角をコネクションへ適用する（まだ適用できないときは何もしない）。
    func applyDesiredRotationAngle() {
        guard #available(iOS 17.0, *),
              let angle = desiredRotationAngle,
              let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(angle),
              connection.videoRotationAngle != angle else { return }
        connection.videoRotationAngle = angle
    }

    /// ジェスチャを 1 度だけ登録する。
    func installGesturesIfNeeded() {
        guard gestureRecognizers?.isEmpty ?? true else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(tap)
        addGestureRecognizer(longPress)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // 回転時は必ず layoutSubviews が走るので、ここを「取りこぼしの受け皿」にする。
        if #available(iOS 17.0, *) {
            // 角度は KVO（CameraSessionController）が push してくるが、
            // 届いた時点でコネクションが未生成だと適用できない。ここで必ず再試行する。
            applyDesiredRotationAngle()
        } else {
            // iOS 16 は `RotationCoordinator` が無いので画面の向きから直接決める。
            applyLegacyPreviewOrientation()
        }
    }

    /// iOS 16 用: 画面の向き → プレビューの向き。
    /// `UIInterfaceOrientation` と `AVCaptureVideoOrientation` は同名ケースが 1:1 に対応する
    ///（端末の向き `UIDeviceOrientation` とは左右が逆になるので、必ず**画面**の向きを使う）。
    private func applyLegacyPreviewOrientation() {
        guard let connection = previewLayer.connection,
              connection.isVideoOrientationSupported,
              let interfaceOrientation = window?.windowScene?.interfaceOrientation else { return }

        let videoOrientation: AVCaptureVideoOrientation
        switch interfaceOrientation {
        case .portrait:           videoOrientation = .portrait
        case .portraitUpsideDown: videoOrientation = .portraitUpsideDown
        case .landscapeLeft:      videoOrientation = .landscapeLeft
        case .landscapeRight:     videoOrientation = .landscapeRight
        default:                  return
        }
        guard connection.videoOrientation != videoOrientation else { return }
        connection.videoOrientation = videoOrientation
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let layerPoint = recognizer.location(in: self)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        // 長押しは began のときだけ拾う（押し続けている間の連続発火を避ける）。
        guard recognizer.state == .began else { return }
        let layerPoint = recognizer.location(in: self)
        onLongPress?(previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint))
    }
}

/// プレビューの SwiftUI ラッパー。
public struct CameraPreviewView: UIViewRepresentable {

    private let session: AVCaptureSession
    private let onTap: (CGPoint) -> Void
    private let onLongPress: (CGPoint) -> Void
    private let onPreviewReady: (CameraPreviewUIView) -> Void

    /// - Parameters:
    ///   - session: 表示するセッション
    ///   - onTap: タップ位置（デバイス座標）を受け取る
    ///   - onLongPress: 長押し位置（デバイス座標）を受け取る
    ///   - onPreviewReady: 生成したプレビュー View を受け取る（回転の追従に使う）
    public init(
        session: AVCaptureSession,
        onTap: @escaping (CGPoint) -> Void,
        onLongPress: @escaping (CGPoint) -> Void,
        onPreviewReady: @escaping (CameraPreviewUIView) -> Void
    ) {
        self.session = session
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.onPreviewReady = onPreviewReady
    }

    public func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        // 空は画面いっぱいに出したいので aspect fill（標準カメラと同じ）。
        view.previewLayer.videoGravity = .resizeAspectFill
        view.installGesturesIfNeeded()
        view.onTap = onTap
        view.onLongPress = onLongPress
        // 回転追従のため、生成直後に View を外へ渡す（`RotationCoordinator` の作り直しに使う）。
        onPreviewReady(view)
        return view
    }

    public func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // クロージャは body 再評価のたびに作り直されるので、毎回入れ替える（古い状態を掴ませない）。
        uiView.onTap = onTap
        uiView.onLongPress = onLongPress
    }
}
