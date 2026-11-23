// swift-tools-version: 6.0
import PackageDescription

// Design system: tokens and SwiftUI components.
let package = Package(
  name: "SpacesUI",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "SpacesUI", targets: ["SpacesUI"]),
    // macOS-only tool that renders every snapshot case to PNG files.
    .executable(name: "spaces-snapshots", targets: ["spaces-snapshots"]),
  ],
  dependencies: [
    .package(path: "../domain"),
    .package(path: "../engine"),
  ],
  targets: [
    .target(
      name: "SpacesUI",
      dependencies: [
        .product(name: "SpacesDomain", package: "domain"),
        .product(name: "SpacesEngine", package: "engine"),
      ]
    ),
    .executableTarget(
      name: "spaces-snapshots",
      dependencies: [
        "SpacesUI",
        .product(name: "SpacesDomain", package: "domain"),
        .product(name: "SpacesEngine", package: "engine"),
      ]
    ),
  ]
)
