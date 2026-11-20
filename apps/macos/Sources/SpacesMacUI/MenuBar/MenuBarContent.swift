import AppKit
import SpacesDomain
import SpacesEngine
import SpacesMac
import SpacesUI
import SwiftUI

/// One line of the menu bar menu.
public struct MenuEntry: Equatable, Sendable {
  /// What choosing a line does.
  public enum Command: Equatable, Sendable {
    case openHub
    case toggleMeeting
    case pasteLast
    /// Use this input device; `nil` is the Mac's own choice.
    case pickMicrophone(String?)
    case openSettings
    /// Look for a new version of the app now, or show the one that was found.
    case checkForUpdates
    /// Keep the resting pill out of sight for an hour, or bring it back.
    case hidePill
    case showPill
    /// Put the pill back at the middle of the bottom edge.
    case resetPillPosition
    case quit
  }

  public enum Kind: Equatable, Sendable {
    case action(Command)
    case submenu([MenuEntry])
    /// A greyed line that only says something.
    case note
    case separator
  }

  public var title: String
  public var kind: Kind
  /// The shortcut to show at the right, or `nil`.
  public var shortcut: KeyCombo?
  public var isChecked: Bool

  public init(_ title: String, _ kind: Kind, shortcut: KeyCombo? = nil, isChecked: Bool = false) {
    self.title = title
    self.kind = kind
    self.shortcut = shortcut
    self.isChecked = isChecked
  }

  public static let separator = MenuEntry("", .separator)
}

/// What the menu bar item shows: its picture and the lines of its menu.
/// Plain values, so the menu can be checked and drawn without a menu bar.
@MainActor
public enum MenuBarContent {
  /// The picture in the menu bar.
  public enum Icon: Equatable, Sendable {
    case idle
    case dictating
    case meeting
  }

  /// Follows what the pill shows: a key that was only passing through (fn + arrow) changes nothing.
  public static func icon(for model: AppModel, controls: MacControls) -> Icon {
    if model.dictation.isRecording, controls.showsRecording { return .dictating }
    return model.meetings.isRecording ? .meeting : .idle
  }

  /// The menu, top to bottom.
  /// - microphones: the input devices to offer; the menu bar item looks them up.
  /// - waitingUpdate: the version of an update that was found and waits for an answer, such as "0.2.0".
  public static func entries(
    for model: AppModel,
    microphones: [AudioDevice],
    waitingUpdate: String? = nil
  ) -> [MenuEntry] {
    let settings = model.settings
    var entries = [
      MenuEntry("Open Spaces", .action(.openHub)),
      .separator,
      MenuEntry(
        model.meetings.isRecording ? "Stop Meeting Recording" : "Start Meeting Recording",
        .action(.toggleMeeting),
        shortcut: usable(settings.shortcut(for: .toggleMeeting))
      ),
      MenuEntry(
        "Paste Last Transcript",
        .action(.pasteLast),
        shortcut: usable(settings.shortcut(for: .pasteLast))
      ),
    ]
    if let last = model.dictations.first(where: { !$0.failed && !$0.text.isEmpty }) {
      entries.append(MenuEntry(preview(of: last.text), .note))
    }
    entries += [
      .separator,
      MenuEntry("Microphone", .submenu(microphoneEntries(microphones, chosen: settings.microphoneID))),
      MenuEntry("Settings…", .action(.openSettings), shortcut: KeyCombo(keyCode: 43, modifiers: [.command])),
    ]
    // Only where the app can update itself: not in the demo, and not in a build with no bundle.
    if model.host.checkForUpdates != nil {
      entries.append(MenuEntry(updateTitle(waiting: waitingUpdate), .action(.checkForUpdates)))
    }
    entries += [
      .separator,
      MenuEntry(dictationHint(settings), .note),
      .separator,
      MenuEntry("Quit Spaces", .action(.quit), shortcut: KeyCombo(keyCode: 12, modifiers: [.command])),
    ]
    return entries
  }

  /// The menu of a right click on the pill.
  public static func pillEntries(
    for model: AppModel,
    controls: MacControls,
    microphones: [AudioDevice]
  ) -> [MenuEntry] {
    let settings = model.settings
    let isHidden = controls.pillHiddenUntil.map { $0 > Date() } ?? false
    var entries = [
      isHidden
        ? MenuEntry("Show the Pill Again", .action(.showPill))
        : MenuEntry("Hide for an Hour", .action(.hidePill))
    ]
    // Only once it was moved: until then there is nothing to put back.
    if controls.pillSpots.isMoved {
      entries.append(MenuEntry("Reset Pill Position", .action(.resetPillPosition)))
    }
    return entries + [
      MenuEntry("Settings…", .action(.openSettings)),
      .separator,
      MenuEntry("Microphone", .submenu(microphoneEntries(microphones, chosen: settings.microphoneID))),
      .separator,
      MenuEntry("Open Spaces", .action(.openHub)),
      MenuEntry(
        "Paste Last Transcript",
        .action(.pasteLast),
        shortcut: usable(settings.shortcut(for: .pasteLast))
      ),
    ]
  }

