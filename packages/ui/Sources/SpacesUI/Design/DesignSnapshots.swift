import SwiftUI

/// The component gallery: every token and component, as snapshot cases named `kit-*`.
enum DesignSnapshots {
  @MainActor static var cases: [SnapshotCase] {
    [
      SnapshotCase("kit-foundations", canvas: .custom(width: 880, height: 800)) { FoundationsGallery() },
      SnapshotCase("kit-controls", canvas: .custom(width: 880, height: 860)) { ControlsGallery() },
      SnapshotCase("kit-fields", canvas: .custom(width: 880, height: 620)) { FieldsGallery() },
      SnapshotCase("kit-page") { PageGallery() },
      SnapshotCase("kit-settings") { SettingsGallery() },
      SnapshotCase("kit-feedback") { FeedbackGallery() },
      SnapshotCase("kit-empty") { EmptyGallery() },
      SnapshotCase("kit-dialog") { DialogGallery() },
      SnapshotCase("kit-settings-sheet", canvas: .custom(width: 1180, height: 760)) {
        SettingsSheetGallery()
      },
      SnapshotCase("kit-voice", canvas: .custom(width: 880, height: 400)) { VoiceGallery() },
      SnapshotCase("kit-hub", canvas: .custom(width: 1180, height: 760)) { HubGallery() },
      SnapshotCase("kit-phone-page", canvas: .phone) { PhonePageGallery() },
      SnapshotCase("kit-phone-controls", canvas: .phone) { PhoneControlsGallery() },
      SnapshotCase("kit-phone-record", canvas: .phone) { PhoneRecordGallery() },
      SnapshotCase("kit-phone-dialog", canvas: .phone) { PhoneDialogGallery() },
    ]
  }
}

// MARK: - Sample content (made up)

private struct SampleRow: Identifiable {
  let id: Int
  let time: String
  let text: String
}

private let sampleRows = [
  SampleRow(id: 0, time: "9:41 am", text: "Let's move the design review to Thursday afternoon."),
  SampleRow(id: 1, time: "9:18 am", text: "Thanks for the notes. I will send the updated draft tonight."),
  SampleRow(id: 2, time: "8:52 am", text: "Remind me to book the train tickets for the offsite."),
  SampleRow(id: 3, time: "8:30 am", text: "The new onboarding copy reads well, ship it."),
]

private enum SampleTab: String, CaseIterable {
  case all = "All"
  case mine = "Added by you"
  case learned = "Learned"
}

private enum SampleTheme: String, CaseIterable {
  case system = "Match system"
  case light = "Light"
  case dark = "Dark"
}

// MARK: - Gallery scaffolding

private struct GalleryGroup<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.m) {
      SectionLabel(title)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct GallerySheet<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 28) { content }
      .padding(36)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Spaces.Color.panel)
  }
}

// MARK: - Foundations

private struct FoundationsGallery: View {
  private let surfaces: [(String, SwiftUI.Color)] = [
    ("window", Spaces.Color.window), ("panel", Spaces.Color.panel), ("surface", Spaces.Color.surface),
    ("surfaceHover", Spaces.Color.surfaceHover), ("surfaceSelected", Spaces.Color.surfaceSelected),
    ("raised", Spaces.Color.raised), ("inverse", Spaces.Color.inverse),
  ]
  private let signals: [(String, SwiftUI.Color)] = [
    ("accent", Spaces.Color.accent), ("success", Spaces.Color.success), ("warning", Spaces.Color.warning),
    ("danger", Spaces.Color.danger), ("recording", Spaces.Color.recording),
    ("textPrimary", Spaces.Color.textPrimary), ("textSecondary", Spaces.Color.textSecondary),
    ("textTertiary", Spaces.Color.textTertiary),
  ]

