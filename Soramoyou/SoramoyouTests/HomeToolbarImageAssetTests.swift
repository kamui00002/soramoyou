//
//  HomeToolbarImageAssetTests.swift
//  SoramoyouTests
//
//  ホームのツールバーに出す 2 枚の画像（見出しのロゴ・そらともの入口の絵）が、
//  アプリのアセットから本当に引けるかの検証 ⭐️（PR-H）
//
//  - 見出しのロゴ: AppTitleView.logoAssetName（SoramoyouLogo.imageset）
//  - そらともの入口の絵: SoratomoEntryButton.iconAssetName（SoratomoGroupIcon.imageset）
//
//  このテストはアプリに載って動く（TEST_HOST 設定済み）ので、`UIImage(named:)` はアプリの束
//  （Bundle.main）の Assets.xcassets から画像を引く。
//

@testable import Soramoyou
import UIKit
import XCTest

/// ホームのツールバーの画像のアセット名が、実在するアセットを指しているかの検証
///
/// 最低 iOS 16 なので、アセットから自動で作られる名前付きの参照（生成シンボル `Image(.xxx)`。iOS 17〜）が使えず、
/// 画像は文字列の名前で引いている。名前を打ち間違えてもビルドは通ってしまい、
/// 画面には何も出ない（`Image("名前")` は見つからなくても落ちずに空になる）。それをここで拾う。
final class HomeToolbarImageAssetTests: XCTestCase {
    /// 見出しのロゴ画像がアセットから引ける
    func testLogoAssetExists() {
        XCTAssertNotNil(
            UIImage(named: AppTitleView.logoAssetName),
            "見出しのロゴ画像が見つからない: \(AppTitleView.logoAssetName)"
        )
    }

    /// そらともの入口の絵がアセットから引ける
    func testSoratomoIconAssetExists() {
        XCTAssertNotNil(
            UIImage(named: SoratomoEntryButton.iconAssetName),
            "そらともの入口の絵が見つからない: \(SoratomoEntryButton.iconAssetName)"
        )
    }
}
