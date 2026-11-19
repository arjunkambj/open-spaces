// swift-tools-version: 6.0
import PackageDescription

// File-backed Library and Keychain secret store.
let package = Package(
  name: "WisperStore",
  platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "WisperStore", targets: ["WisperStore"])
  ],
  dependencies: [
    .package(path: "../domain")
  ],
  targets: [
    .target(
      name: "WisperStore",
      dependencies: [
        .product(name: "WisperDomain", package: "domain")
      ]
    ),
    .testTarget(
      name: "WisperStoreTests",
      dependencies: ["WisperStore", .product(name: "WisperDomain", package: "domain")]
    ),
  ]
)
