// swift-tools-version: 6.0
import PackageDescription

// Dictation and meeting engines.
let package = Package(
  name: "WisperEngine",
  platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "WisperEngine", targets: ["WisperEngine"])
  ],
  dependencies: [
    .package(path: "../domain")
  ],
  targets: [
    .target(
      name: "WisperEngine",
      dependencies: [
        .product(name: "WisperDomain", package: "domain")
      ]
    )
  ]
)
