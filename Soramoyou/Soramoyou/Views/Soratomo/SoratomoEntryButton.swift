//
//  SoratomoEntryButton.swift
//  Soramoyou
//
//  ホームのツールバーの右に出す「そらとも」の入口のボタン ⭐️
//  （tasks 14.1・design.md の SoratomoEntryButton・要件 1.1・1.2・1.4・1.5）
//
//  - そらともを使えるかの判定（SoratomoFeatureGate）が「有効」＝登録済みのアカウントでログインしている
//    ときだけボタンを出す（1.15.0 の一般公開から。1.14.x まではクレームで判定していた）。
//    ゲスト中・匿名アカウント・未ログイン・判定前（unknown）は何も描かない
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

    /// そらともを使えるかの判定（アプリ全体で 1 つ）
    @EnvironmentObject private var soratomoGate: SoratomoFeatureGate

    /// ボタンの絵（そらともの空の地球）のアセット名（Assets.xcassets の SoratomoGroupIcon.imageset）
    ///
    /// 最低 iOS 16 なので、アセットから自動で作られる名前付きの参照（生成シンボル `Image(.xxx)`。iOS 17〜）が使えない。
    /// そのため文字列で引く。名前を打ち間違えてもビルドは通ってしまうので、
    /// 打ち間違いは HomeToolbarImageAssetTests で拾う
    static let iconAssetName = "SoratomoGroupIcon"

    // MARK: - Body

    var body: some View {
        // ⚠️ `isEnabled` は判定が `.enabled` のときだけ true。
        //    判定前（unknown）・無効（未ログイン・匿名）では、
        //    ボタンそのものを作らない（使えない利用者には、既存のホームと同じ見た目のまま）
        if soratomoGate.isEnabled {
            Button {
                // 全画面の表示はルーターに任せる（MainTabView の fullScreenCover が isPresented を見ている）。
                // 計測の `soratomo_opened` は、開いた一覧の画面が記録するので、ここでは記録しない
                SoratomoRouter.shared.openFromEntry()
            } label: {
                // ⭐️ PR-H: 記号（person.2.circle）から、そらともの絵（空の地球）に替えた（利用者の決定 2026-10-24）
                Image(Self.iconAssetName)
                    // ツールバーの中の画像は、何もしないと単色（テンプレート）に塗られることがあるので元の色で描く
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
            }
            // VoiceOver では「そらとも」と読み上げ、押すと何が起きるかを補足する
            .accessibilityLabel("そらとも")
            .accessibilityHint("友達のグループで共有している空を開きます")
        }
    }
}
