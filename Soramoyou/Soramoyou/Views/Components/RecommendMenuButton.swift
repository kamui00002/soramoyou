//
//  RecommendMenuButton.swift ⭐️
//  Soramoyou
//
//  投稿詳細の「…」メニューに置く「おすすめの空に追加 / から外す」ボタンと、
//  その結果を伝えるアラート。
//
//  メニューはタップで即閉じるため、結果（追加した・3枚までです 等）はアラートで伝える。
//  公開投稿だけが対象（おすすめの空は他の人にも見えるため）。公開以外ではボタン自体を出さない。
//

import SwiftUI

struct RecommendMenuButton: View {
    let post: Post
    /// 計装用の発生源（"post_detail" / "gallery_detail"）
    let source: String
    /// 結果を受け取る（呼び出し側でアラートを出す）
    let onOutcome: (RecommendationManager.Outcome) -> Void

    @ObservedObject private var manager = RecommendationManager.shared

    init(post: Post, source: String, onOutcome: @escaping (RecommendationManager.Outcome) -> Void) {
        self.post = post
        self.source = source
        self.onOutcome = onOutcome
    }

    var body: some View {
        if post.visibility == .public {
            Button {
                Task {
                    let outcome = await manager.toggle(post: post, source: source)
                    onOutcome(outcome)
                }
            } label: {
                if manager.isRecommended(post.id) {
                    Label("おすすめの空から外す", systemImage: "star.slash")
                } else {
                    Label("おすすめの空に追加", systemImage: "star")
                }
            }
            .disabled(manager.isUpdating)
        }
    }
}

// MARK: - 結果アラート

extension RecommendationManager.Outcome {
    /// アラートの見出し
    var alertTitle: String {
        switch self {
        case .added: return "おすすめの空に追加しました"
        case .alreadyAdded: return "すでにおすすめの空に入っています"
        case .full: return "おすすめの空は\(RecommendedSkies.maxCount)枚までです"
        case .removed: return "おすすめの空から外しました"
        case .notPublic: return "公開中の空だけをおすすめにできます"
        case .requiresLogin: return "ログインが必要です"
        case .failed: return "保存できませんでした"
        }
    }

    /// アラートの本文
    var alertMessage: String {
        switch self {
        case .added: return "プロフィールの「私のおすすめの空」に表示されます。"
        case .alreadyAdded: return "プロフィールの「私のおすすめの空」で確認できます。"
        case .full: return "プロフィールの「私のおすすめの空」で外してから追加してください。"
        case .removed: return "プロフィールの「私のおすすめの空」から外れました。"
        case .notPublic: return "おすすめの空はあなたのプロフィールを見た人にも表示されるため、公開中の投稿から選んでください。"
        case .requiresLogin: return "ログインすると、おすすめの空を選べます。"
        case .failed: return "通信環境を確認して、もう一度お試しください。"
        }
    }
}

private struct RecommendationOutcomeAlert: ViewModifier {
    @Binding var outcome: RecommendationManager.Outcome?

    func body(content: Content) -> some View {
        content.alert(
            outcome?.alertTitle ?? "",
            isPresented: Binding(
                get: { outcome != nil },
                set: { isPresented in
                    if !isPresented {
                        outcome = nil
                    }
                }
            )
        ) {
            Button("OK") { outcome = nil }
        } message: {
            Text(outcome?.alertMessage ?? "")
        }
    }
}

extension View {
    /// おすすめの空の追加 / 外すの結果をアラートで伝える
    func recommendationOutcomeAlert(_ outcome: Binding<RecommendationManager.Outcome?>) -> some View {
        modifier(RecommendationOutcomeAlert(outcome: outcome))
    }
}
