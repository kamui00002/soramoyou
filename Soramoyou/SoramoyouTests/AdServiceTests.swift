//
//  AdServiceTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import XCTest
@testable import Soramoyou
import GoogleMobileAds

final class AdServiceTests: XCTestCase {
    var adService: AdService!
    
    override func setUp() {
        super.setUp()
        adService = AdService.shared
    }
    
    override func tearDown() {
        adService = nil
        super.tearDown()
    }
    
    func testAdServiceInitialization() {
        // Given & When
        let service = AdService.shared
        
        // Then
        XCTAssertNotNil(service)
    }
    
    func testGetBannerAdSize() {
        // Given & When
        let adSize = adService.getBannerAdSize()
        
        // Then
        XCTAssertNotNil(adSize)
        XCTAssertGreaterThan(adSize.size.width, 0)
        XCTAssertGreaterThan(adSize.size.height, 0)
    }
    
    func testBannerAdSizeIsAdaptive() {
        // Given & When
        let adSize = adService.getBannerAdSize()
        let screenWidth = UIScreen.main.bounds.width
        
        // Then
        // アダプティブバナー広告のサイズは画面幅に基づいている
        XCTAssertLessThanOrEqual(adSize.size.width, screenWidth)
    }
}


