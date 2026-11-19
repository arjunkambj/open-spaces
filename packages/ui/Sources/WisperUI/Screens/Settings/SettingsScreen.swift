import SwiftUI
import WisperDomain
import WisperEngine

/// Every setting, in sections. Reads `AppModel` from the environment.
///
/// On a Mac it fills the card of the settings window: a navigation column on the left and
/// the chosen section on the right. On iPhone it is a list of sections; choosing one shows
/// that section with a back button. Changes are saved as they are made.
/// - shortcuts: the platform's keyboard-shortcut editor (macOS), or `nil` to leave that section out.
/// - onClose: called by the close button; `nil` hides the button.
/// - appearance: a control the platform supplies for its own look, such as light or dark (macOS).
///   It is shown as a row of General, under "App". `nil` leaves the row out.
public struct SettingsScreen: View {
  private let shortcuts: AnyView?
  private let appearance: AnyView?
  private let onClose: (() -> Void)?
  private let preview: SettingsPreview

  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom
  /// The section shown on a Mac.
  @State private var selection: SettingsSection
  /// The section opened on iPhone, or `nil` for the list.
  @State private var opened: SettingsSection?
  @State private var dialog: SettingsDialog?

  public init(shortcuts: AnyView? = nil, onClose: (() -> Void)? = nil, appearance: AnyView? = nil) {
    self.init(shortcuts: shortcuts, onClose: onClose, appearance: appearance, preview: SettingsPreview())
  }

  /// Opens on a given section and dialog, so snapshots can show each state.
  init(
    shortcuts: AnyView? = nil,
    onClose: (() -> Void)? = nil,
    appearance: AnyView? = nil,
    preview: SettingsPreview
  ) {
    self.shortcuts = shortcuts
    self.appearance = appearance
    self.onClose = onClose
    self.preview = preview
    _selection = State(initialValue: preview.section ?? .general)
    _opened = State(initialValue: preview.section)
    _dialog = State(initialValue: preview.dialog)
  }

  public var body: some View {
    Group {
      if idiom == .phone {
        phone
      } else {
        mac
      }
    }
    .modal(isPresented: isShowing(.apiKey)) {
      APIKeyDialog(preview: preview) { dialog = nil }
    }
    .dialog(
      isPresented: isShowing(.removeKey),
      title: "Remove your OpenAI key?",
      subtitle: "Dictation and meeting notes stop working until you add a key again. Your history stays."
    ) {
      EmptyView()
    } footer: {
      // Return must never remove or delete: it presses Cancel.
      Button("Cancel") { dialog = nil }.buttonStyle(.wisper()).keyboardShortcut(.defaultAction)
      Button("Remove key") {
        dialog = nil
        Task { await model.removeAPIKey() }
      }
      .buttonStyle(.wisper(.destructive))
    }
    .dialog(
      isPresented: isShowing(.deleteHistory),
      title: "Delete all dictation history?",
      subtitle: PrivacyCopy.deleteWarning(count: model.dictations.count)
    ) {
      EmptyView()
    } footer: {
      Button("Cancel") { dialog = nil }.buttonStyle(.wisper()).keyboardShortcut(.defaultAction)
      Button("Delete history") {
        dialog = nil
        model.run { try await $0.library.deleteAllDictations() }
      }
      .buttonStyle(.wisper(.destructive))
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

  // MARK: Mac

  private var mac: some View {
    HStack(spacing: 0) {
      navigation
        .frame(width: 220)
        .background(Wisper.Color.window)
      ScrollView {
        VStack(alignment: .leading, spacing: Wisper.Space.xl) {
          Text(selection.title)
            .wisperText(.pageTitle)
            .accessibilityAddTraits(.isHeader)
          content(for: selection)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Wisper.Space.xxl)
      }
      .id(selection)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .topTrailing) {
        if let onClose {
          // Escape closes settings wherever the cursor is. While one of the dialogs above is
          // open this button is out of reach, so Escape closes that dialog first.
          IconButton("xmark", label: "Close settings", action: onClose)
            .keyboardShortcut(.cancelAction)
            .padding(Wisper.Space.xl)
        }
      }
    }
  }

  private var navigation: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
        ForEach(SettingsSection.Group.allCases) { group in
          // A gap, not a label, sets the groups apart.
          if group != SettingsSection.Group.allCases.first {
            SwiftUI.Color.clear.frame(height: Wisper.Space.l).accessibilityHidden(true)
          }
          ForEach(sections(in: group)) { section in
            NavItem(section.title, systemImage: section.systemImage, isSelected: section == selection) {
              selection = section
            }
          }
        }
      }
      .padding(Wisper.Space.m)
      .padding(.top, Wisper.Space.s)
    }
  }

  // MARK: iPhone

  private var phone: some View {
    ZStack {
      if let opened {
        Page(title: opened.title) {
          content(for: opened)
        }
        .onBack { show(nil) }
        .transition(push(from: .trailing))
      } else {
        Page(title: "Settings") {
          if let onClose {
            IconButton("xmark", label: "Close settings", action: onClose)
          }
        } content: {
          ForEach(SettingsSection.Group.allCases) { group in
            sectionList(group)
          }
        }
        .transition(push(from: .leading))
      }
    }
  }

  private func sectionList(_ group: SettingsSection.Group) -> some View {
    CardList(sections(in: group), style: .filled) { section in
      ListRow(section.title) {
        Image(systemName: section.systemImage)
          .wisperText(.bodyStrong)
          .frame(width: Wisper.Space.xl)
          .accessibilityHidden(true)
      } trailing: {
        Image(systemName: "chevron.right")
          .wisperText(.captionStrong, color: Wisper.Color.textTertiary)
          .accessibilityHidden(true)
      }
      .onTap { show(section) }
    }
  }

  private func show(_ section: SettingsSection?) {
    withAnimation(Wisper.Motion.smooth) { opened = section }
  }

  private func push(from edge: Edge) -> AnyTransition {
    Wisper.Motion.reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
  }

  // MARK: Sections

  private func sections(in group: SettingsSection.Group) -> [SettingsSection] {
    SettingsSection.sections(in: group, hasShortcuts: shortcuts != nil)
  }

  private func open(_ section: SettingsSection) {
    selection = section
    if idiom == .phone { show(section) }
  }

  @ViewBuilder private func content(for section: SettingsSection) -> some View {
    switch section {
    case .general: GeneralSettings(appearance: appearance)
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
  case apiKey, removeKey, deleteHistory
}

/// A starting state for the settings screen, for snapshots.
struct SettingsPreview {
  /// The section to show. `nil` is General on a Mac and the list on iPhone.
  var section: SettingsSection?
  var dialog: SettingsDialog?
  /// What is already typed into the key dialog.
  var keyDraft = ""
  /// The error under the key field.
  var keyError: String?
}
