//
//  SettingsView.swift ☀️
//  Soramoyou
//
//  App Store申請に必要な設定画面
//  プライバシーポリシー、利用規約、アプリ情報を表示
//

import SwiftUI
import StoreKit

/// アプリの設定画面
/// プライバシーポリシー、利用規約、アプリ情報を表示する
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var showingPrivacyPolicy = false
    @State private var showingTermsOfService = false
    @State private var showingLogoutConfirmation = false

    /// アプリのバージョン情報を取得
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "バージョン \(version) (\(build))"
    }

    var body: some View {
        NavigationView {
            ZStack {
                // 背景グラデーション
                LinearGradient(
                    colors: DesignTokens.Colors.daySkyGradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: DesignTokens.Spacing.lg) {
                        // アプリ情報セクション
                        appInfoSection

                        // 法的情報セクション
                        legalSection

                        // サポートセクション
                        supportSection

                        // アカウントセクション
                        accountSection

                        // バージョン情報
                        versionSection
                    }
                    .padding()
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .sheet(isPresented: $showingPrivacyPolicy) {
                PrivacyPolicyView()
            }
            .sheet(isPresented: $showingTermsOfService) {
                TermsOfServiceView()
            }
            .alert("ログアウト", isPresented: $showingLogoutConfirmation) {
                Button("キャンセル", role: .cancel) { }
                Button("ログアウト", role: .destructive) {
                    Task {
                        do {
                            try await authViewModel.signOut()
                            await MainActor.run {
                                dismiss()
                            }
                        } catch {
                            // エラー時は何もしない（AuthViewModelでハンドリング）
                        }
                    }
                }
            } message: {
                Text("本当にログアウトしますか？")
            }
        }
    }

    // MARK: - App Info Section ☀️

    /// アプリ情報セクション
    private var appInfoSection: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            // アプリアイコンと名前
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "cloud.sun.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: DesignTokens.Colors.skyBlue.opacity(0.5), radius: 10)

                Text("そらもよう")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(DesignTokens.Colors.textPrimary)

                Text("空を撮る、空を集める")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
            .padding(.vertical, DesignTokens.Spacing.lg)
        }
    }

    // MARK: - Legal Section ☀️

    /// 法的情報セクション
    private var legalSection: some View {
        VStack(spacing: 0) {
            sectionHeader(title: "法的情報", icon: "doc.text")

            settingsCard {
                // プライバシーポリシー
                SettingsRow(
                    title: "プライバシーポリシー",
                    icon: "hand.raised.fill",
                    iconColor: .blue
                ) {
                    showingPrivacyPolicy = true
                }

                Divider()
                    .padding(.leading, 44)

                // 利用規約
                SettingsRow(
                    title: "利用規約",
                    icon: "doc.plaintext.fill",
                    iconColor: .green
                ) {
                    showingTermsOfService = true
                }
            }
        }
    }

    // MARK: - Support Section ☀️

    /// サポートセクション
    private var supportSection: some View {
        VStack(spacing: 0) {
            sectionHeader(title: "サポート", icon: "questionmark.circle")

            settingsCard {
                // お問い合わせ
                SettingsRow(
                    title: "お問い合わせ",
                    icon: "envelope.fill",
                    iconColor: .orange
                ) {
                    openMailApp()
                }

                Divider()
                    .padding(.leading, 44)

                // レビューをお願いする
                SettingsRow(
                    title: "アプリを評価する",
                    icon: "star.fill",
                    iconColor: .yellow
                ) {
                    requestReview()
                }
            }
        }
    }

    // MARK: - Account Section ☀️

    /// アカウントセクション
    private var accountSection: some View {
        VStack(spacing: 0) {
            sectionHeader(title: "アカウント", icon: "person.circle")

            settingsCard {
                // ログアウト
                SettingsRow(
                    title: "ログアウト",
                    icon: "rectangle.portrait.and.arrow.right",
                    iconColor: .red,
                    showChevron: false
                ) {
                    showingLogoutConfirmation = true
                }
            }
        }
    }

    // MARK: - Version Section ☀️

    /// バージョン情報セクション
    private var versionSection: some View {
        Text(appVersion)
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundColor(DesignTokens.Colors.textTertiary)
            .padding(.top, DesignTokens.Spacing.lg)
    }

    // MARK: - Helper Views ☀️

    /// セクションヘッダー
    private func sectionHeader(title: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(DesignTokens.Colors.textSecondary)

            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textSecondary)

            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    /// 設定カード
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                    .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
            }
        )
    }

    // MARK: - Actions ☀️

    /// メールアプリを開く
    private func openMailApp() {
        let email = "soramoyou.app@gmail.com"
        let subject = "そらもようアプリへのお問い合わせ"
        let body = """

        ---
        アプリ情報
        \(appVersion)
        iOS \(UIDevice.current.systemVersion)
        \(UIDevice.current.model)
        """

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        if let url = URL(string: "mailto:\(email)?subject=\(encodedSubject)&body=\(encodedBody)") {
            UIApplication.shared.open(url)
        }
    }

    /// App Storeレビューをリクエスト
    private func requestReview() {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        }
    }
}

