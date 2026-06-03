//
//  JapanPrefecture.swift
//  Soramoyou
//
//  空コレクション図鑑（柱2）の都道府県軸。
//  `Location.prefecture`（逆ジオコードの administrativeArea = 公式名）と照合する。
//

import Foundation

/// 日本の都道府県（図鑑の収集軸の1つ）
///
/// `Location.prefecture` は「東京都」「北海道」「大阪府」等の公式名で入る想定。
/// 47都道府県の正準リストと照合し、非該当（海外・取得失敗）は集計対象外とする。
struct JapanPrefecture: Hashable, Codable {
    /// 公式名（例: "東京都"）
    let name: String

    /// 47都道府県の公式名（北→南の順）
    static let allNames: [String] = [
        "北海道",
        "青森県", "岩手県", "宮城県", "秋田県", "山形県", "福島県",
        "茨城県", "栃木県", "群馬県", "埼玉県", "千葉県", "東京都", "神奈川県",
        "新潟県", "富山県", "石川県", "福井県", "山梨県", "長野県",
        "岐阜県", "静岡県", "愛知県", "三重県",
        "滋賀県", "京都府", "大阪府", "兵庫県", "奈良県", "和歌山県",
        "鳥取県", "島根県", "岡山県", "広島県", "山口県",
        "徳島県", "香川県", "愛媛県", "高知県",
        "福岡県", "佐賀県", "長崎県", "熊本県", "大分県", "宮崎県", "鹿児島県",
        "沖縄県"
    ]

    /// `Location.prefecture` の文字列から該当する都道府県を返す。
    /// - 公式名と完全一致した場合のみ採用（海外・不明・部分不一致は nil）。
    static func from(name: String?) -> JapanPrefecture? {
        guard let name = name, allNames.contains(name) else { return nil }
        return JapanPrefecture(name: name)
    }
}
