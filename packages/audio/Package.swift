// swift-tools-version: 6.0
import PackageDescription

// Microphone and system-audio capture.
let package = Package(
  name: "WisperAudio",
  platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "WisperAudio", targets: ["WisperAudio"])
  ],
  dependencies: [
    .package(path: "../domain")
  ],
  targets: [
    .target(
      name: "WisperAudio",
      dependencies: [
        .product(name: "WisperDomain", package: "domain")
      ]
    ),
    .testTarget(
      name: "WisperAudioTests",
      dependencies: ["WisperAudio", .product(name: "WisperDomain", package: "domain")]
    ),
  ]
)
