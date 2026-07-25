// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HavenCore",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "HavenCore", targets: ["HavenCore"])],
    targets: [
        .target(name: "HavenCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "HavenCoreTests", dependencies: ["HavenCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
