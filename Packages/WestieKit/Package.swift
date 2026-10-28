// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WestieKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WestieKit", targets: ["WestieKit"]),
    ],
    targets: [
        .target(name: "WestieKit"),
        .testTarget(name: "WestieKitTests", dependencies: ["WestieKit"], resources: [.copy("Fixtures")]),
    ]
)
