import SwiftUI
import WisperDomain
import WisperEngine

/// First-run setup: name, OpenAI key, permissions, then the platform's practice step.
/// Calls `AppModel.finishOnboarding(userName:)` at the end. Reads `AppModel` from the environment.
/// - practice: a last step supplied by the platform (macOS: try the shortcut; iOS: turn on the keyboard).
public struct OnboardingFlow: View {
  private let practice: AnyView?
  private let steps: [OnboardingStep]

  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom

  @State private var step: OnboardingStep
  @State private var isMovingForward = true
  @State private var name = ""
  @State private var key: String
  @State private var keyError: String?
  @State private var isChecking: Bool
  @State private var usesServer: Bool
  @State private var server: String
  @State private var serverError: String?
  @State private var allAllowed = false
  @FocusState private var nameIsFocused: Bool

  public init(practice: AnyView? = nil) {
    self.init(practice: practice, preview: OnboardingPreview())
  }

  /// Opens on a given step and state, so snapshots can show each one.
  init(practice: AnyView? = nil, preview: OnboardingPreview) {
    self.practice = practice
    steps = OnboardingStep.steps(hasPractice: practice != nil)
    _step = State(initialValue: preview.step)
    _key = State(initialValue: preview.key)
    _keyError = State(initialValue: preview.keyError)
    _isChecking = State(initialValue: preview.isChecking)
    _usesServer = State(initialValue: preview.server != nil)
    _server = State(initialValue: preview.server ?? "")
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      ZStack {
        stepView
          .id(step)
          .transition(transition)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      footer
    }
    .background { Wisper.Color.panel.ignoresSafeArea() }
    .task {
      // Keep what is already known, e.g. when setup is run a second time.
      if name.isEmpty { name = model.settings.userName }
      if !usesServer, let address = model.settings.apiBaseURL {
        usesServer = true
        server = address
      }
    }
  }

  // MARK: Chrome

  private var header: some View {
    let canGoBack = step.previous(in: steps) != nil
    return ZStack {
      StepDots(count: steps.count, current: steps.firstIndex(of: step) ?? 0)
      HStack {
        IconButton("chevron.left", label: "Back", action: goBack)
          .opacity(canGoBack ? 1 : 0)
          .disabled(!canGoBack || isChecking)
          .accessibilityHidden(!canGoBack)
        Spacer()
      }
    }
    .padding(.horizontal, idiom == .phone ? Wisper.Space.s : Wisper.Space.l)
    .padding(.top, idiom == .phone ? Wisper.Space.xs : Wisper.Space.l)
  }

  private var footer: some View {
    Button(primaryTitle, action: advance)
      .buttonStyle(.wisper(.primary, fullWidth: true))
      .frame(maxWidth: idiom == .phone ? .infinity : OnboardingMetrics.buttonWidth)
      .disabled(!primaryIsEnabled)
      // Steps with a text field take Return themselves; the practice step may need every key.
      .keyboardShortcut(step == .welcome || step == .permissions || step == .done ? .defaultAction : nil)
      .padding(.horizontal, SetupMetrics.rowInset)
      .padding(.top, Wisper.Space.m)
      .padding(.bottom, idiom == .phone ? Wisper.Space.m : Wisper.Space.xxl)
  }

  private var transition: AnyTransition {
    guard !Wisper.Motion.reduceMotion else { return .opacity }
    let distance = isMovingForward ? Wisper.Space.xl : -Wisper.Space.xl
    return .asymmetric(
      insertion: .opacity.combined(with: .offset(x: distance)),
      removal: .opacity.combined(with: .offset(x: -distance))
    )
  }

  // MARK: Steps

  @ViewBuilder private var stepView: some View {
    switch step {
    case .welcome: welcome
    case .name: nameStep
    case .key: keyStep
    case .permissions: permissionsStep
    case .practice: if let practice { practice.frame(maxWidth: .infinity, maxHeight: .infinity) }
    case .done: doneStep
    }
  }

  private var welcome: some View {
    OnboardingPage(title: "Speak instead of typing, in any app.") {
      Wordmark(size: 22)
    } content: {
      VStack(alignment: .leading, spacing: Wisper.Space.l) {
        SetupFact(
          "text.cursor",
          title: "Works everywhere you type",
          detail: "Hold a key, speak, and clean text lands where your cursor is."
        )
        SetupFact(
          "record.circle",
          title: "Records and summarises meetings",
          detail: "Get a transcript, a summary and the action items."
        )
        SetupFact(
          "lock.shield",
          title: "Everything stays on your device",
          detail: "No account and no tracking. You bring your own OpenAI key."
        )
      }
      .frame(maxWidth: OnboardingMetrics.factsWidth)
    }
  }