  var body: some View {
    GallerySheet {
      HStack(alignment: .center, spacing: Spaces.Space.xxl) {
        Wordmark(size: 28)
        Wordmark()
        SpacesGlyph(size: 36, tint: Spaces.Color.accent)
        SpacesGlyph(size: 20)
      }
      GalleryGroup(title: "Surfaces") { swatches(surfaces) }
      GalleryGroup(title: "Text and signals") { swatches(signals) }
      GalleryGroup(title: "Text styles") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Page title").spacesText(.pageTitle)
          Text("A calmer way to write").spacesText(.hero)
          HStack(alignment: .firstTextBaseline, spacing: Spaces.Space.xl) {
            Text("Card title").spacesText(.cardTitle)
            Text("Body strong").spacesText(.bodyStrong)
            Text("Body text").spacesText(.body)
          }
          HStack(alignment: .firstTextBaseline, spacing: Spaces.Space.xl) {
            Text("Caption for helper text").spacesText(.caption)
            Text("Caption strong").spacesText(.captionStrong)
            Text("Section label").spacesText(.sectionLabel)
            Text("~/Library/spaces").spacesText(.mono)
          }
        }
      }
      GalleryGroup(title: "Radius") {
        HStack(spacing: Spaces.Space.l) {
          radius("small 6", Spaces.Radius.small)
          radius("control 10", Spaces.Radius.control)
          radius("card 14", Spaces.Radius.card)
          radius("panel 20", Spaces.Radius.panel)
        }
      }
      GalleryGroup(title: "Space") {
        HStack(alignment: .bottom, spacing: Spaces.Space.l) {
          ForEach([2, 4, 8, 12, 16, 24, 32, 48], id: \.self) { value in
            VStack(spacing: 6) {
              Rectangle().fill(Spaces.Color.accent).frame(width: CGFloat(value), height: CGFloat(value))
              Text("\(value)").spacesText(.caption)
            }
          }
        }
      }
    }
  }

  private func swatches(_ items: [(String, SwiftUI.Color)]) -> some View {
    HStack(alignment: .top, spacing: Spaces.Space.m) {
      ForEach(items, id: \.0) { name, color in
        VStack(alignment: .leading, spacing: 6) {
          RoundedRectangle(cornerRadius: Spaces.Radius.control, style: .continuous)
            .fill(color)
            .frame(height: 48)
            .overlay {
              RoundedRectangle(cornerRadius: Spaces.Radius.control, style: .continuous)
                .strokeBorder(Spaces.Color.border, lineWidth: Spaces.Stroke.hairline)
            }
          Text(name).font(.system(size: 10.5)).foregroundStyle(Spaces.Color.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
      }
    }
  }

  private func radius(_ name: String, _ value: CGFloat) -> some View {
    Text(name)
      .spacesText(.caption)
      .frame(width: 120, height: 56)
      .background(Spaces.Color.surface, in: RoundedRectangle(cornerRadius: value, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: value, style: .continuous)
          .strokeBorder(Spaces.Color.borderStrong, lineWidth: Spaces.Stroke.hairline)
      }
  }
}

// MARK: - Controls

private struct ControlsGallery: View {
  @State private var on = true
  @State private var off = false
  @State private var theme = SampleTheme.system
  @State private var tab = SampleTab.all

  private let kinds: [(String, SpacesButtonStyle.Kind)] = [
    ("Primary", .primary), ("Secondary", .secondary), ("Tertiary", .tertiary), ("Ghost", .ghost),
    ("Delete", .destructive),
  ]

  var body: some View {
    GallerySheet {
      GalleryGroup(title: "Buttons: rest, hover, disabled, small") {
        VStack(alignment: .leading, spacing: Spaces.Space.m) {
          buttonRow(size: .regular)
          buttonRow(size: .regular).environment(\.simulatedHover, true)
          buttonRow(size: .regular).disabled(true)
          buttonRow(size: .small)
          HStack(spacing: Spaces.Space.s) {
            Button {
            } label: {
              Label("Start a meeting", systemImage: "record.circle")
            }
            .buttonStyle(.spaces(.secondary))
            Button {
            } label: {
              Label("Add word", systemImage: "plus")
            }
            .buttonStyle(.spaces(.primary))
          }
        }
      }
      GalleryGroup(title: "Icon buttons and the overflow menu") {
        HStack(spacing: Spaces.Space.s) {
          IconButton("play", label: "Play") {}
          IconButton("doc.on.doc", label: "Copy") {}
          IconButton("trash", label: "Delete") {}.environment(\.simulatedHover, true)
          IconButton("gearshape", label: "Settings") {}.disabled(true)
          IconButton("xmark", label: "Close", size: .small) {}
          OverflowMenu {
            Button("Copy") {}
            Button("Delete", role: .destructive) {}
          }
        }
      }
      GalleryGroup(title: "Switches, select box, badges, keys") {
        HStack(alignment: .center, spacing: Spaces.Space.xl) {
          Toggle("On", isOn: $on).toggleStyle(.spaces).labelsHidden().fixedSize()
          Toggle("Off", isOn: $off).toggleStyle(.spaces).labelsHidden().fixedSize()
          Toggle("Off", isOn: $off).toggleStyle(.spaces).labelsHidden().fixedSize().disabled(true)
          Dropdown("Theme", selection: $theme, options: SampleTheme.allCases) { $0.rawValue }
          HStack(spacing: 6) {
            Badge("Beta")
            Badge("New", tone: .accent)
            Badge("Ready", tone: .success)
            Badge("Needs key", tone: .warning)
            Badge("Failed", tone: .danger)
          }
        }
        HStack(spacing: Spaces.Space.xl) {
          KeyCap("fn")
          KeyCapRow(["fn", "Space"])
          KeyCapRow(["⌃", "⌥", "⌘", "M"])
          KeyCapRow(["Esc"])
        }
        .padding(.top, Spaces.Space.xs)
      }
      GalleryGroup(title: "Tabs") {
        Tabs(selection: $tab, options: SampleTab.allCases) {
          $0.rawValue
        } trailing: {
          IconButton("magnifyingglass", label: "Search") {}
          IconButton("arrow.up.arrow.down", label: "Sort") {}
        }
        Tabs(selection: $tab, options: SampleTab.allCases, style: .segmented) { $0.rawValue }
          .frame(width: 360)
          .padding(.top, Spaces.Space.s)
      }
      GalleryGroup(title: "Navigation items") {
        HStack(alignment: .top, spacing: Spaces.Space.l) {
          VStack(spacing: Spaces.Space.xxs) {
            NavItem("Home", systemImage: "house", isSelected: true) {}
            NavItem("Meetings", systemImage: "record.circle", isSelected: false, badge: "New") {}
            NavItem("Dictionary", systemImage: "character.book.closed", isSelected: false) {}
              .environment(\.simulatedHover, true)
          }
          .frame(width: 220)
          .padding(Spaces.Space.s)
          .background(Spaces.Color.window, in: RoundedRectangle(cornerRadius: Spaces.Radius.card))
        }
      }
    }
  }

  private func buttonRow(size: SpacesButtonStyle.Size) -> some View {
    HStack(spacing: Spaces.Space.s) {
      ForEach(kinds, id: \.0) { name, kind in
        Button(name) {}.buttonStyle(.spaces(kind, size: size))
      }
    }
  }
}

// MARK: - Fields

private struct FieldsGallery: View {
  @State private var empty = ""
  @State private var name = "Sam Rivera"
  @State private var key = "sk-not-a-real-key"
  @State private var bad = "sk"
  @State private var note = "Sign off with my first name only.\nKeep it short and friendly."
  @State private var query = "train"

  var body: some View {
    GallerySheet {
      HStack(alignment: .top, spacing: Spaces.Space.xl) {
        VStack(alignment: .leading, spacing: Spaces.Space.l) {
          SectionLabel("Text fields")
          SpacesTextField(text: $empty, placeholder: "Word or name")
          SpacesTextField("Your name", text: $name, placeholder: "What should we call you?")
            .environment(\.simulatedFocus, true)
          SpacesTextField("OpenAI API key", text: $key, placeholder: "sk-...", isSecure: true)
          SpacesTextField(
            "OpenAI API key",
            text: $bad,
            placeholder: "sk-...",
            error: "That key did not work. Check it and try again."
          )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: Spaces.Space.l) {
          SectionLabel("Text editor")
          SpacesTextEditor("Text to insert", text: $note, placeholder: "The text this snippet types")
          SpacesTextEditor(text: $empty, placeholder: "Write a note for the notes writer", height: 72)
          SectionLabel("Search: closed, open, with text")
          HStack(spacing: Spaces.Space.m) {
            SearchField(text: $empty)
            SearchField(text: $empty, placeholder: "Search words").environment(\.simulatedFocus, true)
          }
          SearchField(text: $query)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

// MARK: - Page, rows

private struct PageGallery: View {
  @State private var tab = SampleTab.all
  @State private var query = ""

  var body: some View {
    Page(title: "Dictionary", subtitle: "Names and terms Spaces should always spell your way.") {
      Button("Import") {}.buttonStyle(.spaces(.secondary))
      Button("Add word") {}.buttonStyle(.spaces(.primary))
    } content: {
      Tabs(selection: $tab, options: SampleTab.allCases) {
        $0.rawValue
      } trailing: {
        SearchField(text: $query)
      }
      PageSection("Today") {
        CardList(sampleRows) { row in
          ListRow(row.text) {
            Text(row.time)
              .spacesText(.caption, color: Spaces.Color.textTertiary)
              .frame(width: 64, alignment: .leading)
          } hoverActions: {
            IconButton("play", label: "Play") {}
            IconButton("doc.on.doc", label: "Copy") {}
            OverflowMenu { Button("Delete", role: .destructive) {} }
          }
          .onTap {}
          .lineLimit(1)
          .environment(\.simulatedHover, row.id == 1)
        }
      }
      CardList(sampleRows.prefix(2), style: .filled) { row in
        ListRow(row.text, subtitle: "Added \(row.time)") {
          SymbolTile("character.book.closed", size: 36)
        } trailing: {
          Badge("Learned", tone: .accent)
        }
      }
    }
  }
}

// MARK: - Settings rows

private struct SettingsGallery: View {
  @State private var launch = true
  @State private var sounds = false
  @State private var theme = SampleTheme.system

  var body: some View {
    Page(title: "General") {
      SettingsGroups()
    }
  }
}

private struct SettingsGroups: View {
  @State private var launch = true
  @State private var sounds = false
  @State private var theme = SampleTheme.system

  var body: some View {
    PageSection("Dictation") {
      Card(padding: 0) {
        SettingRow("Push to talk", description: "Hold to say something short.") {
          KeyCapRow(["fn"])
          Button("Change") {}.buttonStyle(.spaces(.tertiary, size: .small))
        }
        Hairline().padding(.horizontal, 20)
        SettingRow("Microphone", description: "Built-in microphone") {
          Button("Change") {}.buttonStyle(.spaces())
        }
        Hairline().padding(.horizontal, 20)
        SettingRow("Theme") {
          Dropdown("Theme", selection: $theme, options: SampleTheme.allCases) { $0.rawValue }
        }
      }
    }
    PageSection("App") {
      Card(padding: 0) {
        ToggleRow("Open at login", isOn: $launch)
        Hairline().padding(.horizontal, 20)
        ToggleRow(
          "Sounds",
          description: "Play a soft sound when dictation starts and stops.",
          isOn: $sounds
        )
      }
    }
  }
}

/// The settings window: a large modal over the hub with its own navigation.
private struct SettingsSheetGallery: View {
  @State private var isPresented = true

  var body: some View {
    HubGallery()
      .modal(isPresented: $isPresented) {
        HStack(spacing: 0) {
          VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
            SectionLabel("Settings")
              .padding(.horizontal, Spaces.Space.m)
              .padding(.bottom, Spaces.Space.s)
            NavItem("General", systemImage: "slider.horizontal.3", isSelected: true) {}
            NavItem("Shortcuts", systemImage: "keyboard", isSelected: false) {}
            NavItem("Meetings", systemImage: "record.circle", isSelected: false) {}
            SectionLabel("Your data")
              .padding(.horizontal, Spaces.Space.m)
              .padding(.top, Spaces.Space.xl)
              .padding(.bottom, Spaces.Space.s)
            NavItem("OpenAI key", systemImage: "key", isSelected: false) {}
            NavItem("Privacy", systemImage: "lock.shield", isSelected: false) {}
            Spacer()
            Text("Spaces 1.0")
              .spacesText(.caption)
              .padding(.horizontal, Spaces.Space.m)
          }
          .padding(Spaces.Space.m)
          .padding(.top, Spaces.Space.s)
          .frame(width: 220)
          .background(Spaces.Color.window)
          VStack(alignment: .leading, spacing: Spaces.Space.xl) {
            HStack {
              Text("General").spacesText(.pageTitle)
              Spacer()
              IconButton("xmark", label: "Close") {}
            }
            SettingsGroups()
            Spacer(minLength: 0)
          }
          .padding(Spaces.Space.xxl)
        }
        .frame(width: 860, height: 600)
        .modalSurface()
      }
  }
}

// MARK: - Feedback

private struct FeedbackGallery: View {
  var body: some View {
    GallerySheet {
      GalleryGroup(title: "Banners") {
        Banner(title: "Dictation works in every app", message: "Hold the key, speak, let go.")
        Banner(.warning, title: "No API key yet", message: "Add your OpenAI key to start dictating.") {
          Button("Add key") {}.buttonStyle(.spaces(.tertiary, size: .small))
        }
        Banner(.error, title: "Could not reach OpenAI", message: "Check your connection and try again.") {
          Button("Try again") {}.buttonStyle(.spaces(.tertiary, size: .small))
        }
        Banner(.success, title: "Microphone access is on")
      }
      GalleryGroup(title: "Progress") {
        VStack(alignment: .leading, spacing: Spaces.Space.l) {
          ProgressBar(value: 0.62)
          ProgressBar(value: 0.2, tint: Spaces.Color.textPrimary)
          ProgressBar(value: 0)
        }
        .frame(width: 320)
      }
      GalleryGroup(title: "Toasts") {
        HStack(spacing: Spaces.Space.m) {
          ToastView(toast: Toast("Copied"))
          ToastView(toast: Toast("Word added to your dictionary", tone: .info))
          ToastView(toast: Toast("Could not save the note", tone: .error))
        }
      }
    }
  }
}

private struct EmptyGallery: View {
  @State private var tab = SampleTab.all

  var body: some View {
    Page(title: "Meetings") {
      Button {
      } label: {
        Label("Start a meeting", systemImage: "record.circle")
      }
      .buttonStyle(.spaces(.primary))
    } content: {
      Tabs(selection: $tab, options: SampleTab.allCases) { $0.rawValue }
      EmptyState(
        "No meeting notes yet",
        message: "Record a meeting and Spaces writes the notes while you listen."
      ) {
        SymbolTile("waveform.and.mic")
      } action: {
        Button("Start a meeting") {}.buttonStyle(.spaces(.tertiary))
      }
    }
  }
}

// MARK: - Dialog

private struct DialogGallery: View {
  @State private var isPresented = true
  @State private var word = ""
  @State private var fix = false

  var body: some View {
    PageGallery()
      .dialog(
        isPresented: $isPresented,
        title: "Add a word",
        subtitle: "Spaces will spell it this way from now on."
      ) {
        SpacesTextField(text: $word, placeholder: "Word or name")
          .environment(\.simulatedFocus, true)
        Toggle(isOn: $fix) {
          Text("It is often heard as something else").spacesText(.body)
        }
        .toggleStyle(.spaces)
      } footer: {
        Button("Cancel") {}.buttonStyle(.spaces())
        Button("Add word") {}.buttonStyle(.spaces(.primary)).keyboardShortcut(.defaultAction).disabled(true)
      }
  }
}

// MARK: - Voice

private struct VoiceGallery: View {
  var body: some View {
    GallerySheet {
      GalleryGroup(title: "Waveform: silence, quiet, speaking, loud; then working") {
        HStack(spacing: Spaces.Space.xxl) {
          Waveform(level: 0)
          Waveform(level: 0.2)
          Waveform(level: 0.6)
          Waveform(level: 1)
          Waveform(level: 0.7, bars: 21, tint: Spaces.Color.accent, height: 40)
          ProcessingIndicator()
        }
      }
      GalleryGroup(title: "On the floating pill") {
        HStack(spacing: Spaces.Space.xl) {
          pill { SpacesGlyph(size: 14, tint: Spaces.Color.onInverse).opacity(0.7) }
          pill { Waveform(level: 0.65, bars: 11, tint: Spaces.Color.onInverse, height: 18) }
          pill { ProcessingIndicator(tint: Spaces.Color.onInverse, height: 18) }
        }
      }
      GalleryGroup(title: "Record button: ready, recording, working") {
        HStack(spacing: Spaces.Space.xl) {
          RecordButton(.idle) {}
          RecordButton(.recording(level: 0.25)) {}
          RecordButton(.recording(level: 0.9)) {}
          RecordButton(.processing) {}
          RecordButton(.idle, diameter: 56) {}
        }
      }
    }
  }

  private func pill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .frame(minWidth: 72, minHeight: 34)
      .padding(.horizontal, Spaces.Space.m)
      .background(Spaces.Color.inverse, in: Capsule())
  }
}

// MARK: - The hub, put together

private struct HubGallery: View {
  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 228)
      Rectangle().fill(Spaces.Color.border).frame(width: Spaces.Stroke.hairline)
      content.background(Spaces.Color.panel)
    }
    .background(Spaces.Color.window)
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
      Wordmark()
        .padding(.horizontal, Spaces.Space.m)
        .padding(.top, 44)
        .padding(.bottom, Spaces.Space.xl)
      NavItem("Home", systemImage: "house", isSelected: true) {}
      NavItem("Meetings", systemImage: "record.circle", isSelected: false, badge: "Live") {}
      NavItem("Dictionary", systemImage: "character.book.closed", isSelected: false) {}
      NavItem("Snippets", systemImage: "text.quote", isSelected: false) {}
      NavItem("Style", systemImage: "textformat", isSelected: false) {}
      Spacer()
      NavItem("Settings", systemImage: "gearshape", isSelected: false) {}
    }
    .padding(.horizontal, Spaces.Space.m)
    .padding(.bottom, Spaces.Space.m)
  }

  private var content: some View {
    Page(title: "Home", subtitle: "12,480 words dictated · 148 words a minute") {
      IconButton("magnifyingglass", label: "Search") {}
    } content: {
      PageSection("Today") {
        CardList(sampleRows) { row in
          ListRow(row.text) {
            Text(row.time)
              .spacesText(.caption, color: Spaces.Color.textTertiary)
              .frame(width: 64, alignment: .leading)
          } hoverActions: {
            IconButton("doc.on.doc", label: "Copy") {}
            OverflowMenu { Button("Delete", role: .destructive) {} }
          }
          .onTap {}
          .lineLimit(1)
          .environment(\.simulatedHover, row.id == 0)
        }
      }
    }
  }
}

