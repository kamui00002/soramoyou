// ⭐️ ToneCurveView.swift
// インタラクティブなトーンカーブ編集UI（5点ベジェ）
//
//  ToneCurveView.swift
//  Soramoyou
//
// 🔧 2026-04-26 修正:
//   旧実装は各ハンドルに `.position(screenPt) → .contentShape(Circle().size(28x28))`
//   の順で modifier を適用していた。`.position` は view を「親と同じサイズで埋める
//   wrapper」に変換するため、後続の `.contentShape` が指定する 28x28 円は親の左上
//   (0,0) を中心に登録され、screenPt 上のタップを一切拾わない壊れ方をしていた
//   （5 個のハンドルすべてが原点に重なった当たり判定を持つ状態）。
//
//   `.position × .contentShape` の脆い相互作用を避けるため、ハンドル本体は純粋な
//   視覚要素（`.allowsHitTesting(false)`）にして、ZStack 全体に 1 つの DragGesture
//   を貼り、ドラッグ開始時に最近傍ハンドルを検出してロックするロバストなパターンに
//   置き換えた。
//

import SwiftUI

/// 5 点のトーンカーブをインタラクティブに操作するビュー
///
/// - 5 点の制御点をドラッグで動かせる
/// - グリッドと対角線（リニア参照線）を表示
/// - Binding<ToneCurvePoints> を通じて EditViewModel に値を反映
/// - `onEditEnd` コールバックでドラッグ終了を通知（Undo 履歴追加用）
struct ToneCurveView: View {

    // MARK: - Binding / Callbacks

    @Binding var points: ToneCurvePoints

    /// ドラッグ終了時に呼ばれるコールバック（Undo 履歴追加用）
    var onEditEnd: (() -> Void)? = nil

    // MARK: - Constants

    /// タッチ可能な最大半径（pts）。この距離以内にある最も近いハンドルがドラッグ対象になる。
    private let handleRadius: CGFloat = 22
    /// 操作ハンドルの描画半径（pts）
    private let dotRadius: CGFloat = 6
    /// グリッド分割数
    private let gridDivisions: Int = 4

    // MARK: - State

