// swift-tools-version: 6.0
// 来自 https://github.com/gonzalezreal/textual 0.5.0（01b5187，MIT），去掉了测试目标。
// Westie 的补丁见 PATCHES.md。

import PackageDescription

let package = Package(
  name: "textual",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
    .tvOS(.v18),
    .watchOS(.v11),
    .visionOS(.v2),
  ],
  products: [
    .library(name: "Textual", targets: ["Textual"])
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.3.1"),
    .package(url: "https://github.com/gonzalezreal/swiftui-math", from: "0.1.0"),
  ],
  targets: [
    .target(
      name: "Textual",
      dependencies: [
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
        .product(name: "SwiftUIMath", package: "swiftui-math"),
      ],
      resources: [
        .process("Internal/Highlighter/Prism")
      ],
      swiftSettings: [
        .define(
          "TEXTUAL_ENABLE_LINKS",
          .when(platforms: [.macOS, .macCatalyst, .iOS, .watchOS, .visionOS])),
        .define(
          "TEXTUAL_ENABLE_TEXT_SELECTION",
          .when(platforms: [.macOS, .macCatalyst, .iOS, .visionOS])),
      ]
    )
  ]
)
