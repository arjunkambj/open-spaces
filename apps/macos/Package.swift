// swift-tools-version: 6.0
import PackageDescription

// The macOS app. Built with SwiftPM so it needs only the Command Line Tools;
// `scripts/bundle` wraps the result into "Open Wisper.app".
let package = Package(
  name: "OpenWisperMac",
  platforms: [.macOS("14.4")],
  products: [
    .executable(name: "OpenWisper", targets: ["OpenWisper"]),
    .library(name: "WisperMac", targets: ["WisperMac"]),
    .library(name: "WisperMacUI", targets: ["WisperMacUI"]),
  ],
  dependencies: [
    .package(path: "../../packages/domain"),
    .package(path: "../../packages/store"),
    .package(path: "../../packages/ai"),
    .package(path: "../../packages/audio"),
    .package(path: "../../packages/engine"),
    .package(path: "../../packages/ui"),
    .package(path: "../../packages/agent"),
  ],
  targets: [
    // macOS system glue: global shortcuts, typing into other apps, permissions.
    .target(
      name: "WisperMac",
      dependencies: [.product(name: "WisperDomain", package: "domain")]
    ),
    // Every macOS screen: hub, settings, onboarding, the floating pill.
    .target(
      name: "WisperMacUI",
      dependencies: [
        "WisperMac",
        .product(name: "WisperDomain", package: "domain"),
        .product(name: "WisperEngine", package: "engine"),
        .product(name: "WisperUI", package: "ui"),
      ]
    ),
    // The app itself: windows, menu bar item and the wiring of real adapters.
    .executableTarget(
      name: "OpenWisper",
      dependencies: [
        "WisperMac",
        "WisperMacUI",
        .product(name: "WisperDomain", package: "domain"),
        .product(name: "WisperStore", package: "store"),
        .product(name: "WisperAI", package: "ai"),
        .product(name: "WisperAudio", package: "audio"),
        .product(name: "WisperEngine", package: "engine"),
        .product(name: "WisperUI", package: "ui"),
      ]
    ),
    .testTarget(
      name: "WisperMacTests",
      dependencies: ["WisperMac", .product(name: "WisperDomain", package: "domain")]
    ),
  ]
)
