import SwiftUI
import WisperKeyboard
import WisperUI

/// How to turn on the Open Wisper keyboard: the steps, a button to the right place in the
/// Settings app, a live check, and a field to try it in.
///
/// It is the last step of the first-run setup (`OnboardingFlow(practice:)`), so it brings
/// no page of its own. `KeyboardSetupScreen` shows the same thing as a page.
public struct KeyboardSetupStep: View {
  public init() {}

  public var body: some View {
    ScrollView {
      VStack(spacing: Wisper.Space.xl) {
        VStack(spacing: Wisper.Space.m) {
          Text("Add the Open Wisper keyboard")
            .wisperText(.hero)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
          Text("It puts a Dictate key and your latest text under your thumb in every app.")
            .wisperText(.body, color: Wisper.Color.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        KeyboardSetupGuide()
      }
      .padding(.horizontal, Wisper.Space.xl)
      .padding(.vertical, Wisper.Space.m)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
  }
}

/// The keyboard instructions as a page of the Library tab.
struct KeyboardSetupScreen: View {
  var body: some View {
    Page(title: "Keyboard", subtitle: "A Dictate key and your latest text, in every app.") {
      KeyboardSetupGuide()
    }
    .scrollDismissesKeyboard(.interactively)
  }
}

/// The instructions themselves, shared by the setup step and the Library page.
private struct KeyboardSetupGuide: View {
  @Environment(\.phoneDevice) private var device
  @Environment(\.scenePhase) private var scenePhase

  @State private var isOn: Bool?
  @State private var trial = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Wisper.Space.xl) {
      Card(padding: 0) {
        Step(1, "Open Settings", "The button below takes you to Open Wisper's page in the Settings app.")
        Hairline().padding(.horizontal, Wisper.Space.l)
        Step(2, "Tap Keyboards", "Turn on Open Wisper.")
        Hairline().padding(.horizontal, Wisper.Space.l)
        Step(
          3,
          "Turn on Allow Full Access",
          "The keyboard needs it to open this app to listen, and to read your latest text and snippets."
            + " It sends nothing anywhere."
        )
      }

      VStack(alignment: .leading, spacing: Wisper.Space.m) {
        Button {
          device.openSettings()
        } label: {
          Label("Open Settings", systemImage: "gear")
        }
        .buttonStyle(.wisper(.secondary, fullWidth: true))
        status
      }

      VStack(alignment: .leading, spacing: Wisper.Space.s) {
        WisperTextField(
          "Try it here",
          text: $trial,
          placeholder: "Tap here, then press the globe key"
        )
        Text(
          "No Keyboards row in Settings? Go to General, Keyboard, Keyboards, Add New Keyboard, and pick"
            + " Open Wisper."
        )
        .wisperText(.caption)
        .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: Wisper.Space.s) {
        SectionLabel("What it looks like")
        KeyboardPanel(model: .sample)
          .background(Wisper.Color.window, in: RoundedRectangle(cornerRadius: Wisper.Radius.card))
          .overlay {
            RoundedRectangle(cornerRadius: Wisper.Radius.card)
              .strokeBorder(Wisper.Color.border, lineWidth: Wisper.Stroke.hairline)
          }
          // A picture of the keyboard, not the keyboard.
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        Text(
          "iOS does not let a keyboard use the microphone. So the Dictate key opens this app to listen."
            + " Come back, and Insert latest types what you said."
        )
        .wisperText(.caption)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: scenePhase, initial: true) { isOn = device.keyboardIsOn() }
    .task {
      // The person turns the keyboard on in another app; notice when they are back.
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1.5))
        isOn = device.keyboardIsOn()
      }
    }
  }

  @ViewBuilder private var status: some View {
    switch isOn {
    case true?:
      HStack(spacing: Wisper.Space.s) {
        Badge("Keyboard is on", tone: .success)
        Text("Check that Allow Full Access is on too.")
          .wisperText(.caption)
      }
    case false?:
      HStack(spacing: Wisper.Space.s) {
        Badge("Not turned on yet", tone: .neutral)
        Text("This updates by itself.")
          .wisperText(.caption)
      }
    case nil:
      EmptyView()
    }
  }
}

/// One numbered instruction.
private struct Step: View {
  private let number: Int
  private let title: String
  private let detail: String
  /// The number's circle grows with the text, so a large digit still fits inside it.
  @ScaledMetric private var circle = Wisper.Space.xl

  init(_ number: Int, _ title: String, _ detail: String) {
    self.number = number
    self.title = title
    self.detail = detail
  }

  var body: some View {
    HStack(alignment: .top, spacing: Wisper.Space.m) {
      Text("\(number)")
        .wisperText(.captionStrong)
        .frame(width: circle, height: circle)
        .background(Wisper.Color.surfaceSelected, in: Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
        Text(title).wisperText(.bodyStrong)
        Text(detail)
          .wisperText(.caption)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Wisper.Space.l)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Step \(number). \(title). \(detail)")
  }
}
