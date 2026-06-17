//
//  WidgetGuideView.swift ☀️
//  Soramoyou
//
//  ホーム画面ウィジェットの「追加のしかた」と「3つの表示モード」を案内する専用ガイド。
//  設定 ＞ サポート から開く（新規・既存どちらのユーザーもいつでも見られる）。
//  ウィジェットは追加手順が分かりにくいため、手順を番号つきで明示する。
//

import SwiftUI

/// ウィジェット追加ガイド（設定から開くシート）。
struct WidgetGuideView: View {
    @Environment(\.dismiss) private var dismiss

    /// 追加手順（番号・アイコン・説明）。
    private let steps: [(number: Int, icon: String, text: String)] = [
        (1, "hand.tap.fill", "ホーム画面の何もない場所を長押しします（アイコンが揺れます）"),
        (2, "plus.circle.fill", "画面左上に出る「＋」をタップします"),
        (3, "magnifyingglass", "検索に「そらもよう」と入力して選びます"),
        (4, "square.grid.2x2.fill", "好きなサイズ（小・中・大）を選び「ウィジェットを追加」"),
        (5, "slider.horizontal.3", "追加したウィジェットを長押し →「ウィジェットを編集」で表示モードを選べます")
    ]

    /// 3つの表示モード（アイコン・名前・説明）。
    private let modes: [(icon: String, title: String, desc: String)] = [
        ("photo.stack.fill", "アルバム", "集めた空を順番に表示します"),
        ("sun.max.fill", "今の空", "今の時間帯に近い空を表示します"),
        ("sparkles", "抽象色", "時間帯ごとの美しいグラデを表示します")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    stepsSection
                    modesSection
                    hint
                }
                .padding()
            }
            .navigationTitle("ウィジェットの追加方法")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    // MARK: - ヘッダー（空グラデの帯）

    private var header: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.42, green: 0.68, blue: 0.93),
                        Color(red: 0.99, green: 0.72, blue: 0.45)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 96)
            .overlay(
                HStack(spacing: 16) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.white)
                    Text("集めた空を\nホーム画面に飾ろう")
                        .font(.headline)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
            )
    }

    // MARK: - 追加の手順

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("追加の手順")
                .font(.headline)
            ForEach(steps, id: \.number) { step in
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 34, height: 34)
                        Text("\(step.number)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                    Text(step.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - 3つの表示モード

    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("3つの表示モード")
                .font(.headline)
            ForEach(modes, id: \.title) { mode in
                HStack(spacing: 14) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text(mode.desc)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - ヒント

    private var hint: some View {
        Text("ヒント: 朝・昼・夕・夜の空を投稿していくと、「今の空」が時間帯に合わせて変わります。")
            .font(.footnote)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    WidgetGuideView()
}
