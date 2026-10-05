//
//  SoratomoGlass.swift
//  Soramoyou
//
//  そらとものガラス（Liquid Glass）のカードと、その上に置く部品 ⭐️
//  （2026-10-05 ユーザーが候補 G3 を選択。handoffs/2026-10-05_そらとも要望_背景と公開投稿.md）
//
//  - カード: iOS 26 以上は本物の Liquid Glass（`.glassEffect`）。iOS 26 未満と「透明度を下げる」が ON のときは
//    不透明な白（ガラスのふりはしない）
//  - 灰色の小さい文字（N人・時刻・日付）は、空の上でもカードの上でも読める濃さにそろえる
//  - グループの頭文字の丸いアイコン（飾り）
//  使うのはグループ一覧（SoratomoGroupListView）とタイムライン（SoratomoTimelineView）だけ。
//  ⚠️ そらともの画面はライトに固定している（SoratomoSkyBackground.swift）ので、色は黒と白を基準にしている
//

import SwiftUI

// MARK: - カードの見た目

/// カードの見た目（ガラスか、不透明な白か）
enum SoratomoCardStyle: Equatable {
    /// 本物の Liquid Glass（iOS 26 以上）
    case glass
    /// 不透明な白（iOS 26 未満・「透明度を下げる」が ON）
    case opaque

    /// 端末の OS と「透明度を下げる」の設定から、カードの見た目を決める
    /// - Parameter reduceTransparency: 「透明度を下げる」が ON か
    /// - Returns: ガラスか、不透明な白か
    static func resolve(reduceTransparency: Bool) -> SoratomoCardStyle {
        // 「透明度を下げる」の人には、後ろの空が透けない白にする（文字を確実に読めるように）
        guard !reduceTransparency else { return .opaque }
        if #available(iOS 26.0, *) {
            return .glass
        }
        return .opaque
    }
}

/// カードの面（見た目を決めた後に描く部分）
///
/// 見た目を決める部分（`SoratomoCardModifier`）と分けてあるのは、「透明度を下げる」の設定がテストから
/// 切り替えられないため（環境の値が読み取り専用）。白のカードは、この面に `.opaque` を渡して部品単体で確かめる
struct SoratomoCardSurface: ViewModifier {
    // MARK: - Properties

    /// カードの見た目
    let style: SoratomoCardStyle

    /// カードの角の丸み（pt）
    static let cornerRadius: CGFloat = 22

    /// カードの形
    static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    // MARK: - Body

    func body(content: Content) -> some View {
        switch style {
        case .glass:
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: Self.shape)
            } else {
                // `.glass` は iOS 26 以上でしか作られない（resolve が決める）。念のため白に倒す
                content.background(Color.white, in: Self.shape)
            }
        case .opaque:
            content.background(Color.white, in: Self.shape)
        }
    }
}

/// そらとものカード（「透明度を下げる」の設定を読んで、ガラスか白かを決める）
struct SoratomoCardModifier: ViewModifier {
    /// 「透明度を下げる」が ON か
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.modifier(SoratomoCardSurface(style: .resolve(reduceTransparency: reduceTransparency)))
    }
}

extension View {
    /// そらとものカードにする（iOS 26 以上は本物の Liquid Glass・それより前と「透明度を下げる」のときは不透明な白）
    ///
    /// ⚠️ リストの行ごとに 1 枚ずつ独立したガラスになる（`GlassEffectContainer` は List の行をまたげない）。
    ///    ガラスは描くのが重いので、カードの中の写真やアイコンにはガラスを重ねないこと
    func soratomoCard() -> some View {
        modifier(SoratomoCardModifier())
            // 長押しのメニューで浮き上がる形をカードの形にする（四角のままだと角がはみ出る）
            .contentShape(.contextMenuPreview, SoratomoCardSurface.shape)
    }

    /// 空の背景の上の List（`.plain`）で、行をカードとして並べる
    /// （区切り線を消し、カードの間を空け、行の背景を透明にする）
    func soratomoCardRow() -> some View {
        listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .soratomoClearRowBackground()
    }
}

// MARK: - 文字の色

extension ShapeStyle where Self == Color {
    /// そらともの灰色の小さい文字（N人・時刻・日付・状態）。空の上でもカードの上でも読める濃さ
    ///
    /// 黒 75%。コントラスト比は、いちばん濃い空（daySkyGradient の 3 色目）の上で 5.1、カードの上で 7 以上。
    /// システムの灰色（secondaryLabel）は空の上で 2.1〜2.9、白の上でも 3.4 で、本文の基準 4.5 に届かない（2026-10-05 計算）
    static var soratomoSecondary: Color {
        Color.black.opacity(0.75)
    }
}

// MARK: - グループのアイコン

/// グループの頭文字の丸いアイコン（飾り。VoiceOver では読まない＝すぐ横にグループ名がある）
struct SoratomoGroupIcon: View {
    // MARK: - Properties

    /// グループ名
    let name: String

    /// 丸の直径（文字を大きくする設定に合わせて大きくする）
    @ScaledMetric(relativeTo: .headline) private var diameter: CGFloat = 44

    /// 丸の色。空の色（daySkyGradient）より 1〜2 段濃い青
    ///
    /// 空の色のままだと白い頭文字のコントラスト比が 1.5〜3.0 で薄いため、濃くした（4.5〜6.9・2026-10-05 ユーザー判断）
    static let gradientColors: [Color] = [
        Color(red: 0.26, green: 0.45, blue: 0.85),
        Color(red: 0.16, green: 0.33, blue: 0.72),
    ]

    // MARK: - Body

    var body: some View {
        Text(Self.initial(of: name))
            .font(.headline.bold())
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(
                LinearGradient(colors: Self.gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Circle()
            )
            .accessibilityHidden(true)
    }

    // MARK: - 補助

    /// アイコンに出す頭文字（1 文字目。絵文字や濁点つきの文字も 1 文字として扱う）
    /// - Parameter name: グループ名
    /// - Returns: 頭文字（名前が空なら空文字）
    static func initial(of name: String) -> String {
        name.first.map(String.init) ?? ""
    }
}
