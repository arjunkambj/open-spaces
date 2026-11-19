// swift-tools-version: 6.0
import PackageDescription

// MCP server and `wisper` command-line tool for agents.
let package = Package(
  name: "WisperAgent",
  platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "WisperAgent", targets: ["WisperAgent"]),
    .executable(name: "wisper", targets: ["wisper"]),
  ],
  dependencies: [
    .package(path: "../domain"),
    .package(path: "../store"),
  ],
  targets: [
    .target(
      name: "WisperAgent",
      dependencies: [
        .product(name: "WisperDomain", package: "domain"),
        .product(name: "WisperStore", package: "store"),
      ]
    ),
    .executableTarget(
      name: "wisper",
      dependencies: [
        "WisperAgent",
        .product(name: "WisperStore", package: "store"),
      ]
    ),
    .testTarget(
      name: "WisperAgentTests",
      dependencies: [
        "WisperAgent",
        // The end-to-end test starts the built program.
        "wisper",
        .product(name: "WisperDomain", package: "domain"),
        // Only the end-to-end test uses the store, to put real files in front of the built tool.
        .product(name: "WisperStore", package: "store"),
      ]
    ),
  ]
)
