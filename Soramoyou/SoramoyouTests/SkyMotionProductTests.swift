//
//  SkyMotionProductTests.swift
//  SoramoyouTests
//
//  ⭐️「空を動かす」回数パック（消費型IAP）のプロダクト定義のテスト。
//
//  ここで守りたいのは「3か所の食い違い」。プロダクトIDは
//    ① App Store Connect のアイテム
//    ② Soramoyou.storekit
//    ③ Cloud Functions の skyMotionCore.PACK_CREDITS
//  と一致していないと、購入できても**サーバーが unknown_product で弾いてクレジットが増えない**。
//  ①②はコードから参照できないので、せめて定数の形を固定してタイポを止める。
//

@testable import Soramoyou
import XCTest

final class SkyMotionProductTests: XCTestCase {
    /// サーバーの `PACK_CREDITS` のキーと**文字ごとに同一**であること。
    /// 1文字違うだけで購入は成功するのにクレジットが付かない（ユーザーは金だけ払う）。
    func test_pack5ProductID_matchesServerContract() {
        XCTAssertEqual(
            SkyMotionProduct.pack5,
            "com.yoshidometoru.Soramoyou.skymotion.pack5",
            "サーバー skyMotionCore.PACK_CREDITS のキーと一致させること"
        )
    }

    /// Bundle ID 配下の命名になっていること（ASC はこの前提でしかIDを受け付けない）。
    func test_productIDs_areUnderBundleIdentifier() {
        for id in SkyMotionProduct.allProductIDs {
            XCTAssertTrue(
                id.hasPrefix("com.yoshidometoru.Soramoyou."),
                "\(id) がBundle ID配下になっていない"
            )
        }
    }

    /// 表示用クレジット数がサーバーの付与数（5）と一致していること。
    /// ⚠️ 実際の付与数はサーバーが決めるので、ここがズレると「5回と書いてあるのに3回しか増えない」
    ///    のような表示の嘘になる。
    func test_displayCredits_matchesServerPackSize() {
        XCTAssertEqual(SkyMotionProduct.displayCredits(for: SkyMotionProduct.pack5), 5)
    }

    /// 未知のプロダクトIDには nil を返す（勝手な既定値を返して表示を捏造しない）。
    func test_displayCredits_unknownProduct_returnsNil() {
        XCTAssertNil(SkyMotionProduct.displayCredits(for: "com.example.unknown"))
    }

    /// 回数パックと、温存中の非消耗型（広角合成）が混ざっていないこと。
    /// 混ざると `SkyMotionCreditService` が非消耗型まで消費型フローで処理してしまう。
    func test_allProductIDs_doesNotContainNonConsumable() {
        XCTAssertFalse(
            SkyMotionProduct.allProductIDs.contains(SkyStitchProduct.panorama),
            "非消耗型は消費型の購入フローに乗せてはいけない"
        )
    }
}
