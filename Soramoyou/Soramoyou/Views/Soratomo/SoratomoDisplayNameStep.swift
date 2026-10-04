//
//  SoratomoDisplayNameStep.swift
//  Soramoyou
//
//  そらともの表示名の事前入力 ⭐️
//  （tasks 13.2・design.md の SoratomoDisplayNameStep・要件 18.1〜18.5・18.7）
//
//  「グループを作る」「招待コードで参加」のシート（SoratomoGroupFormView）の中で、表示名が未設定か
//  空白だけのときに、グループ名や招待コードより先に出す。
//  保存・検査・計測は SoratomoGroupFormViewModel が行い、この画面は入力と表示だけを持つ。
//

import SwiftUI

/// 表示名の入力の段
///
/// - 入力は呼び出し側（ViewModel）が持つ。失敗しても消えないのは、ViewModel が入力を消さないため（要件 18.5）
/// - 文字数の条件（1〜20 文字）は、失敗したときだけでなく、いつも下に出しておく（要件 18.2）
/// - ここで保存した表示名は、既存のプロフィールの表示名になる（そらとも専用の名前ではない・要件 18.7）
struct SoratomoDisplayNameStep: View {
    // MARK: - Properties

    /// 表示名の入力
    @Binding var displayName: String
    /// 出す失敗の文言（固定の文言。無ければ nil）
    let errorMessage: String?
    /// 保存している間は true（確定のボタンを無効にする）
    let isSaving: Bool
    /// 確定したとき（保存は呼び出し側が行う）
    let onSave: () -> Void

    /// 入力欄にフォーカスがあるか
    @FocusState private var isFocused: Bool

    // MARK: - Body

    var body: some View {
        Form {
            Section {
                TextField("表示名", text: $displayName)
                    .textContentType(.nickname)
                    .submitLabel(.done)
                    .focused($isFocused)
                    .disabled(isSaving)
                    .onSubmit(onSave)
                    .accessibilityLabel("表示名")
                    .accessibilityHint("グループの友達に表示される名前を入力します")
            } header: {
                Text("あなたの表示名")
            } footer: {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    Text("グループのタイムラインと通知で、友達にこの名前が表示されます。プロフィールの表示名として保存します。")
                    // 文字数の条件はいつも出す（`SoratomoTextRules.displayNameMax` と一致させる）
                    Text("1〜\(SoratomoTextRules.displayNameMax)文字で入力してください")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .accessibilityLabel(errorMessage)
                }
            }

            Section {
                Button(action: onSave) {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("保存して次へ")
                                .font(.headline)
                        }
                        Spacer()
                    }
                    .frame(minHeight: 44)
                }
                .disabled(isSaving)
                .accessibilityLabel(isSaving ? "表示名を保存しています" : "表示名を保存して次へ進む")
            }
        }
        .onAppear {
            isFocused = true
        }
    }
}
