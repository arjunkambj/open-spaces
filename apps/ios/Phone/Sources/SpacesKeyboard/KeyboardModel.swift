import Foundation
import Observation
import SpacesDomain

/// What the keyboard can do to the text field it is typing into, and to the system.
/// The keyboard extension supplies the real one; the sample keyboard's does nothing.
public struct KeyboardHost: Sendable {
  /// Types text at the cursor.
  public var insert: @MainActor @Sendable (String) -> Void
  /// Deletes one character before the cursor.
  public var deleteBackward: @MainActor @Sendable () -> Void
  /// Switches to the person's next keyboard.
  public var nextKeyboard: @MainActor @Sendable () -> Void
  /// Opens a link in the app it belongs to. Returns whether the system opened it.
  public var open: @MainActor @Sendable (URL) async -> Bool
  /// Whether the person turned on Allow Full Access for this keyboard.
  public var hasFullAccess: @MainActor @Sendable () -> Bool
  /// Whether this keyboard must show its own key for switching keyboards.
  public var needsGlobeKey: @MainActor @Sendable () -> Bool

  public init(
    insert: @escaping @MainActor @Sendable (String) -> Void,
    deleteBackward: @escaping @MainActor @Sendable () -> Void,
    nextKeyboard: @escaping @MainActor @Sendable () -> Void,
    open: @escaping @MainActor @Sendable (URL) async -> Bool,
    hasFullAccess: @escaping @MainActor @Sendable () -> Bool,
    needsGlobeKey: @escaping @MainActor @Sendable () -> Bool = { true }
  ) {
    self.insert = insert
    self.deleteBackward = deleteBackward
    self.nextKeyboard = nextKeyboard
    self.open = open
    self.hasFullAccess = hasFullAccess
    self.needsGlobeKey = needsGlobeKey
  }
}

/// Everything the keyboard knows and does, behind the keys of `KeyboardPanel`.
///
/// iOS does not let a keyboard use the microphone, so this keyboard is a companion to the
/// app: its Dictate key opens the app to listen, and its other keys type what the app
/// already holds (the latest dictation, the snippets). It only ever reads the library.
@MainActor
@Observable
public final class KeyboardModel {
  /// Why the keyboard cannot do its job right now.
  public enum Problem: Equatable, Sendable {
    /// This build has no folder in common with the app (it was not signed with the App Group).
    case noSharedFolder
    /// Allow Full Access is off, so the keyboard may not open the app or read its files.
    case needsFullAccess
    /// The library is there but could not be read.
    case cannotRead(String)
  }

  /// The person's snippets, newest first.
  public private(set) var snippets: [Snippet] = []
  /// The text of the most recent dictation, when there is one.
  public private(set) var latest: String?
  public private(set) var problem: Problem?
  /// A short message about the last key press that did not work. Cleared by the next press.
  public private(set) var hint: String?
  /// Whether to show the key that switches keyboards.
  public private(set) var showsGlobeKey = true

  /// How long the delete key is held before it starts repeating, and how fast it repeats.
  private static let repeatDelay: Duration = .milliseconds(420)
  private static let repeatInterval: Duration = .milliseconds(85)

  @ObservationIgnored private let library: (any Library)?
  @ObservationIgnored private let dataFolder: URL?
  @ObservationIgnored private let host: KeyboardHost
  @ObservationIgnored private var repeating: Task<Void, Never>?

  /// - library: the library the app writes to, or `nil` when this build cannot reach it.
  /// - dataFolder: the folder that library is in, shared with the app. The Dictate key
  ///   leaves a `LinkTicket` there, which is how the app knows the request is the keyboard's
  ///   and starts listening without asking. `nil` when there is no such folder.
  public init(library: (any Library)?, dataFolder: URL? = nil, host: KeyboardHost) {
    self.library = library
    self.dataFolder = dataFolder
    self.host = host
  }

  /// Reads the library again. Call it each time the keyboard comes on screen.
  public func refresh() async {
    showsGlobeKey = host.needsGlobeKey()
    let fullAccess = host.hasFullAccess()
    guard let library else {
      snippets = []
      latest = nil
      problem = .noSharedFolder
      return
    }
    do {
      let snippets = try await library.snippets()
      // A handful is enough to find the newest one that holds text.
      let recent = try await library.dictations(search: nil, limit: 20)
      self.snippets = snippets
      latest = recent.first { !$0.failed && !$0.text.isEmpty }?.text
      problem = fullAccess ? nil : .needsFullAccess
    } catch {
      snippets = []
      latest = nil
      // Without Full Access iOS keeps the keyboard out of the shared folder altogether.
      problem = fullAccess ? .cannotRead(error.localizedDescription) : .needsFullAccess
    }
  }

  /// Fills the keyboard without a library. For the sample.
  func show(snippets: [Snippet], latest: String?, problem: Problem? = nil) {
    self.snippets = snippets
    self.latest = latest
    self.problem = problem
  }

  /// The Dictate key: opens the app, which starts listening.
  public func dictate() async {
    hint = nil
    // Without a ticket (no shared folder, or it cannot be written) the app still opens on
    // its Dictate screen, and the person taps the button there.
    let ticket = dataFolder.flatMap { try? LinkTicket.issue(in: $0) }
    guard await host.open(SpacesLink.toggleDictation.url(ticket: ticket)) else {
      hint =
        host.hasFullAccess()
        ? "Could not open Spaces. Open the app to dictate, then come back here."
        : "Turn on Allow Full Access so this key can open Spaces."
      return
    }
  }

  /// Types the most recent dictation.
  public func insertLatest() {
    hint = nil
    guard let latest else {
      hint = "Nothing dictated yet. Tap Dictate first."
      return
    }
    host.insert(latest)
  }

  /// Types a snippet's text.
  public func insert(_ snippet: Snippet) {
    hint = nil
    host.insert(snippet.expansion)
  }

  public func space() {
    hint = nil
    host.insert(" ")
  }

  public func newLine() {
    hint = nil
    host.insert("\n")
  }

  public func nextKeyboard() {
    host.nextKeyboard()
  }

  /// The delete key went down: deletes once, then keeps deleting while it is held.
  public func deleteBegan() {
    hint = nil
    repeating?.cancel()
    host.deleteBackward()
    let host = host
    repeating = Task {
      try? await Task.sleep(for: Self.repeatDelay)
      while !Task.isCancelled {
        host.deleteBackward()
        try? await Task.sleep(for: Self.repeatInterval)
      }
    }
  }

  /// The delete key came up.
  public func deleteEnded() {
    repeating?.cancel()
    repeating = nil
  }
}
