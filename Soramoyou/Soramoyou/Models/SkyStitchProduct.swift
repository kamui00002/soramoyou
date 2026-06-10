// ⭐️ SkyStitchProduct.swift
// 課金プロダクトID定数
//
//  Created on 2026-06-10.
//
//  ⚠️ 温存中（未配線）: 広角合成は無料化したため現在この Product ID は使用していない。
//  将来の「AI 補正」課金で再利用する想定で PaymentService と合わせて温存。
//  プロダクトIDを1か所に集約（散在防止）。再有効化時は App Store Connect 側で同じ Product ID の
//  非消耗型(Non-Consumable) アイテムを作成する。
//

import Foundation

enum SkyStitchProduct {
    /// 広角合成の機能解放（非消耗型・1回購入で恒久解放）。
    /// Bundle ID prefix は既存アプリに合わせる: com.yoshidometoru.Soramoyou
    static let panorama = "com.yoshidometoru.Soramoyou.panorama"

    /// loadProducts で取得する全プロダクトID。
    static let allProductIDs: Set<String> = [panorama]
}
