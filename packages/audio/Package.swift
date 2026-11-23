// swift-tools-version: 6.0
import PackageDescription

// Microphone and system-audio capture.
let package = Package(
  name: "SpacesAudio",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "SpacesAudio", targets: ["SpacesAudio"])
  ],
  dependencies: [
    .package(path: "../domain")
  ],
  targets: [
    .target(
      name: "SpacesAudio",
      dependencies: [
        .product(name: "SpacesDomain", package: "domain")
      ]
    )
  ]
)
