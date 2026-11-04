// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LittleSurfaceCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "LittleSurfaceCore", targets: ["LittleSurfaceCore"])],
    targets: [
        .target(
            name: "LittleSurfaceCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .testTarget(name: "LittleSurfaceCoreTests", dependencies: ["LittleSurfaceCore"]),
    ],
    swiftLanguageModes: [.v5]
)
