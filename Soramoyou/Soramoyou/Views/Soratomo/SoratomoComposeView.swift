//
//  SoratomoComposeView.swift
//  Soramoyou
//
//  ⭐️ 仮の行き先（tasks 13.1 で置いた骨組み）。中身は 13.7・13.8 の担当（b4）が作る。
//  ⚠️ init のシグネチャは変えない（呼び出し側の SoratomoRootView などを、担当は触らないため）。
//     足したいものがあれば、変えずに「共有ファイルへの追加依頼」として報告する。
//

import SwiftUI

/// 投稿画面（写真の選択・プレビュー・キャプション・送信）
///
/// タイムライン（13.5）がシートで出す。投稿先は `groupId` の 1 つだけ。
/// 投稿が完了したら `onFinished(true)`、送らずに閉じたら `onFinished(false)` を呼ぶ
/// （新しい投稿はタイムラインの監視で先頭に届く）。
struct SoratomoComposeView: View {
    /// 投稿先のグループの ID
    let groupId: String
    /// サービスの容れ物
    let dependencies: SoratomoDependencies
    /// 閉じるときに呼ぶ（投稿が完了したら true）
    let onFinished: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Text("準備中")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { onFinished(false) }
                    }
                }
        }
    }
}
