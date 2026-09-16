// swift-tools-version: 5.10
// ⭐️ そらもよう「空カメラ」のローカル Swift Package。
//    本体（Firebase / PostHog / アプリのモデル）には一切依存しない。
//    計装は `SkyCameraEvent` のコールバックで本体へ返し、ここでは何も送信しない。
import PackageDescription

let package = Package(
    name: "SkyCamera",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "SkyCamera", targets: ["SkyCamera"])
    ],
    targets: [
        .target(name: "SkyCamera")
    ]
)
