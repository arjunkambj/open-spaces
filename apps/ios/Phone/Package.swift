// swift-tools-version: 6.0
import PackageDescription

// Everything of the iPhone app that is not tied to an Xcode target: the screens only the
// phone has, the phone's adapters, and the keyboard. It also builds on a Mac, so its
// snapshot tool runs without Xcode. The Xcode targets in `../App`, `../Keyboard` and
// `../Widgets` are thin shells around these libraries.
let package = Package(
  name: "SpacesPhone",
  platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "SpacesPhone", targets: ["SpacesPhone"]),
    .library(name: "SpacesKeyboard", targets: ["SpacesKeyboard"]),
    .library(name: "SpacesLive", targets: ["SpacesLive"]),
    // macOS-only tool that draws the phone's own screens to PNG files.
    .executable(name: "spaces-phone-snapshots", targets: ["spaces-phone-snapshots"]),
  ],
  dependencies: [
    .package(path: "../../../packages/domain"),
    .package(path: "../../../packages/store"),
    .package(path: "../../../packages/ai"),
    .package(path: "../../../packages/audio"),
    .package(path: "../../../packages/engine"),
    .package(path: "../../../packages/ui"),
  ],
  targets: [
    // The keyboard extension. It must stay small: no audio, no network.
    .target(
      name: "SpacesKeyboard",
      dependencies: [
        .product(name: "SpacesDomain", package: "domain"),
        .product(name: "SpacesStore", package: "store"),
        .product(name: "SpacesUI", package: "ui"),
      ]
    ),
    // The Live Activity: a recording shown on the Lock Screen and in the Dynamic Island.
    .target(
      name: "SpacesLive",
      dependencies: [
        .product(name: "SpacesDomain", package: "domain"),
        .product(name: "SpacesUI", package: "ui"),
      ]
    ),
    // The app: the wiring of real adapters, the tab shell and the Dictate screen.
    .target(
      name: "SpacesPhone",
      dependencies: [
        "SpacesKeyboard",
        "SpacesLive",
        .product(name: "SpacesDomain", package: "domain"),
        .product(name: "SpacesStore", package: "store"),
        .product(name: "SpacesAI", package: "ai"),
        .product(name: "SpacesAudio", package: "audio"),
        .product(name: "SpacesEngine", package: "engine"),
        .product(name: "SpacesUI", package: "ui"),
      ]
    ),
    .executableTarget(
      name: "spaces-phone-snapshots",
      dependencies: [
        "SpacesPhone",
        "SpacesKeyboard",
        .product(name: "SpacesUI", package: "ui"),
      ]
    ),
  ]
)
