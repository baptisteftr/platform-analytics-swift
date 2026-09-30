// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlatformAnalytics",
    platforms: [
        .iOS("17.4"),
        .macOS("14.4"),
        .visionOS("1.1"),
    ],
    products: [
        .library(name: "PlatformAnalytics", targets: ["PlatformAnalytics"])
    ],
    targets: [
        .target(
            name: "PlatformAnalytics",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "PlatformAnalyticsTests", dependencies: ["PlatformAnalytics"]),
    ]
)
