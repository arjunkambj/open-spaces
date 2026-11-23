// swift-tools-version: 6.0
import PackageDescription

// OpenAI adapters: transcription and language model.
let package = Package(
  name: "SpacesAI",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "SpacesAI", targets: ["SpacesAI"])
  ],
  dependencies: [
    .package(path: "../domain")
  ],
  targets: [
    .target(
      name: "SpacesAI",
      dependencies: [
        .product(name: "SpacesDomain", package: "domain")
      ]
    )
  ]
)
