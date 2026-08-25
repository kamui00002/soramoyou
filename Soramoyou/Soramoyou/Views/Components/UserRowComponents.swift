//
//  UserRowComponents.swift
//  Soramoyou
//
//  「ユーザーが縦に並ぶ一覧」で共有する行パーツ ⭐️
//
//  フォロー一覧（FollowListView）と反応してくれた人一覧（ReactedUsersView）は
//  見た目がほぼ同じ行を持つ。最初は各画面に private コピーを置いていたが、
//  アバターのプレースホルダだけ font/opacity がズレる（＝同じ画面のはずなのに
//  人型アイコンの濃さが違う）事故が起きたため、ここへ集約した。
//
//  ⚠️ ここは「見た目だけ」を持つ純粋な表示部品にする。
//     フォロー状態の判定や文言の出し分けは ViewModel 側の責務
//     （View の private に置くとテストで固定できない。PR #97 D1 の教訓）。
//

import SwiftUI

// MARK: - Avatar

/// ユーザーのアバター（URL が無い / 読み込み失敗はプレースホルダ）
struct UserAvatarView: View {
    /// プロフィール画像の URL 文字列（未設定なら nil）
    let photoURL: String?
    /// 直径（既定 44pt = 一覧行の標準サイズ）
    var size: CGFloat = 44

    var body: some View {
        if let urlString = photoURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    // 読み込み中・失敗はプレースホルダに落とす（レイアウトを動かさない）
                    placeholder
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
        } else {
            placeholder
        }
    }

    /// 画像が無いときの人型プレースホルダ
    private var placeholder: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "person.fill")
                    // サイズに追従させる（44pt のとき 18pt ＝ 従来の見た目）
                    .font(.system(size: size * 18 / 44))
                    .foregroundColor(.white.opacity(0.7))
            )
    }
}

// MARK: - Follow Button

/// フォロー / フォローバック / フォロー中 を切り替えるボタン ⭐️
///
/// 状態と文言は呼び出し側（ViewModel）が決めて渡す。
/// この部品は「渡された状態をどう描くか」だけを知っている。
struct FollowActionButton: View {
    /// ボタンの文言（「フォロー」「フォローバック」「フォロー中」）
    let title: String
    /// 既にフォローしているか（見た目とアクセシビリティの出し分けに使う）
    let isFollowing: Bool
    /// 通信中か（二重タップ防止と半透明表示）
    let isToggling: Bool
    /// VoiceOver 用の相手の表示名
    let displayName: String
    /// タップ時の処理
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                // ⚠️ 未フォロー時は白い背景の上に載るため、文字は必ず暗い色にする。
                //    DesignTokens.Colors.textPrimary は Color.white なのでここでは使えない
                //    （白背景×白文字で読めなくなる。実データ検証で発覚）。
                .foregroundColor(
                    isFollowing
                        ? .white.opacity(0.85)
                        : Color(red: 0.20, green: 0.28, blue: 0.45)
                )
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.xs)
                .background(
                    Capsule().fill(
                        isFollowing
                            // フォロー中は控えめ（解除が主目的ではないので目立たせない）
                            ? AnyShapeStyle(.ultraThinMaterial)
                            // 未フォローは行動を促す色
                            : AnyShapeStyle(Color.white.opacity(0.9))
                    )
                )
                .overlay(
                    Capsule().stroke(.white.opacity(isFollowing ? 0.3 : 0), lineWidth: 1)
                )
                // 処理中は押せないことが見た目でも分かるようにする
                .opacity(isToggling ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isToggling)
        // 名前が無いと VoiceOver で同じ読み上げのボタンが並び、どの行か分からなくなる
        .accessibilityLabel("\(displayName) を\(isFollowing ? "フォロー解除" : "フォロー")")
        .accessibilityAddTraits(isFollowing ? .isSelected : [])
    }
}
