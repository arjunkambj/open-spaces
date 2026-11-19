// swift-tools-version: 6.0
import PackageDescription

// Design system: tokens and SwiftUI components.
let package = Package(
  name: "WisperUI",
  platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "WisperUI", targets: ["WisperUI"])
  ],
  dependencies: [
    .package(path: "../domain"),
    .package(path: "../engine"),
  ],
  targets: [
    .target(
      name: "WisperUI",
      dependencies: [
        .product(name: "WisperDomain", package: "domain"),
        .product(name: "WisperEngine", package: "engine"),
      ]
    ),
    .testTarget(
      name: "WisperUITests",
      dependencies: [
        "WisperUI",
        .product(name: "WisperDomain", package: "domain"),
        .product(name: "WisperEngine", package: "engine"),
      ]
    ),
  ]
)
