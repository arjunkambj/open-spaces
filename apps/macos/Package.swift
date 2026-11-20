// swift-tools-version: 6.0
import PackageDescription

// The macOS app. Built with SwiftPM so it needs only the Command Line Tools;
// `scripts/bundle` wraps the result into "Spaces.app".
let package = Package(
  name: "SpacesMac",
  platforms: [.macOS("14.4")],
  products: [
    .executable(name: "SpacesApp", targets: ["SpacesApp"]),
    .library(name: "SpacesMac", targets: ["SpacesMac"]),
    .library(name: "SpacesMacUI", targets: ["SpacesMacUI"]),
  ],
  dependencies: [
    .package(path: "../../packages/domain"),
    .package(path: "../../packages/store"),
    .package(path: "../../packages/ai"),
    .package(path: "../../packages/audio"),
    .package(path: "../../packages/engine"),
    .package(path: "../../packages/ui"),
    .package(path: "../../packages/agent"),
    // The one third-party library: Sparkle, the standard updater for Mac apps that are not in
    // the App Store. An updater checks and replaces the app itself, so it is not code to write
    // twice. Pinned to one exact version; Package.resolved records the checksum of its download.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
  ],
  targets: [
    // macOS system glue: global shortcuts, typing into other apps, permissions.
    .target(
      name: "SpacesMac",
      dependencies: [.product(name: "SpacesDomain", package: "domain")]
    ),
    // Every macOS screen: hub, settings, onboarding, the floating pill.
    .target(
      name: "SpacesMacUI",
      dependencies: [
        "SpacesMac",
        .product(name: "SpacesDomain", package: "domain"),
        .product(name: "SpacesEngine", package: "engine"),
        .product(name: "SpacesUI", package: "ui"),
      ]
    ),
    // The app itself: windows, menu bar item and the wiring of real adapters. Not named
    // "Spaces": on a Mac, file names ignore case, and the bundle also holds the `spaces` tool.
    .executableTarget(
      name: "SpacesApp",
      dependencies: [
        "SpacesMac",
        "SpacesMacUI",
        .product(name: "SpacesDomain", package: "domain"),
        .product(name: "SpacesStore", package: "store"),
        .product(name: "SpacesAI", package: "ai"),
        .product(name: "SpacesAudio", package: "audio"),
        .product(name: "SpacesEngine", package: "engine"),
        .product(name: "SpacesUI", package: "ui"),
        .product(name: "Sparkle", package: "Sparkle"),
      ]
    ),
  ]
)
