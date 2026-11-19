// swift-tools-version: 6.0
import PackageDescription

// Models and seams shared by every Open Wisper module.
let package = Package(
  name: "WisperDomain",
  platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "WisperDomain", targets: ["WisperDomain"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "WisperDomain",
      dependencies: []
    ),
    .testTarget(name: "WisperDomainTests", dependencies: ["WisperDomain"]),
  ]
)
