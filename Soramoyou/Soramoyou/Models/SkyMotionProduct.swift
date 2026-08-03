// ⭐️ SkyMotionProduct.swift
// 「空を動かす」回数パック（消費型IAP）のプロダクトID定数
//
//  設計: docs/sky-motion-billing-plan.md
//
//  ⚠️ ここの ID / クレジット数は **3か所で一致させること**:
//     1. App Store Connect の App内課金アイテム（種別=消費型 Consumable）
//     2. `Soramoyou.storekit`（ローカル / サンドボックステスト用）
//     3. Cloud Functions の `skyMotionCore.PACK_CREDITS`（**付与数の真実源はこちら**）
//
//  ⚠️ クライアントのクレジット数は「表示用」に過ぎない。実際に何回ぶん付与されるかは
//     サーバーが検証済みJWSの productId から決める（client申告を信じると
//     「pack5を買ってpack100と自己申告」が通ってしまうため）。
//

import Foundation

enum SkyMotionProduct {
    /// 5回パック（消費型）。1回の生成につき残高を1消費する。
    static let pack5 = "com.yoshidometoru.Soramoyou.skymotion.pack5"

    /// `Product.products(for:)` で取得する全プロダクトID。
    static let allProductIDs: Set<String> = [pack5]

    /// 表示用のクレジット数（サーバーの `PACK_CREDITS` と一致させること）。
    /// 実際の付与数はサーバーが決めるので、ここはUI文言のためだけに使う。
    static func displayCredits(for productID: String) -> Int? {
        switch productID {
        case pack5: 5
        default: nil
        }
    }
}