// MARK: - iPhone

private struct PhonePageGallery: View {
  @State private var query = ""
  @State private var tab = SampleTab.all

  var body: some View {
    Page(title: "Dictionary", subtitle: "Words Spaces should spell your way.") {
      IconButton("plus", label: "Add word") {}
    } content: {
      SearchField(text: $query, placeholder: "Search words")
      Tabs(selection: $tab, options: SampleTab.allCases, style: .segmented) { $0.rawValue }
      Banner(.warning, title: "No API key yet", message: "Add your OpenAI key to start dictating.") {
        Button("Add key") {}.buttonStyle(.spaces(.tertiary, size: .small))
      }
      PageSection("Today") {
        CardList(sampleRows.prefix(3)) { row in
          ListRow(row.text, subtitle: row.time) {
          } hoverActions: {
            OverflowMenu { Button("Delete", role: .destructive) {} }
          }
          .onTap {}
          .lineLimit(2)
        }
      }
    }
  }
}

private struct PhoneControlsGallery: View {
  @State private var name = "Sam"
  @State private var key = ""
  @State private var on = true
  @State private var off = false
  @State private var theme = SampleTheme.system

  var body: some View {
    Page(title: "Settings") {
      SpacesTextField("Your name", text: $name, placeholder: "What should we call you?")
      SpacesTextField(
        "OpenAI API key",
        text: $key,
        placeholder: "sk-...",
        error: "Paste your key to continue."
      )
      Card(padding: 0) {
        ToggleRow("Sounds", description: "Play a soft sound when dictation starts.", isOn: $on)
        Hairline().padding(.horizontal, 20)
        ToggleRow("Keep audio", isOn: $off)
        Hairline().padding(.horizontal, 20)
        SettingRow("Theme") {
          Dropdown("Theme", selection: $theme, options: SampleTheme.allCases) { $0.rawValue }
        }
      }
      VStack(spacing: Spaces.Space.s) {
        Button("Continue") {}.buttonStyle(.spaces(.primary, fullWidth: true))
        Button("Not now") {}.buttonStyle(.spaces(.ghost, fullWidth: true))
      }
    }
    .onBack {}
  }
}

