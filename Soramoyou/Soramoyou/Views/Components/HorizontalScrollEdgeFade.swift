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
//  - 右端まで読み切ったら手がかりを消す。判定は「内容の右端」と「スクロールビュー自身の右端」の
//    比較で行う。⚠️ **画面幅（`UIScreen.main.bounds`）と比べてはいけない**。
//    iPad の Split View / Stage Manager ではウィンドウ幅が画面幅より狭く手がかりが永久に出ず、
//    iPhone 横向きでは safe area の分だけスクロールビュー右端が画面右端より内側になり、
//    内容がまだ隠れているのに手がかりが早く消える（レビュー D1）。
//  - ⚠️ 計測用の `preference` は **`.background` / `.overlay` の中に置くと親へ伝播しない**
//    （実測: 値が 0 のままだった）。GeometryReader を HStack の末尾に「幅 0 の実体」として
//    置くこと。この置き方でのみ動く。
//    一方、スクロールビュー自身の幅は `.overlay` 内で**その場で消費する**だけなので、
//    preference を経由せず GeometryReader から直接読んでよい（上の制約には抵触しない）。
//

import SwiftUI

// MARK: - PreferenceKey

/// スクロール内容の右端の X 座標（ウィンドウ座標系）を親へ伝えるキー。
struct HorizontalScrollTrailingEdgeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 計測マーカー

/// 横スクロールの内容（HStack）の末尾に置く、大きさ 0 の計測マーカー。
///
/// `.background` 経由だと preference が親に届かないため、`HStack` の要素として直接置く。
/// 幅も高さも 0 に固定するのは、GeometryReader が提案サイズを丸呑みして
/// 行の高さ決定に噛むのを防ぐため（レビュー D3）。`maxX` の値は 0×0 でも正しく取れる。
struct HorizontalScrollEndMarker: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: HorizontalScrollTrailingEdgeKey.self,
                value: geometry.frame(in: .global).maxX
            )
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

// MARK: - 判定ロジック（純関数・テスト対象）

/// 「まだ右に隠れている内容があるか」を判定する純関数群。
///
/// ビューから切り離してあるのでユニットテストできる（`HorizontalScrollEdgeFadeTests`）。
enum HorizontalScrollEdgeRule {
    /// 右端に着いたと見なす許容誤差（pt）。
    ///
    /// ⚠️ ここで吸収したいのはバウンスや端数だが、**実効的な不感帯はもっと広い**。
    /// マーカーは HStack の内側にあり、その外側に `.padding(.horizontal)`（16pt）が付き、
    /// さらに末尾要素との `spacing`（12〜16pt）も挟まる。つまり計測される右端は
    /// 「最後のチップの右端」より 14〜18pt ほど右にある。結果として、はみ出しが
    /// その程度以下のときは手がかりが出ない**安全側のヒステリシス**になる（レビュー D7）。
    static let defaultEpsilon: CGFloat = 2

    /// - Parameters:
    ///   - contentTrailingEdgeX: 内容の右端 X（マーカーが計測したウィンドウ座標）
    ///   - containerTrailingEdgeX: スクロールビュー自身の右端 X（同じ座標系）
    ///   - epsilon: 許容誤差
    /// - Returns: まだ右に隠れている内容があれば true
    ///
    /// 未計測（`contentTrailingEdgeX <= 0`）のときは true を返す。
    /// 初回表示で手がかりが出ないより、出るほうが目的（はみ出し時に確実に出す）に沿うため。
    static func hasMoreTrailing(
        contentTrailingEdgeX: CGFloat,
        containerTrailingEdgeX: CGFloat,
        epsilon: CGFloat = defaultEpsilon
    ) -> Bool {
        guard contentTrailingEdgeX > 0 else { return true }
        // コンテナ幅が未確定（0以下）のときも、出す側に倒す
        guard containerTrailingEdgeX > 0 else { return true }
        return contentTrailingEdgeX > containerTrailingEdgeX + epsilon
    }
}

// MARK: - Modifier

/// 横スクロールビューの右端に「続きがある」手がかりを重ねるモディファイア。
struct HorizontalScrollEdgeFade: ViewModifier {
    /// 手がかりの幅（pt）。チップ1個ぶんより狭くして内容を隠しすぎないようにする。
    private let fadeWidth: CGFloat = 32

    /// 内容の右端の X 座標（マーカーから届く・ウィンドウ座標系）
    @State private var contentTrailingEdgeX: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(HorizontalScrollTrailingEdgeKey.self) { newValue in
                // スクロール中は毎フレーム届くので、値が実際に変わったときだけ書き戻す
                // （毎フレームの再評価を避ける。レビュー D4）
                if newValue != contentTrailingEdgeX {
                    contentTrailingEdgeX = newValue
                }
            }
            .overlay {
                // スクロールビュー自身の右端をその場で読む（preference を経由しない）
                GeometryReader { geometry in
                    let hasMore = HorizontalScrollEdgeRule.hasMoreTrailing(
                        contentTrailingEdgeX: contentTrailingEdgeX,
                        containerTrailingEdgeX: geometry.frame(in: .global).maxX
                    )
                    ZStack(alignment: .trailing) {
                        if hasMore {
                            hintOverlay
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .animation(.easeInOut(duration: 0.15), value: hasMore)
                }
                // 下にあるチップをそのまま押せるようにする（手がかりは装飾のみ）
                .allowsHitTesting(false)
                // VoiceOver では読み上げない（スクロール自体は標準ジェスチャで伝わる）
                .accessibilityHidden(true)
            }
    }

    /// 右端に重ねる「続きがある」手がかり本体
    private var hintOverlay: some View {
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
        .transition(.opacity)
    }
}

extension View {
    /// 横スクロールビューの右端に「続きがある」手がかりを重ねる。
    /// 内容（HStack）の末尾に `HorizontalScrollEndMarker()` を置くこととセットで使う。
    func horizontalScrollEdgeFade() -> some View {
        modifier(HorizontalScrollEdgeFade())
    }
}
