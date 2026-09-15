// ⭐️ 端末の傾きを監視して水平線ガイドへ流す（CoreMotion）
import Combine
import CoreMotion
import Foundation

/// `CMMotionManager` の deviceMotion を購読し、傾きを UI へ配る監視役。
///
/// iOS 16 を最低対応にしているため `@Observable`（iOS 17+）は使わず `ObservableObject` を使う。
/// `CMDeviceMotion` の重力ベクトルは使用許可文言が不要（`NSMotionUsageDescription` が要るのは
/// 歩数計・気圧計・モーションアクティビティであり、加速度/ジャイロ由来の姿勢は対象外）。
public final class HorizonMonitor: ObservableObject {

    /// 直近の傾き読み取り結果。
    @Published public private(set) var reading = HorizonMath.Reading(
        rollDegrees: 0,
        isLevel: false,
        isReliable: false
    )

    private let motionManager = CMMotionManager()

    /// 更新周期（秒）。30Hz 程度あればガイドの追従は十分滑らか。
    private let updateInterval: TimeInterval = 1.0 / 30.0

    public init() {}

    deinit {
        motionManager.stopDeviceMotionUpdates()
    }

    /// 監視を開始する。deviceMotion が使えない端末では何もしない（ガイドは非表示のまま）。
    public func start() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = updateInterval
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let gravity = motion.gravity
            // ハンドラは `to: .main`（OperationQueue.main）指定なので必ずメインスレッドで呼ばれる。
            // よって @Published の更新をそのまま行ってよい（Task への包み直しは不要）。
            self.reading = HorizonMath.reading(gravityX: gravity.x, gravityY: gravity.y)
        }
    }

    /// 監視を停止する（画面を閉じたら必ず呼ぶ＝バッテリー消費を残さない）。
    public func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}