private struct PhoneRecordGallery: View {
  var body: some View {
    VStack(spacing: Spaces.Space.xl) {
      Wordmark(size: 22)
        .padding(.top, Spaces.Space.xl)
      Spacer()
      Text("Listening").spacesText(.hero)
      Text("Say what you want to write.").spacesText(.body, color: Spaces.Color.textSecondary)
      Waveform(level: 0.7, bars: 25, tint: Spaces.Color.accent, height: 56)
        .padding(.vertical, Spaces.Space.l)
      Spacer()
      RecordButton(.recording(level: 0.7), diameter: 96) {}
      HStack(spacing: Spaces.Space.xxxl) {
        RecordButton(.idle, diameter: 56) {}
        RecordButton(.processing, diameter: 56) {}
      }
      .padding(.bottom, Spaces.Space.l)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct PhoneDialogGallery: View {
  @State private var isPresented = true
  @State private var word = ""

  var body: some View {
    PhonePageGallery()
      .dialog(
        isPresented: $isPresented,
        title: "Add a word",
        subtitle: "Spaces will spell it this way from now on."
      ) {
        SpacesTextField(text: $word, placeholder: "Word or name")
      } footer: {
        Button("Add word") {}.buttonStyle(.spaces(.primary, fullWidth: true))
      }
  }
}
