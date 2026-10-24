//
//  ProfileSectionVisibilityEditor.swift ⭐️
//  Soramoyou
//
//  プロフィール編集の「プロフィールに表示するもの」の節（1.18.0・PR-B）
//  他人が自分のプロフィールを見たときに、おすすめの空・空カレンダー・お気に入りの空を見せるかを選ぶ。
//  計画書 ~/.claude/plans/profile-visibility-toggles.md の「アプリ」「(c) フォロー・入口ボタン・スイッチ」。
//

import SwiftUI

/// プロフィール編集の「プロフィールに表示するもの」の節 ⭐️
///
/// - 値は持たない。編集中の値（`ProfileViewModel.editingSectionVisibility`）を Binding で受け取る。
///   保存は編集画面の「保存」ボタンで、ほかの項目と一緒に行う（変わった欄だけ書く・ProfileViewModel 側）。
/// - 今の値を読めるまで（読み込み中・失敗）はスイッチを押せない（読めていない値で上書きしないため）。
/// - 見た目は投稿画面の「保存オプション」の節（PostInfoView）と同じ形（白い文字・ガラスの角丸・同じスイッチの色）。
///   どちらも同じ空のグラデーションの上に置くため。
struct ProfileSectionVisibilityEditor: View {
    // MARK: - Properties

    /// 編集中の見せる/見せない
    @Binding var visibility: ProfileSectionVisibility
    /// スイッチを押せるか（自分の公開プロフィールから今の値を読めたときだけ true）
    let isEditable: Bool
    /// 今の値の読み込みに失敗したか（true なら「読み込めませんでした」を出す）
    let loadFailed: Bool

    /// スイッチの色（PostInfoView の「オリジナル画像も保存する」と同じ）
    private let toggleTint = Color(red: 0.39, green: 0.58, blue: 0.93)

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プロフィールに表示するもの")
                .font(.headline)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(ProfileSection.allCases, id: \.self) { section in
                    row(for: section)
                }

                statusMessage
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.15))
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.3), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Rows

    /// 1 つの欄のスイッチと 1 行の説明
    private func row(for section: ProfileSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: binding(for: section)) {
                Text(title(for: section))
                    .foregroundColor(.white)
            }
            .toggleStyle(SwitchToggleStyle(tint: toggleTint))
            // 読み上げ（VoiceOver）では、説明の文をスイッチのヒントとして読む（説明の Text は二重に読ませない）
            .accessibilityHint(Text(description(for: section)))

            Text(description(for: section))
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
                // 長い説明は折り返して全部見せる（省略記号で切らない）
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .disabled(!isEditable)
        .opacity(isEditable ? 1 : 0.5)
    }

    /// 欄ごとのスイッチの Binding
    ///
    /// 触覚（`.selection`）はここの set で鳴らす。`onChange` で鳴らすと、読み込みで値が入ったときにも鳴ってしまう
    /// （set は人がスイッチを切り替えたときだけ呼ばれる）。
    private func binding(for section: ProfileSection) -> Binding<Bool> {
        let keyPath = Self.keyPath(for: section)
        return Binding(
            get: { visibility[keyPath: keyPath] },
            set: { newValue in
                guard visibility[keyPath: keyPath] != newValue else { return }
                visibility[keyPath: keyPath] = newValue
                Haptics.play(.selection)
            }
        )
    }

    /// 欄 → `ProfileSectionVisibility` の項目
    private static func keyPath(for section: ProfileSection) -> WritableKeyPath<ProfileSectionVisibility, Bool> {
        switch section {
        case .recommendedSkies: \.showsRecommendedSkies
        case .skyCalendar: \.showsSkyCalendar
        case .favorites: \.showsFavorites
        }
    }

    // MARK: - Texts

    /// スイッチの名前
    private func title(for section: ProfileSection) -> String {
        switch section {
        case .recommendedSkies: "おすすめの空"
        case .skyCalendar: "空カレンダー"
        case .favorites: "お気に入りの空"
        }
    }

    /// スイッチの下の 1 行の説明（下書き・利用者の承認待ち）
    ///
    /// ⚠️ 空カレンダーの「フォロワーだけ」は見せ方の制限で、壁ではない（公開の投稿は今も誰でも読める）。
    ///    「フォロワー以外には見えません」のように過剰に約束しない（計画書「firestore.rules」の 🟡）。
    private func description(for section: ProfileSection) -> String {
        switch section {
        case .recommendedSkies: "プロフィールを見た人に、選んだおすすめの空を表示します"
        case .skyCalendar: "フォロワーがあなたのプロフィールから空カレンダーを見られます"
        case .favorites: "フォロワーがあなたのプロフィールから、🔖 を付けた公開の空を見られます"
        }
    }

    /// 読み込み中・失敗のときの知らせ（読めたときは何も出さない）
    @ViewBuilder
    private var statusMessage: some View {
        if loadFailed {
            VStack(alignment: .leading, spacing: 2) {
                Label("読み込めませんでした", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                Text("編集画面を開き直すと、もう一度読み込みます")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }
            .accessibilityElement(children: .combine)
        } else if !isEditable {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("読み込んでいます")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Preview

struct ProfileSectionVisibilityEditor_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.68, green: 0.85, blue: 0.90),
                    Color(red: 0.39, green: 0.58, blue: 0.93),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                ProfileSectionVisibilityEditor(
                    visibility: .constant(.default),
                    isEditable: true,
                    loadFailed: false
                )
                ProfileSectionVisibilityEditor(
                    visibility: .constant(.default),
                    isEditable: false,
                    loadFailed: true
                )
            }
            .padding()
        }
    }
}
