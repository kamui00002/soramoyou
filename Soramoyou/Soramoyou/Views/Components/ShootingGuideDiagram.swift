//
//  ShootingGuideDiagram.swift ⭐️
//  Soramoyou
//
//  広角合成の「撮り方」を示す図解コンポーネント。
//  上下左右に少しずつ振って重ねて撮った4枚が、中央で重なって1枚になることを 2×2 の重なり絵で伝える。
//  - オンボーディング(WhatsNewView・色背景)では tint=.white
//  - 合成画面のヘルプシート(白背景)では tint=空色
//  どちらでも見えるよう配色は tint で差し替え可能。
//

import SwiftUI

/// 広角合成の撮り方図解（4隅を重ねて撮る 2×2 の重なり絵）。
struct ShootingGuideDiagram: View {
    /// 線・塗りの基準色（色背景なら白、白背景なら空色など）
    var tint: Color = .white
    /// 図全体の一辺の目安
    var size: CGFloat = 180

    var body: some View {
        // 各写真フレームの一辺と、中心からのずらし量（重なりを作る）
        let frame = size * 0.50
        let shift = size * 0.15
        // (x方向, y方向, 番号, 振る向きの矢印)
        let cells: [(CGFloat, CGFloat, Int, String)] = [
            (-shift, -shift, 1, "arrow.up.left"),
            ( shift, -shift, 2, "arrow.up.right"),
            (-shift,  shift, 3, "arrow.down.left"),
            ( shift,  shift, 4, "arrow.down.right")
        ]
        ZStack {
            // 4枚の写真フレーム（半透明・重なり）
            ForEach(cells, id: \.2) { cell in
                RoundedRectangle(cornerRadius: 9)
                    .fill(tint.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(tint.opacity(0.85), lineWidth: 1.5)
                    )
                    .frame(width: frame, height: frame)
                    .overlay(
                        Image(systemName: cell.3)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(tint.opacity(0.9))
                            // フレームの外側の角寄りに矢印を置く（振る向き）
                            .offset(x: cell.0 < 0 ? -frame * 0.3 : frame * 0.3,
                                    y: cell.1 < 0 ? -frame * 0.3 : frame * 0.3)
                    )
                    .offset(x: cell.0, y: cell.1)
            }
            // 中央の重なり（＝合成される領域）を強調
            RoundedRectangle(cornerRadius: 6)
                .fill(tint.opacity(0.34))
                .frame(width: frame - shift * 2, height: frame - shift * 2)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(tint)
                )
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("撮り方の図。上下左右に少しずつ振って、重ねながら4枚撮ると中央が重なって1枚になります")
    }
}

// MARK: - 撮り方のコツ（ヘルプシート）

/// 合成画面の「？」から開く撮り方ガイド。図解＋コツの箇条書き。
/// 閉じる操作は呼び出し側に委ねる（このプロジェクトの sheet クローズ慣習＝明示 onClose）。
/// `@Environment(\.dismiss)` は presentation 文脈次第で効かないことがあるため使わない。
struct SkyStitchHelpView: View {
    /// 閉じる操作（呼び出し側で sheet を閉じる）
    let onClose: () -> Void

    /// 白背景でも見える空色（オンボの青系グラデと同系）
    private let skyBlue = Color(red: 0.39, green: 0.58, blue: 0.93)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    ShootingGuideDiagram(tint: skyBlue, size: 200)
                        .padding(.top, 12)

                    Text("上下左右に少しずつ振って、\n重ねながら4枚撮るのがコツ")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 14) {
                        tip("重ねるほど広く仕上がる", "となりの写真と大きく重なるように撮ると、横に広い1枚になります。", "arrow.left.and.right")
                        tip("振りすぎると正方形に近づく", "上下左右に大きく振ると四隅に写真が無くなり、黒を消すぶん中央寄り（正方形に近い形）になります。", "square")
                        tip("順番は自動", "撮った順番は気にしなくてOK。自動でつなげます。", "wand.and.stars")
                        tip("うまく繋がらない時は", "「配置写真」モードなら4枚をそのまま並べて確実に1枚にできます。", "square.grid.2x2")
                    }
                    .padding(.horizontal, 4)
                }
                .padding(20)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("撮り方のコツ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { onClose() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    /// コツ1項目（アイコン＋見出し＋本文）
    private func tip(_ title: String, _ body: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(skyBlue)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(body)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Preview

#Preview("図解（色背景）") {
    ZStack {
        LinearGradient(colors: [Color(red: 0.53, green: 0.81, blue: 0.98),
                                Color(red: 0.39, green: 0.58, blue: 0.93)],
                       startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        ShootingGuideDiagram(tint: .white, size: 200)
    }
}

#Preview("ヘルプシート") {
    SkyStitchHelpView(onClose: {})
}
