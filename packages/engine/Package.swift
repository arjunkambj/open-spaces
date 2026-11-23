// swift-tools-version: 6.0
import PackageDescription

// Dictation and meeting engines.
let package = Package(
  name: "SpacesEngine",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "SpacesEngine", targets: ["SpacesEngine"])
  ],
  dependencies: [
    .package(path: "../domain")
  ],
  targets: [
    .target(
      name: "SpacesEngine",
      dependencies: [
        .product(name: "SpacesDomain", package: "domain")
      ]
    )
  ]
)
