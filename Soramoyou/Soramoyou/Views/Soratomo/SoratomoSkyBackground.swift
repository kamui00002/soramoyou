//
//  SoratomoSkyBackground.swift
//  Soramoyou
//
//  そらともの画面の背景を、アプリ本体と同じ雲つきの空にそろえる ⭐️
//  （2026-10-05 ユーザーの要望 1・段階 1。handoffs/2026-10-05_そらとも要望_背景と公開投稿.md）
//
//  それまでは背景を指定しておらず、端末がダークモードだと黒になっていた（黒は空と相性が悪い、という要望）。
//  - 空は既存の `SkyBackgroundView`（ログイン画面と同じ雲つき）をそのまま使う。部品そのものは変えない
//  - そらともの画面は、端末がダークモードでもライトの見た目（明るい空＋黒い文字）に固定する。
//    空の色は明るい水色で固定なので、ダークの白い文字では読めない。最初はダークのときだけ黒を 50% 重ねたが、
//    実機で「めちゃ暗い・もっと明るいのがいい」となった（2026-10-05 build 107 の目視・ユーザーが「いつも明るい空」を選択）
//  - 固定は表示の単位（全画面のカバー・シート）ごとに効く。根の一覧はカバーの底にいつも居るので、
//    カバーの中の投稿詳細もライトになる（投稿詳細は背景をシステムの色に任せているので、薄い灰色になる）
//  - 写真を大きく見る投稿詳細（SoratomoSkyDetailView）には空を付けない（写真の色を空の青が邪魔しないように・ユーザー判断）
//

import SwiftUI

// MARK: - 背景の修飾子

/// そらともの画面の背景（雲つきの空）。List・Form・ScrollView の既定の背景を隠して、後ろの空を見せる
///
/// 見た目はライトに固定する（黒い文字と空のコントラスト比は 7.0〜13.8。WCAG の本文の基準 4.5 を満たす。
/// daySkyGradient の 3 色で計算・2026-10-05）
struct SoratomoSkyBackgroundModifier: ViewModifier {
    // MARK: - Body

    func body(content: Content) -> some View {
        content
            // List・Form の不透明な背景を隠す（Form の行そのものは不透明のまま残るので、行の文字は今までどおり読める）
            .scrollContentBackground(.hidden)
            .background {
                SkyBackgroundView(showClouds: true) {
                    Color.clear
                }
                // 背景の飾りなので VoiceOver では読ませない
                .accessibilityHidden(true)
            }
            // 端末がダークモードでも、この表示（カバー・シート）はライトの見た目にする
            .preferredColorScheme(.light)
    }
}

extension View {
    /// そらともの画面の背景を雲つきの空にする
    func soratomoSkyBackground() -> some View {
        modifier(SoratomoSkyBackgroundModifier())
    }

    /// 空の背景の上に置く List（`.plain`）の行の背景を透明にする。
    /// `.plain` の List は行ごとに不透明な背景を持つため、これを付けないと行が白（ダークでは黒）の帯になる
    func soratomoClearRowBackground() -> some View {
        listRowBackground(Color.clear)
    }
}
