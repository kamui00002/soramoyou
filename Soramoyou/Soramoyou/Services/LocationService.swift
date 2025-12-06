//
//  LocationService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import CoreLocation
import MapKit

protocol LocationServiceProtocol {
    func requestLocationPermission() async -> Bool
    func getCurrentLocation() async throws -> CLLocation
    func reverseGeocode(location: CLLocation) async throws -> (city: String?, prefecture: String?)
    func searchLandmarks(query: String, region: MKCoordinateRegion) async throws -> [MKMapItem]
}

class LocationService: NSObject, LocationServiceProtocol, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    // MARK: - Location Permission
    
    func requestLocationPermission() async -> Bool {
        let status = locationManager.authorizationStatus
        
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                permissionContinuation = continuation
                locationManager.requestWhenInUseAuthorization()
            }
        default:
            return false
        }
    }
    
    // MARK: - Get Current Location
    
    func getCurrentLocation() async throws -> CLLocation {
        let hasPermission = await requestLocationPermission()
        guard hasPermission else {
            throw LocationServiceError.permissionDenied
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            locationManager.requestLocation()
        }
    }
    
    // MARK: - Reverse Geocoding
    
    func reverseGeocode(location: CLLocation) async throws -> (city: String?, prefecture: String?) {
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        
        guard let placemark = placemarks.first else {
            throw LocationServiceError.geocodingFailed
        }
        
        let city = placemark.locality
        let prefecture = placemark.administrativeArea
        
        return (city: city, prefecture: prefecture)
    }
    
    // MARK: - Search Landmarks
    
    func searchLandmarks(query: String, region: MKCoordinateRegion) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region
        
        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        
        return response.mapItems
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        locationContinuation?.resume(returning: location)
        locationContinuation = nil
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if let continuation = permissionContinuation {
            let granted = status == .authorizedWhenInUse || status == .authorizedAlways
            continuation.resume(returning: granted)
            permissionContinuation = nil
        }
    }
}

// MARK: - LocationServiceError

enum LocationServiceError: LocalizedError {
    case permissionDenied
    case geocodingFailed
    case locationNotFound
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "位置情報の使用許可が必要です"
        case .geocodingFailed:
            return "位置情報の取得に失敗しました"
        case .locationNotFound:
            return "位置情報が見つかりませんでした"
        }
    }
}


