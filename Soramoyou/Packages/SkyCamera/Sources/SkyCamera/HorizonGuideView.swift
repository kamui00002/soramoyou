// ⭐️ 水平線ガイド（傾きに追従する線・水平で色が変わる）
import SwiftUI
import UIKit

/// 傾きに追従して回転する水平線ガイド。
/// 水平（±1°）に入った瞬間だけ軽いハプティクスを 1 回返す（鳴り続けないよう状態の変化で判定）。
public struct HorizonGuideView: View {

    /// 現在の傾き読み取り結果。
    private let reading: HorizonMath.Reading

    /// 直前に「水平だった」か。ハプティクスを入った瞬間だけに絞るための記憶。
    @State private var wasLevel = false

    /// UI フレームの回転角（画面の向き由来）。
    /// 画面回転ロック中は端末を横にしても 0 のままで、そのぶんガイドを余分に回す必要がある。
    @State private var interfaceDegrees: Double = 0

    public init(reading: HorizonMath.Reading) {
        self.reading = reading
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let lineWidth = width * 0.6

            // ⚠️ 線の角度は `rollDegrees` ではなく `guideAngles` から取る。
            //    プレビューと撮影画像は端末の物理的な向きに追従するのに、ガイドだけ UI フレーム
            //    基準で描くと、画面回転ロック中の横持ちでガイドだけ縦のまま取り残される。
            let angles = HorizonMath.guideAngles(reading: reading, interfaceDegrees: interfaceDegrees)

            ZStack {
                // 基準線（撮影したときに水平になる向き）。ここに追従線が重なると「水平」。
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: lineWidth, height: 1)
                    .rotationEffect(.degrees(angles.reference))

                // 端末の傾きに追従する線。
                Rectangle()
                    .fill(reading.isLevel ? Color.green : Color.white.opacity(0.9))
                    .frame(width: lineWidth, height: reading.isLevel ? 2 : 1)
                    .rotationEffect(.degrees(angles.moving))
                    .animation(.linear(duration: 0.05), value: angles.moving)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // 真上（空）を向いていて傾きが求まらないときは、嘘の線を出さずに隠す。
            .opacity(reading.isReliable ? 1 : 0)
            .onAppear { interfaceDegrees = Self.currentInterfaceDegrees() }
            // UI が回ると必ずサイズが変わるので、これを「向きが変わった」合図に使う
            //（回転ロック中はサイズが変わらず 0 のまま＝それが正しい）。
            .onChange(of: geometry.size) { _ in
                interfaceDegrees = Self.currentInterfaceDegrees()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: reading.isLevel) { isLevel in
            // ⚠️ 記憶の更新は guard より**前**に行う。
            //    真上（空）を向いて計測不能になっている間も「水平だった」と覚えたままだと、
            //    水平に戻したときに `isLevel && !wasLevel` が成立せずハプティクスが 1 回鳴らない。
            //    計測不能時は `isLevel` が必ず false になるので、ここで記憶も一緒に落ちる。
            let wasLevelBefore = wasLevel
            wasLevel = isLevel
            guard reading.isReliable, isLevel, !wasLevelBefore else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// 現在の UI フレームの回転角を画面の向きから求める。
    /// `UIInterfaceOrientation` は端末の向き（`UIDeviceOrientation`）と**左右が逆**なので、
    /// 「正立から反時計回りに何度か」へ直すときは名前ではなく対応関係で変換する。
    private static func currentInterfaceDegrees() -> Double {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        switch scene?.interfaceOrientation {
        case .portrait:           return 0
        case .landscapeRight:     return 90    // 端末は landscapeLeft（正立から反時計回りに 90°）
        case .portraitUpsideDown: return 180
        case .landscapeLeft:      return 270   // 端末は landscapeRight
        default:                  return 0
        }
    }
}