// MARK: - Settings Row ☀️

/// 設定項目の行
struct SettingsRow: View {
    let title: String
    let icon: String
    var iconColor: Color = .blue
    var showChevron: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            action()
        }) {
            HStack(spacing: DesignTokens.Spacing.md) {
                // アイコン
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(iconColor)
                    .frame(width: 28, height: 28)

                // タイトル
                Text(title)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundColor(DesignTokens.Colors.textPrimary)

                Spacer()

                // 矢印
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DesignTokens.Colors.textTertiary)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Privacy Policy View ☀️

/// プライバシーポリシー表示画面
struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: DesignTokens.Colors.daySkyGradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                        Text(privacyPolicyText)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(DesignTokens.Colors.textPrimary)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                                    .fill(.ultraThinMaterial)
                            )
                    }
                    .padding()
                }
            }
            .navigationTitle("プライバシーポリシー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }

    /// プライバシーポリシーの本文
    private var privacyPolicyText: String {
        """
        プライバシーポリシー

        最終更新日: 2025年2月2日

        「そらもよう」（以下、「本アプリ」）は、ユーザーのプライバシーを尊重し、個人情報の保護に努めています。本プライバシーポリシーは、本アプリが収集する情報とその利用方法について説明します。

        ■ 収集する情報

        1. アカウント情報
        - メールアドレス
        - 表示名
        - プロフィール画像

        2. 投稿コンテンツ
        - 写真
        - キャプション
        - ハッシュタグ

        3. 位置情報
        - 投稿に付加する位置情報（市区町村レベル）
        - 位置情報の使用はユーザーの許可が必要です

        4. 写真のメタデータ
        - 撮影日時（EXIF情報）
        - カメラ情報

        5. 利用状況データ
        - アプリの使用状況
        - デバイス情報

        ■ 情報の利用目的

        収集した情報は以下の目的で利用します：
        - アカウントの作成と管理
        - 投稿の保存と表示
        - アプリの機能改善
        - ユーザーサポートの提供
        - 広告の表示（Google AdMob）

        ■ 第三者へのデータ提供

        本アプリは以下のサービスを利用しています：

        1. Firebase（Google）
        - 認証、データベース、ストレージに使用
        - プライバシーポリシー: https://firebase.google.com/support/privacy

        2. Google AdMob
        - 広告配信に使用
        - プライバシーポリシー: https://policies.google.com/privacy

        ■ データの保護

        ユーザーのデータは、Firebase のセキュリティ機能により保護されています。
        - データの暗号化
        - アクセス制御
        - セキュリティルールの適用

        ■ ユーザーの権利

        ユーザーは以下の権利を有します：
        - アカウント情報の閲覧・編集
        - 投稿の削除
        - アカウントの削除（お問い合わせください）

        ■ お問い合わせ

        プライバシーに関するお問い合わせは、アプリ内の「設定」→「お問い合わせ」よりご連絡ください。

        ■ ポリシーの変更

        本ポリシーは予告なく変更されることがあります。重要な変更がある場合は、アプリ内で通知します。
        """
    }
}

