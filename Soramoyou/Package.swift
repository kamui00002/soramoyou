// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Soramoyou",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "Soramoyou",
            targets: ["Soramoyou"]),
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "10.18.0"),
        .package(url: "https://github.com/onevcat/Kingfisher", from: "7.9.0"),
        .package(url: "https://github.com/googleads/swift-package-manager-google-mobile-ads.git", from: "10.14.0"),
    ],
    targets: [
        .target(
            name: "Soramoyou",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseStorage", package: "firebase-ios-sdk"),
                .product(name: "Kingfisher", package: "Kingfisher"),
                .product(name: "GoogleMobileAds", package: "swift-package-manager-google-mobile-ads"),
            ]),
        .testTarget(
            name: "SoramoyouTests",
            dependencies: ["Soramoyou"]),
    ]
)

