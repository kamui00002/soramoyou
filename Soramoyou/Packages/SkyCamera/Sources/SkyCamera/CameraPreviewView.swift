// ⭐️ カメラプレビュー（AVCaptureVideoPreviewLayer を SwiftUI に載せる）
import AVFoundation
import SwiftUI
import UIKit

/// 長押しロック中の「明るさ調整」ドラッグの段階。
public enum ExposureDragPhase: Equatable {
    /// 縦のドラッグが始まった。
    case began
    /// ドラッグ中。`translationY` は開始点からの縦の移動量（pt。UIKit の座標なので上が負）。
    case changed(translationY: CGFloat)
    /// 指を離した・取り消された（ロック解除でジェスチャが無効化された場合も含む）。
    case ended
}

/// 明るさ調整ドラッグを「縦に動かしたときだけ」始めさせる判定役。
///
/// ⚠️ 横成分の判定は**始まる前**（`gestureRecognizerShouldBegin`）に行う。
///    始まった後の `.changed` で捨てる形にすると、いったん始まったパンが
///    斜めのドラッグを最後まで握り続けてしまう。
/// ⚠️ デリゲートは弱参照で保持されるので、View 側が強参照で抱えること。
private final class ExposurePanDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: pan.view)
        // 縦成分の方が大きいときだけ明るさの操作として扱う。
        return abs(velocity.y) > abs(velocity.x)
    }
}

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

    /// 長押し（AE/AF ロック）のコールバック。
    /// 引数は (デバイス座標（0...1）, この View 上の座標（pt）)。
    /// ⭐️ View 上の座標は、ロック点に四角と ☀︎ を描くために使う。
    var onLongPress: ((CGPoint, CGPoint) -> Void)?

    /// 明るさ調整ドラッグ（ロック中の 1 本指の縦ドラッグ）のコールバック。
    var onExposureDrag: ((ExposureDragPhase) -> Void)?

    /// 明るさ調整ドラッグを受け付けるか（AE/AF ロック中だけ true にする）。
    /// ⚠️ false にすると進行中のドラッグは `.cancelled` になる。`.ended` と同じ扱いで
    ///    コールバックするので、解除と同時に指を動かしていても状態が取り残されない。
    var isExposureDragEnabled = false {
        didSet { exposurePan?.isEnabled = isExposureDragEnabled }
    }

    /// 明るさ調整ドラッグのジェスチャ（有効・無効の切り替えに使う）。
    private weak var exposurePan: UIPanGestureRecognizer?

    /// `exposurePan` の判定役（デリゲートは弱参照なのでここで保持する）。
    private let exposurePanDelegate = ExposurePanDelegate()

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
        // 明るさ調整。ピンチ（2 本指）と取り合わないよう 1 本指に限る。
        // タップ・長押しとは「指を動かしたか」で自然に分かれる（動かせばタップも長押しも成立しない）。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleExposurePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = exposurePanDelegate
        pan.isEnabled = isExposureDragEnabled
        addGestureRecognizer(tap)
        addGestureRecognizer(longPress)
        addGestureRecognizer(pan)
        exposurePan = pan
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
        onLongPress?(previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint), layerPoint)
    }

    @objc private func handleExposurePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onExposureDrag?(.began)
        case .changed:
            onExposureDrag?(.changed(translationY: recognizer.translation(in: self).y))
        case .ended, .cancelled, .failed:
            onExposureDrag?(.ended)
        default:
            break
        }
    }
}

/// プレビューの SwiftUI ラッパー。
public struct CameraPreviewView: UIViewRepresentable {

    private let session: AVCaptureSession
    private let onTap: (CGPoint) -> Void
    private let onLongPress: (CGPoint, CGPoint) -> Void
    private let isExposureDragEnabled: Bool
    private let onExposureDrag: (ExposureDragPhase) -> Void
    private let onPreviewReady: (CameraPreviewUIView) -> Void

    /// - Parameters:
    ///   - session: 表示するセッション
    ///   - onTap: タップ位置（デバイス座標）を受け取る
    ///   - onLongPress: 長押し位置（デバイス座標, この View 上の座標）を受け取る
    ///   - isExposureDragEnabled: 明るさ調整ドラッグを受け付けるか（AE/AF ロック中だけ true）
    ///   - onExposureDrag: 明るさ調整ドラッグの段階を受け取る
    ///   - onPreviewReady: 生成したプレビュー View を受け取る（回転の追従に使う）
    public init(
        session: AVCaptureSession,
        onTap: @escaping (CGPoint) -> Void,
        onLongPress: @escaping (CGPoint, CGPoint) -> Void,
        isExposureDragEnabled: Bool,
        onExposureDrag: @escaping (ExposureDragPhase) -> Void,
        onPreviewReady: @escaping (CameraPreviewUIView) -> Void
    ) {
        self.session = session
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.isExposureDragEnabled = isExposureDragEnabled
        self.onExposureDrag = onExposureDrag
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
        view.onExposureDrag = onExposureDrag
        view.isExposureDragEnabled = isExposureDragEnabled
        // 回転追従のため、生成直後に View を外へ渡す（`RotationCoordinator` の作り直しに使う）。
        onPreviewReady(view)
        return view
    }

    public func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // クロージャは body 再評価のたびに作り直されるので、毎回入れ替える（古い状態を掴ませない）。
        uiView.onTap = onTap
        uiView.onLongPress = onLongPress
        uiView.onExposureDrag = onExposureDrag
        // ロックの有無が変わるたびに body が再評価されるので、ここで必ず追従させる。
        uiView.isExposureDragEnabled = isExposureDragEnabled
    }
}
