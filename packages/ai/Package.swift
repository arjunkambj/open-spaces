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
    .package(path: "../domain")
  ],
  targets: [
    .target(
      name: "WisperAI",
      dependencies: [
        .product(name: "WisperDomain", package: "domain")
      ]
    )
  ]
)
