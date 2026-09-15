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

    /// ジェスチャを 1 度だけ登録する。
    func installGesturesIfNeeded() {
        guard gestureRecognizers?.isEmpty ?? true else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(tap)
        addGestureRecognizer(longPress)
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

    /// - Parameters:
    ///   - session: 表示するセッション
    ///   - onTap: タップ位置（デバイス座標）を受け取る
    ///   - onLongPress: 長押し位置（デバイス座標）を受け取る
    public init(
        session: AVCaptureSession,
        onTap: @escaping (CGPoint) -> Void,
        onLongPress: @escaping (CGPoint) -> Void
    ) {
        self.session = session
        self.onTap = onTap
        self.onLongPress = onLongPress
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
        return view
    }

    public func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // クロージャは body 再評価のたびに作り直されるので、毎回入れ替える（古い状態を掴ませない）。
        uiView.onTap = onTap
        uiView.onLongPress = onLongPress
    }
}
