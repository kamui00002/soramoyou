// ⭐️ 長押しロック中の「明るさ調整（☀︎）」の表示と状態（黄色い四角・太陽マーク・補正値ラベル）
import SwiftUI

/// ロック中の明るさ調整の表示状態。
///
/// ⚠️ **ViewModel（`SkyCameraViewModel`）の `@Published` に置かず、別の観測対象にしている。**
///    ドラッグ中は値が細かく変わるので、ViewModel に置くと画面全体が作り直され、
///    ボタンのタップを取りこぼす（`HorizonMonitor` を `HorizonGuideContainer` に閉じ込めたのと同じ理由）。
///    ViewModel は素の `let` で抱え、観測は `ManualExposureOverlay` の中だけで行う。
@MainActor
final class ManualExposureOverlayModel: ObservableObject {
    // MARK: - 表示状態

    /// ロック点（プレビュー View 上の座標）。nil なら何も出さない。
    @Published private(set) var lockPoint: CGPoint?

    /// いまかかっている補正値（EV。表示用）。
    @Published private(set) var bias: Float = 0

    /// 動かせる範囲。nil の間（取得前・端末の範囲が壊れている）は太陽マークを出さない
    /// （動かせないものを動かせるように見せない）。
    @Published private(set) var range: ClosedRange<Float>?

    /// 補正値ラベル（「+0.7」など）を出しているか。
    @Published private(set) var isShowingValue = false

    // MARK: - 内部状態

    /// ドラッグを始めたときの補正値。ドラッグ中はここを基準に移動量を足す。
    private var dragStartBias: Float?

    /// ドラッグの基準にした縦位置（pt）。通常は 0。
    /// ⚠️ ドラッグ開始が範囲の取得より先だった場合、取得できた時点の位置を基準にする。
    ///    そうしないと、それまでの移動量が一気に効いて明るさが跳ぶ。
    private var dragOriginY: CGFloat = 0

    /// 指を離してからラベルを消すまでの予約。
    private var hideValueTask: Task<Void, Never>?

    /// ロックの世代。ロックし直した・解除したあとに、古いロックの取得結果が届いても捨てる。
    private var generation: UInt64 = 0

    /// 指を離してから補正値ラベルを消すまでの時間（秒）。
    private static let valueDisplayDuration: UInt64 = 1_500_000_000

    // MARK: - ロック

    /// ロックした。ロック点に四角と太陽マークを出し、明るさの開始値と範囲を取りに行く。
    /// - Parameters:
    ///   - point: ロック点（プレビュー View 上の座標）
    ///   - controller: 開始値と範囲の問い合わせ先
    func beginLock(at point: CGPoint, controller: CameraSessionController) {
        generation &+= 1
        let current = generation
        resetDragState()
        lockPoint = point
        range = nil
        bias = 0
        Task { [weak self] in
            // ⭐️ ロック中は空優先 AE が補正を書かないので、ロック直後に取った値が
            //    そのままドラッグの開始値になる（以後、値を動かすのは手動だけ）。
            let context = await controller.manualExposureContext()
            guard let self, generation == current else { return }
            bias = context.bias
            range = context.range
        }
    }

    /// ロック中に、手動以外の理由で補正値が変わった（空優先 AE を OFF にして 0 に戻った等）ときに、
    /// 表示とドラッグの基準を実際の値へ取り直す。
    ///
    /// ⚠️ 取り直さないと、太陽マークは古い値（例 -1.0）のまま、実際は 0 になっている。
    ///    その状態で上へドラッグすると -1.0 を起点に計算するので、「明るくしたのに暗くなる」。
    ///    コントローラの処理は直列キューなので、ここで取る値は 0 に戻した後の値になる。
    func resync(controller: CameraSessionController) {
        guard lockPoint != nil else { return }
        let current = generation
        Task { [weak self] in
            let context = await controller.manualExposureContext()
            guard let self, generation == current, lockPoint != nil else { return }
            bias = context.bias
            range = context.range
            // ドラッグの途中なら、次の指の動きから「いまの位置」を基準に計算し直す
            // （範囲の取得がドラッグ開始に間に合わなかったときと同じ経路に乗せる）。
            if dragStartBias != nil { dragStartBias = nil }
        }
    }

    /// ロックが解けた（タップ・ロック中の長押し・レンズの付け替え）。四角と太陽マークを消す。
    func endLock() {
        generation &+= 1
        resetDragState()
        lockPoint = nil
        range = nil
    }

    // MARK: - ドラッグ

    /// ドラッグが始まった。
    func dragBegan() {
        dragOriginY = 0
        dragStartBias = range == nil ? nil : bias
        showValue()
    }

