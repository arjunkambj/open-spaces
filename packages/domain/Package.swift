// swift-tools-version: 6.0
import PackageDescription

// Models and seams shared by every Spaces module.
let package = Package(
  name: "SpacesDomain",
  platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "SpacesDomain", targets: ["SpacesDomain"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "SpacesDomain",
      dependencies: []
    )
  ]
)