  /// Does what a menu line stands for.
  public static func perform(_ command: MenuEntry.Command, model: AppModel, controls: MacControls) {
    switch command {
    case .openHub: controls.open(.hub)
    case .openSettings: controls.open(.settings)
    case .checkForUpdates: model.host.checkForUpdates?()
    case .toggleMeeting: controls.toggleMeeting()
    case .pasteLast: controls.pasteLast()
    case .pickMicrophone(let id): model.update { $0.microphoneID = id }
    case .hidePill: controls.hidePill(for: .seconds(3600))
    case .showPill: controls.hidePill(for: nil)
    case .resetPillPosition: controls.pillSpots.reset()
    case .quit: NSApplication.shared.terminate(nil)
    }
  }

  static func microphoneEntries(_ devices: [AudioDevice], chosen: String?) -> [MenuEntry] {
    let systemChoice = devices.first(where: \.isDefault).map { "Mac’s Choice (\($0.name))" } ?? "Mac’s Choice"
    var entries = [MenuEntry(systemChoice, .action(.pickMicrophone(nil)), isChecked: chosen == nil)]
    if !devices.isEmpty { entries.append(.separator) }
    entries += devices.map { device in
      MenuEntry(device.name, .action(.pickMicrophone(device.id)), isChecked: chosen == device.id)
    }
    // A chosen microphone that is unplugged right now still shows, so the choice is not a mystery.
    if let chosen, !devices.contains(where: { $0.id == chosen }) {
      entries.append(MenuEntry("Chosen microphone (not connected)", .note, isChecked: true))
    }
    return entries
  }

  /// The update line: it names the version once one was found.
  static func updateTitle(waiting version: String?) -> String {
    guard let version, !version.isEmpty else { return "Check for Updates…" }
    return "Install Update \(version)…"
  }

  static func dictationHint(_ settings: SpacesDomain.Settings) -> String {
    guard let combo = usable(settings.shortcut(for: .pushToTalk)) else {
      return "Click the pill to dictate"
    }
    return "Hold \(combo.keyCaps.joined(separator: " ")) to dictate"
  }

  /// The start of a dictation, short enough for a menu line.
  static func preview(of text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    return line.count > 44 ? "“\(line.prefix(42).trimmingCharacters(in: .whitespaces))…”" : "“\(line)”"
  }

  private static func usable(_ combo: KeyCombo?) -> KeyCombo? {
    guard let combo, !combo.isEmpty else { return nil }
    return combo
  }
}

/// A drawing of the menu bar menu, for still pictures. The app shows a real menu.
struct MenuPreview: View {
  let entries: [MenuEntry]

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.control, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
        row(entry)
      }
    }
    .padding(.vertical, Spaces.Space.xs + Spaces.Space.xxs)
    .frame(width: 290)
    .background {
      shape.fill(Spaces.Color.raised).shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }
    .overlay { shape.strokeBorder(Spaces.Color.border, lineWidth: Spaces.Stroke.hairline) }
  }

  @ViewBuilder private func row(_ entry: MenuEntry) -> some View {
    if entry.kind == .separator {
      Hairline().padding(.horizontal, Spaces.Space.m).padding(.vertical, Spaces.Space.xs)
    } else {
      HStack(spacing: Spaces.Space.s) {
        Image(systemName: "checkmark")
          .spacesText(.caption, color: Spaces.Color.textPrimary)
          .opacity(entry.isChecked ? 1 : 0)
          .frame(width: 12)
        Text(entry.title)
          .spacesText(
            .caption,
            color: entry.kind == .note ? Spaces.Color.textTertiary : Spaces.Color.textPrimary
          )
          .lineLimit(1)
        Spacer(minLength: Spaces.Space.l)
        if let shortcut = entry.shortcut {
          Text(shortcut.keyCaps.joined())
            .spacesText(.caption, color: Spaces.Color.textTertiary)
        }
        if case .submenu = entry.kind {
          Image(systemName: "chevron.right").spacesText(.caption, color: Spaces.Color.textTertiary)
        }
      }
      .padding(.horizontal, Spaces.Space.s + Spaces.Space.xxs)
      .frame(height: 24)
    }
  }
}
