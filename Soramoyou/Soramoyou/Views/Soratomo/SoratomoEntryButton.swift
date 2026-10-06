//
//  SoratomoEntryButton.swift
//  Soramoyou
//
//  ホームのツールバーの右に出す「そらとも」の入口のボタン ⭐️
//  （tasks 14.1・design.md の SoratomoEntryButton・要件 1.1・1.2・1.4・1.5）
//
//  - 機能フラグの判定（SoratomoFeatureGate）が「有効」のときだけボタンを出す。
//    ゲスト中・匿名アカウント・フラグ OFF・判定前（unknown）は何も描かない
//  - 押したら、ルーターがそらともの画面（グループ一覧）を全画面で開く。
//    全画面のカバーは MainTabView が持っているので、ここでは開くことをルーターへ頼むだけ
//

import SwiftUI

/// ホームのツールバーの右に置く「そらとも」の入口
///
/// HomeView の `.toolbar` の中で `ToolbarItem(placement: .navigationBarTrailing)` に入れて使う。
/// 判定は環境オブジェクトの `SoratomoFeatureGate` を読む（SoramoyouApp で注入済み。
/// ゲスト中の GuestTabView も同じ HomeView を使うので、同じオブジェクトを読む）。
struct SoratomoEntryButton: View {
    // MARK: - Properties

    /// そらともの機能フラグの判定（アプリ全体で 1 つ）
    @EnvironmentObject private var soratomoGate: SoratomoFeatureGate

    // MARK: - Body

    var body: some View {
        // ⚠️ `isEnabled` は判定が `.enabled` のときだけ true。
        //    判定前（unknown）・無効（未ログイン・匿名・クレーム無し・トークン取得失敗）では、
        //    ボタンそのものを作らない（フラグ OFF の利用者には、既存のホームと同じ見た目のまま）
        if soratomoGate.isEnabled {
            Button {
                // 全画面の表示はルーターに任せる（MainTabView の fullScreenCover が isPresented を見ている）。
                // 計測の `soratomo_opened` は、開いた一覧の画面が記録するので、ここでは記録しない
                SoratomoRouter.shared.openFromEntry()
            } label: {
                Image(systemName: "person.2.circle")
                    .font(.system(size: 20, weight: .regular))
            }
            // VoiceOver では「そらとも」と読み上げ、押すと何が起きるかを補足する
            .accessibilityLabel("そらとも")
            .accessibilityHint("友達のグループで共有している空を開きます")
        }
    }
}
