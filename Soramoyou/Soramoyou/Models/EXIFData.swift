//
//  EXIFData.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation

/// EXIF情報
struct EXIFData: Codable, Equatable {
    let capturedAt: Date?
    let cameraModel: String?
    let iso: Int?
    let shutterSpeed: String?
    let aperture: String?
    let focalLength: String?
    
    init(
        capturedAt: Date? = nil,
        cameraModel: String? = nil,
        iso: Int? = nil,
        shutterSpeed: String? = nil,
        aperture: String? = nil,
        focalLength: String? = nil
    ) {
        self.capturedAt = capturedAt
        self.cameraModel = cameraModel
        self.iso = iso
        self.shutterSpeed = shutterSpeed
        self.aperture = aperture
        self.focalLength = focalLength
    }
}

