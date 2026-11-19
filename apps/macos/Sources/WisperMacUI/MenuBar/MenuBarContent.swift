import AppKit
import SwiftUI
import WisperDomain
import WisperEngine
import WisperMac
import WisperUI

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
    /// Keep the resting pill out of sight for an hour, or bring it back.
    case hidePill
    case showPill
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
  public static func entries(for model: AppModel, microphones: [AudioDevice]) -> [MenuEntry] {
    let settings = model.settings
    var entries = [
      MenuEntry("Open Open Wisper", .action(.openHub)),
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
      .separator,
      MenuEntry(dictationHint(settings), .note),
      .separator,
      MenuEntry("Quit Open Wisper", .action(.quit), shortcut: KeyCombo(keyCode: 12, modifiers: [.command])),
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
    return [
      isHidden
        ? MenuEntry("Show the Pill Again", .action(.showPill))
        : MenuEntry("Hide for an Hour", .action(.hidePill)),
      MenuEntry("Settings…", .action(.openSettings)),
      .separator,
      MenuEntry("Microphone", .submenu(microphoneEntries(microphones, chosen: settings.microphoneID))),
      .separator,
      MenuEntry("Open Open Wisper", .action(.openHub)),
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
    case .toggleMeeting: controls.toggleMeeting()
    case .pasteLast: controls.pasteLast()
    case .pickMicrophone(let id): model.update { $0.microphoneID = id }
    case .hidePill: controls.hidePill(for: .seconds(3600))
    case .showPill: controls.hidePill(for: nil)
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

  static func dictationHint(_ settings: WisperDomain.Settings) -> String {
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
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.control, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
        row(entry)
      }
    }
    .padding(.vertical, Wisper.Space.xs + Wisper.Space.xxs)
    .frame(width: 290)
    .background {
      shape.fill(Wisper.Color.raised).shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }
    .overlay { shape.strokeBorder(Wisper.Color.border, lineWidth: Wisper.Stroke.hairline) }
  }

  @ViewBuilder private func row(_ entry: MenuEntry) -> some View {
    if entry.kind == .separator {
      Hairline().padding(.horizontal, Wisper.Space.m).padding(.vertical, Wisper.Space.xs)
    } else {
      HStack(spacing: Wisper.Space.s) {
        Image(systemName: "checkmark")
          .wisperText(.caption, color: Wisper.Color.textPrimary)
          .opacity(entry.isChecked ? 1 : 0)
          .frame(width: 12)
        Text(entry.title)
          .wisperText(
            .caption,
            color: entry.kind == .note ? Wisper.Color.textTertiary : Wisper.Color.textPrimary
          )
          .lineLimit(1)
        Spacer(minLength: Wisper.Space.l)
        if let shortcut = entry.shortcut {
          Text(shortcut.keyCaps.joined())
            .wisperText(.caption, color: Wisper.Color.textTertiary)
        }
        if case .submenu = entry.kind {
          Image(systemName: "chevron.right").wisperText(.caption, color: Wisper.Color.textTertiary)
        }
      }
      .padding(.horizontal, Wisper.Space.s + Wisper.Space.xxs)
      .frame(height: 24)
    }
  }
}