// MARK: - Terms of Service View ☀️

/// 利用規約表示画面
struct TermsOfServiceView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: DesignTokens.Colors.daySkyGradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                        Text(termsOfServiceText)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(DesignTokens.Colors.textPrimary)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                                    .fill(.ultraThinMaterial)
                            )
                    }
                    .padding()
                }
            }
            .navigationTitle("利用規約")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }

    /// 利用規約の本文
    private var termsOfServiceText: String {
        """
        利用規約

        最終更新日: 2025年2月2日

        本利用規約（以下、「本規約」）は、「そらもよう」（以下、「本アプリ」）の利用条件を定めるものです。ユーザーの皆様には、本規約に同意いただいた上で、本アプリをご利用いただきます。

        ■ 第1条（適用）

        本規約は、ユーザーと本アプリの運営者との間の本アプリの利用に関わる一切の関係に適用されます。

        ■ 第2条（利用登録）

        1. 登録希望者が本規約に同意の上、所定の方法により利用登録を申請し、運営者がこれを承認することによって、利用登録が完了するものとします。

        2. 運営者は、以下の場合には利用登録の申請を承認しないことがあります：
        - 虚偽の事項を届け出た場合
        - 本規約に違反したことがある者からの申請である場合
        - その他、運営者が利用登録を相当でないと判断した場合

        ■ 第3条（禁止事項）

        ユーザーは、本アプリの利用にあたり、以下の行為をしてはなりません：

        1. 法令または公序良俗に違反する行為
        2. 犯罪行為に関連する行為
        3. 運営者、他のユーザー、または第三者の知的財産権を侵害する行為
        4. 他のユーザーに対する誹謗中傷、嫌がらせ行為
        5. わいせつな表現を含むコンテンツの投稿
        6. 虚偽の情報を投稿する行為
        7. 本アプリの運営を妨害する行為
        8. 不正アクセス、または不正アクセスを試みる行為
        9. 他のユーザーに成りすます行為
        10. 反社会的勢力等への利益供与
        11. その他、運営者が不適切と判断する行為

        ■ 第4条（コンテンツの権利）

        1. ユーザーが投稿したコンテンツの著作権は、ユーザーに帰属します。

        2. ユーザーは、投稿したコンテンツについて、運営者に対し、本アプリの運営に必要な範囲で利用することを許諾するものとします。

        3. 運営者は、本規約に違反するコンテンツを削除する権利を有します。

        ■ 第5条（利用停止等）

        運営者は、ユーザーが本規約に違反した場合、または以下の事由に該当する場合、事前の通知なく、当該ユーザーに対して本アプリの利用を制限、または登録を抹消することができるものとします：

        1. 本規約のいずれかの条項に違反した場合
        2. 登録事項に虚偽の事実があることが判明した場合
        3. その他、運営者が本アプリの利用を適当でないと判断した場合

        ■ 第6条（免責事項）

        1. 運営者は、本アプリに事実上または法律上の瑕疵がないことを明示的にも黙示的にも保証しません。

        2. 運営者は、本アプリに起因してユーザーに生じたあらゆる損害について、一切の責任を負いません。

        3. 運営者は、ユーザー間の紛争について、一切関与しません。

        ■ 第7条（サービス内容の変更等）

        運営者は、ユーザーに通知することなく、本アプリの内容を変更、または提供を中止することができるものとします。

        ■ 第8条（利用規約の変更）

        運営者は、必要と判断した場合には、ユーザーに通知することなく本規約を変更することができるものとします。変更後の利用規約は、本アプリ内に掲示した時点から効力を生じるものとします。

        ■ 第9条（準拠法・管轄裁判所）

        本規約の解釈にあたっては、日本法を準拠法とします。本アプリに関して紛争が生じた場合には、東京地方裁判所を第一審の専属的合意管轄裁判所とします。

        以上
        """
    }
}

// MARK: - Preview ☀️

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AuthViewModel())
    }
}
