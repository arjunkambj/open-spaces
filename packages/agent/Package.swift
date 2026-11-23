// swift-tools-version: 6.0
import PackageDescription

// MCP server and `spaces` command-line tool for agents.
let package = Package(
  name: "SpacesAgent",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "SpacesAgent", targets: ["SpacesAgent"]),
    .executable(name: "spaces", targets: ["spaces"]),
  ],
  dependencies: [
    .package(path: "../domain"),
    .package(path: "../store"),
  ],
  targets: [
    .target(
      name: "SpacesAgent",
      dependencies: [
        .product(name: "SpacesDomain", package: "domain"),
        .product(name: "SpacesStore", package: "store"),
      ]
    ),
    .executableTarget(
      name: "spaces",
      dependencies: [
        "SpacesAgent",
        .product(name: "SpacesStore", package: "store"),
      ]
    ),
  ]
)