    /// ドラッグ中。補正値を計算してコントローラへ渡す。
    /// - Parameters:
    ///   - translationY: ドラッグ開始点からの縦の移動量（pt。上が負）
    ///   - controller: 補正値の書き込み先
    func dragChanged(translationY: CGFloat, controller: CameraSessionController) {
        guard let range, lockPoint != nil else { return }
        if dragStartBias == nil {
            // 範囲の取得がドラッグ開始に間に合わなかった。いまの位置を基準にして始める。
            dragStartBias = bias
            dragOriginY = translationY
        }
        guard let start = dragStartBias else { return }
        showValue()
        let next = ManualExposure.bias(startBias: start,
                                       translationY: translationY - dragOriginY,
                                       range: range)
        // 0.1 EV 刻みなので、値が変わったときだけ送る（同じ値を 60Hz で書き直さない）。
        guard next != bias else { return }
        bias = next
        controller.setManualExposureBias(next)
    }

    /// 指を離した。約 1.5 秒後にラベルを薄く消す（太陽マークはロック中ずっと出す）。
    func dragEnded() {
        dragStartBias = nil
        dragOriginY = 0
        scheduleHideValue()
    }

    // MARK: - アクセシビリティ

    /// VoiceOver の「増やす／減らす」で 1/3 EV ずつ動かす。
    /// - Parameters:
    ///   - direction: 増やすなら +1、減らすなら -1
    ///   - controller: 補正値の書き込み先
    func adjust(direction: Int, controller: CameraSessionController) {
        guard let range, lockPoint != nil else { return }
        let next = ManualExposure.steppedBias(currentBias: bias, direction: direction, range: range)
        showValue()
        scheduleHideValue()
        guard next != bias else { return }
        bias = next
        controller.setManualExposureBias(next)
    }

    // MARK: - Private

    /// ラベルを出す（消す予約があれば取り消す）。
    private func showValue() {
        hideValueTask?.cancel()
        hideValueTask = nil
        if !isShowingValue { isShowingValue = true }
    }

    /// 少し待ってからラベルを消す予約を入れる。
    private func scheduleHideValue() {
        hideValueTask?.cancel()
        hideValueTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.valueDisplayDuration)
            guard !Task.isCancelled else { return }
            self?.isShowingValue = false
        }
    }

    /// ドラッグとラベルの状態を初期化する。
    private func resetDragState() {
        hideValueTask?.cancel()
        hideValueTask = nil
        dragStartBias = nil
        dragOriginY = 0
        isShowingValue = false
    }
}

/// ロック点の黄色い四角と、その横の太陽マーク（明るさ）。
///
/// ⚠️ タッチは一切受けない（`allowsHitTesting(false)`）。操作はすべて下のプレビューが受ける
///    （ドラッグはプレビュー上のどこでもよい。太陽マークを正確に掴ませない）。
struct ManualExposureOverlay: View {
    @ObservedObject var model: ManualExposureOverlayModel

    /// VoiceOver の「増やす／減らす」（+1 / -1）。
    let onAdjust: (Int) -> Void

    /// ロック点の四角の一辺（pt）。
    private static let boxSize: CGFloat = 70
    /// 四角と太陽マークの間隔（pt）。
    private static let sunGap: CGFloat = 18
    /// トラック線の長さの半分（pt）。±2 EV が両端に当たる。
    private static let trackHalfLength: CGFloat = 50

    var body: some View {
        GeometryReader { proxy in
            if let point = model.lockPoint {
                ZStack {
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: Self.boxSize, height: Self.boxSize)
                        .position(point)
                        .accessibilityHidden(true)

                    if model.range != nil {
                        sunControl
                            .position(x: sunX(lockX: point.x, width: proxy.size.width), y: point.y)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 太陽マーク・トラック線・補正値ラベル。
    private var sunControl: some View {
        ZStack {
            // 細い縦のトラック線。
            Rectangle()
                .fill(Color.yellow.opacity(0.6))
                .frame(width: 1, height: Self.trackHalfLength * 2)

            Image(systemName: "sun.max.fill")
                .font(.system(size: 18))
                .foregroundColor(.yellow)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .offset(y: ManualExposure.indicatorOffset(bias: model.bias,
                                                          trackHalfLength: Self.trackHalfLength))

            // 補正値ラベルは太陽マークの横に出す。ドラッグ中だけ見せ、離して少ししたら薄く消す。
            Text(ManualExposure.displayText(model.bias))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(.yellow)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .fixedSize()
                .offset(x: 30,
                        y: ManualExposure.indicatorOffset(bias: model.bias,
                                                          trackHalfLength: Self.trackHalfLength))
                .opacity(model.isShowingValue ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: model.isShowingValue)
        }
        .frame(width: 24, height: Self.trackHalfLength * 2 + 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("明るさ")
        .accessibilityValue(ManualExposure.accessibilityValue(model.bias))
        .accessibilityHint("上下にスワイプして明るさを調整します")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onAdjust(1)
            case .decrement: onAdjust(-1)
            @unknown default: break
            }
        }
    }

    /// 太陽マークの横位置。基本は四角の右。
    /// ⚠️ 画面の右端近くでロックすると右側に出すと見切れるので、そのときだけ左に出す。
    private func sunX(lockX: CGFloat, width: CGFloat) -> CGFloat {
        let offset = Self.boxSize / 2 + Self.sunGap
        // ラベル（右へ 30pt + 文字幅）が収まる余裕を見て判定する。
        if lockX + offset + 60 > width {
            return lockX - offset
        }
        return lockX + offset
    }
}