  private var nameStep: some View {
    OnboardingPage(
      title: "What should we call you?",
      message: "Used to greet you, and so your name is spelled right when you dictate it."
    ) {
      WisperTextField(text: $name, placeholder: "Your name")
        .focused($nameIsFocused)
        .onSubmit(advance)
        #if os(iOS)
          .textInputAutocapitalization(.words)
          .textContentType(.givenName)
          .submitLabel(.continue)
        #endif
        .frame(maxWidth: OnboardingMetrics.fieldWidth)
        .onAppear { nameIsFocused = true }
    }
  }

  private var keyStep: some View {
    OnboardingPage(
      title: "Add your OpenAI key",
      message: OnboardingCopy.keyMessage(usesServer: usesServer)
    ) {
      VStack(alignment: .leading, spacing: Wisper.Space.l) {
        if model.hasAPIKey {
          Banner(
            .success,
            title: "A key is already saved",
            message: "Continue, or paste another key to replace it."
          )
        }
        APIKeyField(text: $key, error: keyError)
          .onSubmit(advance)
          .disabled(isChecking)
        if keyError != nil, usesServer, ServerAddress(server).address != nil {
          // A server of your own may not check keys at all, so a failed check must not trap anyone here.
          Button("Continue without a key") {
            key = ""
            submitKey()
          }
          .buttonStyle(.wisper(.tertiary, size: .small))
        }
        HStack(alignment: .firstTextBaseline, spacing: Wisper.Space.m) {
          SetupLink("Get a key", url: SetupLinks.openAIKeys)
          Spacer(minLength: Wisper.Space.s)
          Button {
            withAnimation(Wisper.Motion.smooth) { usesServer.toggle() }
            serverError = nil
          } label: {
            HStack(spacing: Wisper.Space.xs) {
              Text(usesServer ? "Use OpenAI instead" : "Use a custom server instead")
              Image(systemName: usesServer ? "chevron.up" : "chevron.down")
                .imageScale(.small)
                .accessibilityHidden(true)
            }
            .wisperText(.captionStrong, color: Wisper.Color.textSecondary)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        if usesServer {
          VStack(alignment: .leading, spacing: Wisper.Space.s) {
            WisperTextField(
              "Custom server address",
              text: $server,
              placeholder: "https://",
              error: serverError
            )
            .onSubmit(advance)
            #if os(iOS)
              .textInputAutocapitalization(.never)
              .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()
            Text(
              "For a proxy or a model server on your own machine that works like OpenAI. "
                + "It may not need a key."
            )
            .wisperText(.caption)
            .fixedSize(horizontal: false, vertical: true)
          }
          .transition(.opacity)
        }
      }
      .frame(maxWidth: OnboardingMetrics.formWidth)
      .onChange(of: key) { _, _ in keyError = nil }
      .onChange(of: server) { _, _ in serverError = nil }
    }
  }

  private var permissionsStep: some View {
    OnboardingPage(
      title: "Allow a few things",
      message: "You can skip any of these and allow it later in Settings."
    ) {
      PermissionsList(allAllowed: $allAllowed)
        .frame(maxWidth: OnboardingMetrics.listWidth)
    }
  }

  private var doneStep: some View {
    OnboardingPage(title: OnboardingCopy.allSetTitle(name: name)) {
      SymbolTile("checkmark", size: 56, tint: Wisper.Color.accent)
    } content: {
      VStack(alignment: .leading, spacing: Wisper.Space.l) {
        if idiom == .phone {
          SetupFact(
            "keyboard",
            title: "Dictate from the keyboard",
            detail: "In any app, switch to the Open Wisper keyboard, tap the microphone and speak."
          )
        } else {
          SetupFact(
            "keyboard",
            title: "Hold your shortcut and speak",
            detail: "Let go, and the text is typed where your cursor is."
          )
        }
        SetupFact(
          "record.circle",
          title: "Record a meeting",
          detail: "Start one from Meetings. The notes are written when it ends."
        )
        SetupFact(
          "character.book.closed",
          title: "Teach it your words",
          detail: "Add names and terms to the Dictionary so they are spelled your way."
        )
      }
      .frame(maxWidth: OnboardingMetrics.factsWidth)
    }
  }

  // MARK: Moving

  private var keyAction: KeyStepAction {
    KeyStepAction(
      key: key,
      hasSavedKey: model.hasAPIKey,
      usesServer: usesServer,
      server: ServerAddress(server)
    )
  }

  private var primaryTitle: String {
    switch step {
    case .welcome: "Get started"
    case .name, .practice: "Continue"
    case .key: isChecking ? "Checking…" : keyAction.buttonTitle
    case .permissions: OnboardingCopy.permissionsButton(allAllowed: allAllowed)
    case .done: "Start using Open Wisper"
    }
  }

  private var primaryIsEnabled: Bool {
    switch step {
    case .name: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .key: !isChecking && keyAction.isEnabled
    case .welcome, .permissions, .practice, .done: true
    }
  }

  private func advance() {
    guard primaryIsEnabled else { return }
    switch step {
    case .key: submitKey()
    case .done: model.finishOnboarding(userName: name)
    case .welcome, .name, .permissions, .practice: goForward()
    }
  }

  private func goForward() {
    guard let next = step.next(in: steps) else { return }
    isMovingForward = true
    withAnimation(Wisper.Motion.smooth) { step = next }
  }

  private func goBack() {
    guard let previous = step.previous(in: steps) else { return }
    isMovingForward = false
    withAnimation(Wisper.Motion.smooth) { step = previous }
  }

  private func submitKey() {
    let action = keyAction
    guard action != .fixServer else {
      serverError = ServerAddress.invalidMessage
      return
    }
    let address = usesServer ? ServerAddress(server).address : nil
    isChecking = true
    Task {
      defer { isChecking = false }
      // The server address has to be stored before the key is checked against it.
      if address != model.settings.apiBaseURL {
        let stored = await model.attempt { model in
          try await model.library.updateSettings { settings in settings.apiBaseURL = address }
        }
        guard stored else { return }
      }
      if action == .saveKey {
        do {
          try await model.saveAPIKey(key)
        } catch {
          keyError = APIKeyEntry.message(for: error)
          return
        }
      }
      goForward()
    }
  }
}

/// A starting state for the onboarding flow, for snapshots.
struct OnboardingPreview {
  var step = OnboardingStep.welcome
  var key = ""
  var keyError: String?
  var isChecking = false
  /// When set, the custom server part is open with this text in it.
  var server: String?
}

/// Sizes of the onboarding layout.
enum OnboardingMetrics {
  /// The widest a headline and its message get.
  static let textWidth: CGFloat = 460
  static let factsWidth: CGFloat = 400
  static let fieldWidth: CGFloat = 320
  static let formWidth: CGFloat = 440
  static let listWidth: CGFloat = 560
  /// The width of the main button on a Mac.
  static let buttonWidth: CGFloat = 280
}

/// One step: something small on top, a serif headline, a sentence, then the step's own content,
/// all centred. Scrolls when the content is taller than the window.
private struct OnboardingPage<Top: View, Content: View>: View {
  private let title: String
  private let message: String?
  private let top: Top
  private let content: Content

  @Environment(\.wisperIdiom) private var idiom

  init(
    title: String,
    message: String? = nil,
    @ViewBuilder top: () -> Top,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.message = message
    self.top = top()
    self.content = content()
  }

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: Wisper.Space.xxl) {
          VStack(spacing: Wisper.Space.l) {
            top
            Text(title)
              .wisperText(.hero)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityAddTraits(.isHeader)
            if let message {
              Text(message)
                .wisperText(.body, color: Wisper.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          .frame(maxWidth: OnboardingMetrics.textWidth)
          content
        }
        .padding(.horizontal, idiom == .phone ? SetupMetrics.rowInset : Wisper.Space.xxl)
        .padding(.vertical, Wisper.Space.m)
        .frame(maxWidth: .infinity)
        .frame(minHeight: proxy.size.height)
      }
      .scrollDismissesKeyboard(.interactively)
    }
  }
}

extension OnboardingPage where Top == EmptyView {
  init(title: String, message: String? = nil, @ViewBuilder content: () -> Content) {
    self.init(title: title, message: message, top: { EmptyView() }, content: content)
  }
}

/// The small row of dots that shows how far along the flow is.
private struct StepDots: View {
  let count: Int
  let current: Int

  var body: some View {
    HStack(spacing: Wisper.Space.xs) {
      ForEach(0..<count, id: \.self) { index in
        Capsule()
          .fill(index == current ? Wisper.Color.textPrimary : Wisper.Color.borderStrong)
          .frame(width: index == current ? Wisper.Space.xl : Wisper.Space.s, height: Wisper.Space.xs)
      }
    }
    .animation(Wisper.Motion.smooth, value: current)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Step \(current + 1) of \(count)")
  }
}
