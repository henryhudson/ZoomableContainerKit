// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZoomableContainerKit",
    // iOS 16 is the floor: DaDeckOfCards deploys to 16.0 (Hansard to 26.0).
    // The component uses only long-standing UIKit APIs, so 16 is safe.
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "ZoomableContainerKit", targets: ["ZoomableContainerKit"]),
    ],
    targets: [
        .target(
            name: "ZoomableContainerKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZoomableContainerKitTests",
            dependencies: ["ZoomableContainerKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
