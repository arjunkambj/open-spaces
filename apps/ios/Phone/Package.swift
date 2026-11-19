// swift-tools-version: 6.0
import PackageDescription

// Everything of the iPhone app that is not tied to an Xcode target: the screens only the
// phone has, the phone's adapters, and the keyboard. It also builds on a Mac, so its tests
// and its snapshot tool run without Xcode. The Xcode targets in `../App`, `../Keyboard` and
// `../Widgets` are thin shells around these libraries.
let package = Package(
  name: "WisperPhone",
  platforms: [.macOS("14.4"), .iOS(.v17)],
  products: [
    .library(name: "WisperPhone", targets: ["WisperPhone"]),
    .library(name: "WisperKeyboard", targets: ["WisperKeyboard"]),
    .library(name: "WisperLive", targets: ["WisperLive"]),
    // macOS-only tool that draws the phone's own screens to PNG files.
    .executable(name: "wisper-phone-snapshots", targets: ["wisper-phone-snapshots"]),
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
      name: "WisperKeyboard",
      dependencies: [
        .product(name: "WisperDomain", package: "domain"),
        .product(name: "WisperStore", package: "store"),
        .product(name: "WisperUI", package: "ui"),
      ]
    ),
    // The Live Activity: a recording shown on the Lock Screen and in the Dynamic Island.
    .target(
      name: "WisperLive",
      dependencies: [
        .product(name: "WisperDomain", package: "domain"),
        .product(name: "WisperUI", package: "ui"),
      ]
    ),
    // The app: the wiring of real adapters, the tab shell and the Dictate screen.
    .target(
      name: "WisperPhone",
      dependencies: [
        "WisperKeyboard",
        "WisperLive",
        .product(name: "WisperDomain", package: "domain"),
        .product(name: "WisperStore", package: "store"),
        .product(name: "WisperAI", package: "ai"),
        .product(name: "WisperAudio", package: "audio"),
        .product(name: "WisperEngine", package: "engine"),
        .product(name: "WisperUI", package: "ui"),
      ]
    ),
    .executableTarget(
      name: "wisper-phone-snapshots",
      dependencies: [
        "WisperPhone",
        "WisperKeyboard",
        .product(name: "WisperUI", package: "ui"),
      ]
    ),
  ]
)
