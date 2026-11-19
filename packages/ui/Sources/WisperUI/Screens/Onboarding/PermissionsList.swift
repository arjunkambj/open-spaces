import SwiftUI
import WisperDomain
import WisperEngine

/// The system permissions Open Wisper needs on this device, each with a reason, its
/// status and a button to allow it. Reads `AppModel` from the environment.
///
/// The statuses are checked again about once a second while the list is on screen and
/// when the app comes back to the front, so a change made in System Settings shows up
/// by itself. Nothing here blocks: every permission can be left for later.
public struct PermissionsList: View {
  private let allAllowed: Binding<Bool>?

  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @State private var statuses: [Permission: PermissionStatus] = [:]
  @State private var asking: Permission?

  public init() {
    allAllowed = nil
  }

  /// - allAllowed: kept true while every needed permission is allowed.
  init(allAllowed: Binding<Bool>) {
    self.allAllowed = allAllowed
  }

  public var body: some View {
    let needed = model.permissions.needed
    Card(padding: 0) {
      ForEach(Array(needed.enumerated()), id: \.element) { index, permission in
        if index > 0 { SettingsDivider() }
        PermissionRow(
          permission: permission,
          status: statuses[permission] ?? model.permissions.status(permission),
          isAsking: asking == permission
        ) {
          request(permission)
        }
      }
    }
    .task {
      // The system tells nobody when a permission changes, so look again while visible.
      while !Task.isCancelled {
        refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { refresh() }
    }
  }

  private func refresh() {
    let permissions = model.permissions
    var fresh: [Permission: PermissionStatus] = [:]
    for permission in permissions.needed { fresh[permission] = permissions.status(permission) }
    if fresh != statuses { statuses = fresh }
    let everything = PermissionCopy.allAllowed(fresh)
    if let allAllowed, allAllowed.wrappedValue != everything { allAllowed.wrappedValue = everything }
  }

  private func request(_ permission: Permission) {
    guard asking == nil else { return }
    asking = permission
    Task {
      await model.permissions.request(permission)
      asking = nil
      refresh()
    }
  }
}

/// The words of the permissions list.
enum PermissionCopy {
  static func systemImage(_ permission: Permission) -> String {
    switch permission {
    case .microphone: "mic"
    case .accessibility: "keyboard"
    case .systemAudio: "speaker.wave.2"
    }
  }

  /// Why the permission is needed, in one line.
  static func reason(_ permission: Permission) -> String {
    switch permission {
    case .microphone: "To hear you."
    case .accessibility: "To type the text into the app you are using, and to notice the shortcut."
    case .systemAudio: "To capture the other people in a meeting."
    }
  }

  /// What does not work while the permission is missing.
  static func consequence(_ permission: Permission) -> String {
    switch permission {
    case .microphone: "Without it, dictation and meeting recording cannot work."
    case .accessibility: "Without it, Open Wisper cannot type for you or react to the shortcut."
    case .systemAudio: "Without it, meetings record only your own voice."
    }
  }

  static func badge(_ status: PermissionStatus) -> String {
    status == .granted ? "Allowed" : "Not allowed yet"
  }

  /// The label of the button, or `nil` when there is nothing left to do.
  static func action(_ status: PermissionStatus) -> String? {
    switch status {
    case .granted: nil
    case .notDetermined: "Allow"
    // The system asks only once. After a "no", the switch is in System Settings.
    case .denied: "Open Settings"
    }
  }

  static func allAllowed(_ statuses: [Permission: PermissionStatus]) -> Bool {
    statuses.values.allSatisfy { $0 == .granted }
  }
}

private struct PermissionRow: View {
  let permission: Permission
  let status: PermissionStatus
  let isAsking: Bool
  let request: () -> Void

  @Environment(\.wisperIdiom) private var idiom

  var body: some View {
    HStack(alignment: .top, spacing: Wisper.Space.m) {
      SymbolTile(PermissionCopy.systemImage(permission), size: 36)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Wisper.Space.s) {
        VStack(alignment: .leading, spacing: Wisper.Space.xs) {
          HStack(spacing: Wisper.Space.s) {
            Text(permission.label).wisperText(.bodyStrong)
            Badge(PermissionCopy.badge(status), tone: status == .granted ? .success : .warning)
          }
          Text(explanation)
            .wisperText(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        if idiom == .phone { button }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if idiom == .mac { button }
    }
    .padding(.horizontal, SetupMetrics.rowInset)
    .padding(.vertical, Wisper.Space.l)
  }

  private var explanation: String {
    status == .granted
      ? PermissionCopy.reason(permission)
      : PermissionCopy.reason(permission) + " " + PermissionCopy.consequence(permission)
  }

  @ViewBuilder private var button: some View {
    if let title = PermissionCopy.action(status) {
      Button(title, action: request)
        .buttonStyle(.wisper(.secondary, size: .small))
        .disabled(isAsking)
        .accessibilityLabel("\(title): \(permission.label)")
    }
  }
}
