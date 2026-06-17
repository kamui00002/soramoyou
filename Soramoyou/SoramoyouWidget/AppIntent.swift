//
//  AppIntent.swift
//  SoramoyouWidget
//
//  ウィジェットの設定（長押し → 編集）で選ぶ「表示モード」。
//  - album      : Mode A 自分の空をローテーション表示
//  - currentSky : Mode B 今の時間帯に合う自分の空を表示（無ければ抽象色へフォールバック）
//  - abstract   : Mode C 太陽の位置から空色をグラデーションで描画（写真・通信不要）
//

import AppIntents
import WidgetKit

/// ウィジェットの表示モード（AppIntent の設定パラメータ）。
enum WidgetDisplayMode: String, AppEnum {
    case album
    case currentSky
    case abstract

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "表示モード")
    }

    static var caseDisplayRepresentations: [WidgetDisplayMode: DisplayRepresentation] {
        [
            .album: DisplayRepresentation(title: "アルバム", subtitle: "自分の空を順番に表示"),
            .currentSky: DisplayRepresentation(title: "今の空", subtitle: "今の時間帯に合う空を表示"),
            .abstract: DisplayRepresentation(title: "抽象色", subtitle: "太陽の位置から空色を描画")
        ]
    }
}

/// ウィジェット設定インテント。長押し→編集でモードを切り替えられる。
struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "そらもよう" }
    static var description: IntentDescription { "ホーム画面に「そらもよう」を表示します。" }

    @Parameter(title: "表示モード", default: .currentSky)
    var mode: WidgetDisplayMode
}
