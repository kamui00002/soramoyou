//
//  AppCheckProviderFactories.swift
//  Soramoyou
//
//  Created on 2026-05-14.
//  Silent failure fix SR-H1: App Check Provider Factory
//

import Foundation
#if canImport(FirebaseAppCheck)
import FirebaseAppCheck
import FirebaseCore

/// 本番ビルド用の App Check Provider Factory。
/// iOS 14+ では DeviceCheck より強力な AppAttest を優先利用する。
/// AppAttest が使えない端末では DeviceCheck にフォールバック。
final class SoramoyouAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        if #available(iOS 14.0, *) {
            return AppAttestProvider(app: app)
        } else {
            return DeviceCheckProvider(app: app)
        }
    }
}
#endif
