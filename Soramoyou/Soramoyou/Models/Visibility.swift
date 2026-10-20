//
//  Visibility.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation

/// 投稿の公開設定
enum Visibility: String, Codable, CaseIterable {
    case `public`
    case followers
    case `private`

    /// 表示名
    var displayName: String {
        switch self {
        case .public: "公開"
        case .followers: "フォロワーのみ"
        case .private: "非公開"
        }
    }

    /// 投稿情報画面の「公開設定」の下に出す説明文（出さないときは nil）⭐️（C 項目 4）
    /// - フォロワー限定の投稿を誰が見られるかを書く。文は 10/19 ユーザー承認
    /// - アプリの画面で表示される相手のことだけを書き、「完全に見えなくなる」のような言い切りはしない
    ///   （ブロックより前に手に入れた画像の URL は、URL をやめる直しまで残るため）
    /// - displayName は全画面に出るので変えず、説明はこちらに分ける
    var selectionNote: String? {
        switch self {
        case .followers: "あなたをフォローしている人に表示されます。フォローは誰でもできます。あなたがブロックした人には表示されません"
        case .public, .private: nil
        }
    }
}
