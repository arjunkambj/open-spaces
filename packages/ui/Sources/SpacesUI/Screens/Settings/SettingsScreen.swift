import SpacesDomain
import SpacesEngine
import SwiftUI

/// Every setting, in sections. Reads `AppModel` from the environment.
///
/// It fills the card of the settings window: a navigation column on the left and the chosen
/// section on the right. Changes are saved as they are made.
/// - shortcuts: the Mac app's keyboard-shortcut editor, or `nil` to leave that section out.
/// - onClose: called by the close button; `nil` hides the button.
/// - appearance: a control the Mac app supplies for its own look, such as light or dark.
///   It is shown as a row of General, under "App". `nil` leaves the row out.
/// - pill: a row the Mac app supplies about its floating pill, such as putting it back in its
///   place. It is shown right under "Show the floating pill". `nil` leaves it out.
/// - section: the section to open on. `nil` opens General.
public struct SettingsScreen: View {
  private let shortcuts: AnyView?
  private let appearance: AnyView?
  private let pill: AnyView?
  private let onClose: (() -> Void)?
  private let preview: SettingsPreview

  @Environment(AppModel.self) private var model
  @State private var selection: SettingsSection
  @State private var dialog: SettingsDialog?

  public init(
    shortcuts: AnyView? = nil,
    onClose: (() -> Void)? = nil,
    appearance: AnyView? = nil,
    pill: AnyView? = nil,
    section: SettingsSection? = nil
  ) {
    self.init(
      shortcuts: shortcuts,
      onClose: onClose,
      appearance: appearance,
      pill: pill,
      preview: SettingsPreview(section: section)
    )
  }

  /// Opens on a given section and dialog, so snapshots can show each state.
  init(
    shortcuts: AnyView? = nil,
    onClose: (() -> Void)? = nil,
    appearance: AnyView? = nil,
    pill: AnyView? = nil,
    preview: SettingsPreview
  ) {
    self.shortcuts = shortcuts
    self.appearance = appearance
    self.pill = pill
    self.onClose = onClose
    self.preview = preview
    _selection = State(initialValue: preview.section ?? .general)
    _dialog = State(initialValue: preview.dialog)
  }

  public var body: some View {
    layout
      .modal(isPresented: isShowing(.apiKey)) {
        APIKeyDialog(preview: preview) { dialog = nil }
      }
      .modal(isPresented: isShowing(.claudeKey)) {
        ClaudeKeyDialog { dialog = nil }
      }
      .dialog(
        isPresented: isShowing(.removeClaudeKey),
        title: "Remove your Anthropic key?",
        subtitle: "Claude models stop working until you add a key again. OpenAI models keep working."
      ) {
        EmptyView()
      } footer: {
        Button("Cancel") { dialog = nil }.buttonStyle(.spaces()).keyboardShortcut(.defaultAction)
        Button("Remove key") {
          dialog = nil
          model.run { try await $0.removeClaudeKey() }
        }
        .buttonStyle(.spaces(.destructive))
      }
      .dialog(
        isPresented: isShowing(.removeKey),
        title: "Remove your OpenAI key?",
        subtitle: "Dictation and meeting notes stop working until you add a key again. Your history stays."
      ) {
        EmptyView()
      } footer: {
        // Return must never remove or delete: it presses Cancel.
        Button("Cancel") { dialog = nil }.buttonStyle(.spaces()).keyboardShortcut(.defaultAction)
        Button("Remove key") {
          dialog = nil
          model.run { try await $0.removeAPIKey() }
        }
        .buttonStyle(.spaces(.destructive))
      }
      .dialog(
        isPresented: isShowing(.deleteHistory),
        title: "Delete all dictation history?",
        subtitle: PrivacyCopy.deleteWarning(count: model.dictations.count)
      ) {
        EmptyView()
      } footer: {
        Button("Cancel") { dialog = nil }.buttonStyle(.spaces()).keyboardShortcut(.defaultAction)
        Button("Delete history") {
          dialog = nil
          model.run { try await $0.library.deleteAllDictations() }
        }
        .buttonStyle(.spaces(.destructive))
      }
  }

  private func isShowing(_ wanted: SettingsDialog) -> Binding<Bool> {
    Binding(
      get: { dialog == wanted },
      set: { shown in
        if !shown, dialog == wanted { dialog = nil }
      }
    )
  }

  // MARK: Layout

  private var layout: some View {
    HStack(spacing: 0) {
      navigation
        .frame(width: 220)
        .background(Spaces.Color.window)
      ScrollView {
        VStack(alignment: .leading, spacing: Spaces.Space.xl) {
          Text(selection.title)
            .spacesText(.pageTitle)
            .accessibilityAddTraits(.isHeader)
          content(for: selection)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spaces.Space.xxl)
      }
      .id(selection)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .topTrailing) {
        if let onClose {
          // Escape closes settings wherever the cursor is. While one of the dialogs above is
          // open this button is out of reach, so Escape closes that dialog first.
          IconButton("xmark", label: "Close settings", action: onClose)
            .keyboardShortcut(.cancelAction)
            .padding(Spaces.Space.xl)
        }
      }
    }
  }

  private var navigation: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
        ForEach(SettingsSection.Group.allCases) { group in
          // A gap, not a label, sets the groups apart.
          if group != SettingsSection.Group.allCases.first {
            SwiftUI.Color.clear.frame(height: Spaces.Space.l).accessibilityHidden(true)
          }
          ForEach(sections(in: group)) { section in
            NavItem(section.title, systemImage: section.systemImage, isSelected: section == selection) {
              selection = section
            }
          }
        }
      }
      .padding(Spaces.Space.m)
      .padding(.top, Spaces.Space.s)
    }
  }

  // MARK: Sections

  private func sections(in group: SettingsSection.Group) -> [SettingsSection] {
    SettingsSection.sections(in: group, hasShortcuts: shortcuts != nil)
  }

  private func open(_ section: SettingsSection) {
    selection = section
  }

  @ViewBuilder private func content(for section: SettingsSection) -> some View {
    switch section {
    case .general: GeneralSettings(appearance: appearance, pill: pill)
    case .shortcuts: if let shortcuts { shortcuts }
    case .meetings: MeetingSettingsSection(open: open)
    case .openAI: OpenAISettings(dialog: $dialog)
    case .agents: AgentSettings()
    case .privacy: PrivacySettings(dialog: $dialog)
    case .permissions: PermissionSettings()
    case .about: AboutSettings()
    }
  }
}

/// The dialogs the settings screen can show over itself.
enum SettingsDialog: Hashable, Sendable {
  case apiKey, removeKey, claudeKey, removeClaudeKey, deleteHistory
}

/// A starting state for the settings screen, for snapshots.
struct SettingsPreview {
  /// The section to show. `nil` is General.
  var section: SettingsSection?
  var dialog: SettingsDialog?
  /// What is already typed into the key dialog.
  var keyDraft = ""
  /// The error under the key field.
  var keyError: String?
}
