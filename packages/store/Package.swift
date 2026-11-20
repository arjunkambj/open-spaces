// swift-tools-version: 6.0
import PackageDescription

// File-backed Library and secret store.
let package = Package(
  name: "SpacesStore",
  platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "SpacesStore", targets: ["SpacesStore"])
  ],
  dependencies: [
    .package(path: "../domain")
  ],
  targets: [
    .target(
      name: "SpacesStore",
      dependencies: [
        .product(name: "SpacesDomain", package: "domain")
      ]
    )
  ]
)
