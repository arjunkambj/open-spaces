// swift-tools-version: 6.0
import PackageDescription

// OpenAI adapters: transcription and language model.
let package = Package(
  name: "WisperAI",
  platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "WisperAI", targets: ["WisperAI"])
  ],
  dependencies: [
    .package(path: "../domain"),
    // Tests only: what reaches the network is also tested with the real settings file.
    .package(path: "../store"),
  ],
  targets: [
    .target(
      name: "WisperAI",
      dependencies: [
        .product(name: "WisperDomain", package: "domain")
      ]
    ),
    .testTarget(
      name: "WisperAITests",
      dependencies: [
        "WisperAI",
        .product(name: "WisperDomain", package: "domain"),
        .product(name: "WisperStore", package: "store"),
      ]
    ),
  ]
)