    /// ドラッグ中のハンドルインデックス（0〜4, nil = ドラッグなし）
    @State private var draggingIndex: Int? = nil

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)

            ZStack(alignment: .topLeading) {
                // グリッド背景
                gridView(size: size)

                // リニア参照線（対角線）
                linearReferenceLine(size: size)

                // トーンカーブ
                curveShape(size: size)
                    .stroke(Color.white, lineWidth: 2)

                // 制御点ハンドル（純粋な視覚要素。ジェスチャは下の親 ZStack に集約）
                ForEach(0..<5, id: \.self) { i in
                    let pt = point(at: i)
                    let screenPt = toScreen(pt, size: size)

                    Circle()
                        .fill(draggingIndex == i ? Color.yellow : Color.white)
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.5), lineWidth: 1)
                        )
                        .frame(width: dotRadius * 2, height: dotRadius * 2)
                        .position(screenPt)
                        .allowsHitTesting(false)
                }

                // リセットボタン
                VStack {
                    HStack {
                        Spacer()
                        if points != .identity {
                            Button(action: {
                                withAnimation { points = .identity }
                                onEditEnd?()   // Undo 履歴にリセット前の状態を記録
                            }) {
                                Text("リセット")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.7))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.15))
                                    .cornerRadius(4)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(4)
            }
            .frame(width: size, height: size)
            .background(Color.black.opacity(0.4))
            .cornerRadius(8)
            // ZStack 全体を当たり判定領域にして、最近傍ハンドル検出方式でドラッグを処理する
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if draggingIndex == nil {
                            // 最初の接触: handleRadius 以内で最も近いハンドルをロック
                            var nearestIndex: Int? = nil
                            var nearestDistance: CGFloat = .greatestFiniteMagnitude
                            for idx in 0..<5 {
                                let p = toScreen(point(at: idx), size: size)
                                let d = hypot(value.location.x - p.x, value.location.y - p.y)
                                if d < nearestDistance {
                                    nearestDistance = d
                                    nearestIndex = idx
                                }
                            }
                            guard let nearest = nearestIndex,
                                  nearestDistance <= handleRadius else {
                                return  // どのハンドルにも近くない
                            }
                            draggingIndex = nearest
                        }
                        if let i = draggingIndex {
                            let normalized = toNormalized(value.location, size: size)
                            updatePoint(at: i, to: normalized)
                        }
                    }
                    .onEnded { _ in
                        if draggingIndex != nil {
                            draggingIndex = nil
                            onEditEnd?()
                        }
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Views

    /// グリッド線
    private func gridView(size: CGFloat) -> some View {
        Canvas { ctx, _ in
            let step = size / CGFloat(gridDivisions)
            let gridColor = Color.white.opacity(0.15)

            for i in 1..<gridDivisions {
                let x = step * CGFloat(i)
                let y = step * CGFloat(i)

                // 縦線
                var vPath = Path()
                vPath.move(to: CGPoint(x: x, y: 0))
                vPath.addLine(to: CGPoint(x: x, y: size))
                ctx.stroke(vPath, with: .color(gridColor), lineWidth: 0.5)

                // 横線
                var hPath = Path()
                hPath.move(to: CGPoint(x: 0, y: y))
                hPath.addLine(to: CGPoint(x: size, y: y))
                ctx.stroke(hPath, with: .color(gridColor), lineWidth: 0.5)
            }

            // 外枠
            var borderPath = Path()
            borderPath.addRect(CGRect(origin: .zero, size: CGSize(width: size, height: size)))
            ctx.stroke(borderPath, with: .color(Color.white.opacity(0.3)), lineWidth: 1)
        }
        .frame(width: size, height: size)
    }

    /// リニア（対角）参照線
    private func linearReferenceLine(size: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size))
            path.addLine(to: CGPoint(x: size, y: 0))
        }
        .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    /// トーンカーブ Shape
    private func curveShape(size: CGFloat) -> Path {
        Path { path in
            let allPts = [points.point0, points.point1, points.point2, points.point3, points.point4]
            let screenPts = allPts.map { toScreen($0, size: size) }

            path.move(to: screenPts[0])
            // カトマル・ロム スプライン近似（隣接 2 点で曲線制御）
            for i in 0..<(screenPts.count - 1) {
                let p0 = i > 0 ? screenPts[i - 1] : screenPts[i]
                let p1 = screenPts[i]
                let p2 = screenPts[i + 1]
                let p3 = i + 2 < screenPts.count ? screenPts[i + 2] : screenPts[i + 1]

                let cp1 = CGPoint(
                    x: p1.x + (p2.x - p0.x) / 6.0,
                    y: p1.y + (p2.y - p0.y) / 6.0
                )
                let cp2 = CGPoint(
                    x: p2.x - (p3.x - p1.x) / 6.0,
                    y: p2.y - (p3.y - p1.y) / 6.0
                )
                path.addCurve(to: p2, control1: cp1, control2: cp2)
            }
        }
    }

    // MARK: - Helpers

    /// インデックスから CurvePoint を取得
    private func point(at index: Int) -> CurvePoint {
        switch index {
        case 0: return points.point0
        case 1: return points.point1
        case 2: return points.point2
        case 3: return points.point3
        case 4: return points.point4
        default: fatalError("Invalid curve point index")
        }
    }

    /// ドラッグで制御点を更新（x 軸は固定・ソート維持、y 軸のみ変化）
    private func updatePoint(at index: Int, to normalized: CurvePoint) {
        // x 軸は固定（制御点を移動させると補間が破綻するため）。
        // 両端 (0, 4) も含めて x は常に元の値で保持する。
        // y 軸のみ 0...1 にクランプ
        let newY = max(0.0, min(1.0, normalized.y))
        let originalX = point(at: index).x

        switch index {
        case 0: points.point0 = CurvePoint(x: originalX, y: newY)
        case 1: points.point1 = CurvePoint(x: originalX, y: newY)
        case 2: points.point2 = CurvePoint(x: originalX, y: newY)
        case 3: points.point3 = CurvePoint(x: originalX, y: newY)
        case 4: points.point4 = CurvePoint(x: originalX, y: newY)
        default: break
        }
    }

    /// 正規化座標 → スクリーン座標（y 軸反転: 正規化 0=暗, 1=明 → 画面上は下=暗, 上=明）
    private func toScreen(_ pt: CurvePoint, size: CGFloat) -> CGPoint {
        CGPoint(x: pt.x * size, y: (1.0 - pt.y) * size)
    }

    /// スクリーン座標 → 正規化座標
    private func toNormalized(_ screenPt: CGPoint, size: CGFloat) -> CurvePoint {
        CurvePoint(
            x: screenPt.x / size,
            y: 1.0 - (screenPt.y / size)
        )
    }
}

// MARK: - Preview

struct ToneCurveView_Preview: View {
    @State private var pts = ToneCurvePoints()

    var body: some View {
        ToneCurveView(points: $pts)
            .frame(width: 260, height: 260)
            .background(Color.black)
            .preferredColorScheme(.dark)
    }
}

#Preview {
    ToneCurveView_Preview()
}
