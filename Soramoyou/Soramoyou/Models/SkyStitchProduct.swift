// ⭐️ SkyStitchProduct.swift
// 広角合成(v2)の課金プロダクトID定数
//
//  Created on 2026-06-10.
//
//  プロダクトIDを1か所に集約（散在防止）。App Store Connect 側で同じ Product ID の
//  非消耗型(Non-Consumable) アイテムを作成する必要がある（ユーザー作業）。
//

import Foundation

enum SkyStitchProduct {
    /// 広角合成の機能解放（非消耗型・1回購入で恒久解放）。
    /// Bundle ID prefix は既存アプリに合わせる: com.yoshidometoru.Soramoyou
    static let panorama = "com.yoshidometoru.Soramoyou.panorama"

    /// loadProducts で取得する全プロダクトID。
    static let allProductIDs: Set<String> = [panorama]
}
