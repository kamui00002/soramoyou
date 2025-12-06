//
//  Location.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import CoreLocation

/// 位置情報Value Object
struct Location: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let city: String?
    let prefecture: String?
    let landmark: String?
    
    init(
        latitude: Double,
        longitude: Double,
        city: String? = nil,
        prefecture: String? = nil,
        landmark: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.prefecture = prefecture
        self.landmark = landmark
    }
    
    /// CLLocationCoordinate2Dから初期化
    init(coordinate: CLLocationCoordinate2D, city: String? = nil, prefecture: String? = nil, landmark: String? = nil) {
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.city = city
        self.prefecture = prefecture
        self.landmark = landmark
    }
    
    /// CLLocationCoordinate2Dに変換
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    
    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "latitude": latitude,
            "longitude": longitude
        ]
        
        if let city = city {
            data["city"] = city
        }
        
        if let prefecture = prefecture {
            data["prefecture"] = prefecture
        }
        
        if let landmark = landmark {
            data["landmark"] = landmark
        }
        
        return data
    }
    
    /// Firestoreドキュメントデータから初期化
    init?(from documentData: [String: Any]) {
        guard let latitude = documentData["latitude"] as? Double,
              let longitude = documentData["longitude"] as? Double else {
            return nil
        }
        
        self.latitude = latitude
        self.longitude = longitude
        self.city = documentData["city"] as? String
        self.prefecture = documentData["prefecture"] as? String
        self.landmark = documentData["landmark"] as? String
    }
}


