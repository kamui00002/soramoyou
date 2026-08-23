//
//  HorizontalScrollEdgeFade.swift
//  Soramoyou
//
//  横スクロール行の右端に「まだ続きがある」ことを示す手がかりを重ねる仕組み ⭐️
//
//  背景（2026-08-23 の PostHog 実査）:
//  編集画面のフィルター行は「なし」＋10種類＝計11個あるのに画面には5個ぶんしか映らず、
//  `showsIndicators: false` でスクロールバーも出ないため「ここで終わり」に見えていた。
//  実際、右端付近（画面の横91%・縦82%）に rageclick が 6 件・4 日ぶん集中していた
//  （＝続きを出そうとして端を繰り返し触っていた）。
//
//  実装方針:
//  - 手がかりは「矢印（chevron）＋下地の黒フェード」。フェード単体では、チップの地色が
//    もともと暗いため見分けが付かないことをシミュレータ実測で確認している（明度 25→14 程度）。
//  - `.overlay` + `allowsHitTesting(false)` で重ねる。`.mask` はヒットテストにも効いてしまい、
//    いちばん端のチップが押しにくくなる本末転倒を招くため使わない。
//  - 右端まで読み切ったら手がかりを消す。そのために内容の右端位置を計測する。
//    ⚠️ 計測用の `preference` は **`.background` / `.overlay` の中に置くと親へ伝播しない**
//       （実測: 値が 0 のままだった）。GeometryReader を HStack の末尾に「幅 0 の実体」として
//       置くこと。この置き方でのみ動く。
//

import SwiftUI

// MARK: - PreferenceKey

/// スクロール内容の右端の画面上 X 座標を親へ伝えるキー。
struct HorizontalScrollTrailingEdgeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 計測マーカー

/// 横スクロールの内容（HStack）の末尾に置く、幅 0 の計測マーカー。
///
/// `.background` 経由だと preference が親に届かないため、`HStack` の要素として直接置く。
/// 幅 0・ヒットテスト無効なので見た目と操作には影響しない。
struct HorizontalScrollEndMarker: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: HorizontalScrollTrailingEdgeKey.self,
                // 画面全体（.global）基準で内容の右端を測る。
                // スクロール行は画面幅いっぱいに置かれる前提なので、画面幅と比べるだけで
                // 「まだ右に隠れているか」を判定できる（ScrollView の幅を別途測らずに済む）。
                value: geometry.frame(in: .global).maxX
            )
        }
        .frame(width: 0)
        .allowsHitTesting(false)
    }
}

// MARK: - Modifier

/// 横スクロールビューの右端に「続きがある」手がかりを重ねるモディファイア。
struct HorizontalScrollEdgeFade: ViewModifier {
    /// 手がかりの幅（pt）。チップ1個ぶんより狭くして内容を隠しすぎないようにする。
    private let fadeWidth: CGFloat = 32
    /// 右端に着いたと見なす許容誤差（pt）。バウンスや端数でのちらつきを防ぐ。
    private let epsilon: CGFloat = 2

    /// 内容の右端の画面上 X 座標（マーカーから届く）
    @State private var contentTrailingEdgeX: CGFloat = 0

    /// まだ右に隠れている内容があるか。
    /// 未計測（0）のときは true にしておく（初回表示で手がかりが出ないより、出るほうが安全）。
    private var hasMoreTrailing: Bool {
        guard contentTrailingEdgeX > 0 else { return true }
        return contentTrailingEdgeX > UIScreen.main.bounds.width + epsilon
    }

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(HorizontalScrollTrailingEdgeKey.self) { contentTrailingEdgeX = $0 }
            .overlay(alignment: .trailing) {
                if hasMoreTrailing {
                    ZStack(alignment: .trailing) {
                        // ⚠️ 編集画面の背景が黒（`EditView` の `.background(Color.black)`）である前提の色。
                        //    背景色が違う画面で使うときは色を引数化すること。
                        LinearGradient(
                            colors: [Color.black.opacity(0), Color.black.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: fadeWidth)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white.opacity(0.55))
                            .padding(.trailing, 4)
                    }
                    // 下にあるチップをそのまま押せるようにする（手がかりは装飾のみ）
                    .allowsHitTesting(false)
                    // VoiceOver では読み上げない（スクロール自体は標準ジェスチャで伝わる）
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: hasMoreTrailing)
    }
}

extension View {
    /// 横スクロールビューの右端に「続きがある」手がかりを重ねる。
    /// 内容（HStack）の末尾に `HorizontalScrollEndMarker()` を置くこととセットで使う。
    func horizontalScrollEdgeFade() -> some View {
        modifier(HorizontalScrollEdgeFade())
    }
}
