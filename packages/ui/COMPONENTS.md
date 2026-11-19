# WisperUI components

The one page to read before building a screen. Everything here is `public` in the module `WisperUI` and works on macOS 14.4+ and iOS 17+.

The look: warm, calm, paper-like. A warm off-white window, a slightly lighter content panel, warm-grey cards with hairline borders, no heavy shadows. Sans text (SF), serif (New York) only for stat numbers and hero headlines. Near-black primary buttons. One accent colour, a deep pine green, used sparingly. Dark mode is warm near-black.

## Rules

- **No literals in screens.** No `Color(...)`, `.font(.system(...))`, raw paddings or corner radii. Use `Wisper.Color`, `.wisperText`, `Wisper.Space`, `Wisper.Radius`. If a token is missing, add it to the kit, not to the screen.
- **Start every screen with `Page`.** It gives the title, the width, the scrolling and the paddings on both platforms.
- **Build from the kit.** A list is a `CardList` of `ListRow`s. A settings group is a `Card(padding: 0)` of `SettingRow`s and `ToggleRow`s. An empty list is an `EmptyState`. A form in a popup is a `.dialog`.
- **One primary button per screen or dialog.** Everything else is secondary, tertiary or ghost.
- **Accent is rare.** Links, a badge, a progress bar, the live waveform. Never large fills.
- **Never read the platform with `#if os(...)` for layout.** Read `@Environment(\.wisperIdiom)` (`.mac` or `.phone`). The snapshot tool sets it, which is how iPhone layouts are drawn on a Mac. Use `#if os(...)` only for APIs that do not exist on the other platform.
- **Every control needs a VoiceOver name.** The kit asks for one where it cannot guess it (`IconButton(label:)`, `Dropdown("…")`).
- **Text is plain English.** Short sentences, no jargon.

## Tokens

### Colours: `Wisper.Color.<name>`

Each is a SwiftUI `Color` that follows light and dark mode by itself.

| Name | Use |
| --- | --- |
| `window` | Behind everything; the sidebar sits on it |
| `panel` | The content panel; the page background on iPhone |
| `surface` | Cards and rows |
| `surfaceHover` | A row or control under the pointer |
| `surfaceSelected` | Selected item; fill of secondary buttons and key caps |
| `raised` | Fields, select boxes, dialogs |
| `border`, `borderStrong` | Hairlines; the border of fields and outline buttons |
| `textPrimary`, `textSecondary`, `textTertiary` | Text. Tertiary is for placeholders and timestamps, and only on window, panel, surface and raised |
| `inverse`, `onInverse` | Near-black fill (primary button, pill, toast) and the text on it. They swap in dark mode |
| `accent`, `onAccent` | The pine green and the text on it |
| `success`, `warning`, `danger`, `onDanger` | Signals. Readable as text on window, panel, surface and raised |
| `recording` | The red of a live recording. A fill, not a text colour |
| `scrim` | The dim layer behind a dialog |

```swift
Text("Saved").foregroundStyle(Wisper.Color.success)
RoundedRectangle(cornerRadius: Wisper.Radius.card).fill(Wisper.Color.surface)
```

### Text: `.wisperText(_ style:, color:)`

Sets font, letter spacing, case and colour. Sizes follow the idiom and Dynamic Type.

| Style | Mac / iPhone | Use |
| --- | --- | --- |
| `.pageTitle` | 28 semibold / 32 bold | Page titles (`Page` does this) |
| `.hero` | 32 / 30 serif | Hero headlines |
| `.statNumber` | 30 serif | Big numbers (`StatTile` does this) |
| `.cardTitle` | 17 / 18 semibold | Titles of cards and dialogs |
| `.body`, `.bodyStrong` | 15 / 17 | Reading text; row titles that matter |
| `.caption`, `.captionStrong` | 13 / 14 | Helper text (secondary colour); field labels |
| `.sectionLabel` | 12 / 13 uppercase, spaced | Labels above groups (`SectionLabel` does this) |
| `.mono` | 13 / 14 fixed-width | Paths, commands |
| `.keyCap` | 13 / 14 medium | Inside key caps |

```swift
Text("Hold fn and speak.").wisperText(.body)
Text("9:41 am").wisperText(.caption, color: Wisper.Color.textTertiary)
```

### Space, radius, stroke, motion

```swift
Wisper.Space.xxs / xs / s / m / l / xl / xxl / xxxl   // 2 4 8 12 16 24 32 48
Wisper.Radius.small / control / card / panel           // 6 10 14 20
Wisper.Stroke.hairline / focus                         // 1 1.5
Wisper.Motion.quick / smooth / spring                  // hover; in-screen moves; dialogs and the pill
```

`Wisper.Motion` presets turn into a short fade when Reduce Motion is on. `Wisper.Motion.reduceMotion` tells you if it is.

```swift
VStack(spacing: Wisper.Space.l) { ... }
withAnimation(Wisper.Motion.spring) { isOpen = true }
```

### Idiom

```swift
@Environment(\.wisperIdiom) private var idiom   // .mac or .phone
```

## Components

### Page

```swift
Page(title: String, subtitle: String? = nil, width: PageWidth = .regular,   // .regular 780, .wide 1080
     toolbar: () -> Toolbar = { EmptyView() }, content: () -> Content)
  .onBack { }      // optional back button

Page(title: "Dictionary", subtitle: "Words Open Wisper should know.") {
  Button("Add word") { adding = true }.buttonStyle(.wisper(.primary))
} content: {
  CardList(model.words) { word in ListRow(word.text) }
}
```

The content is a leading-aligned column with 24 points between children. It is at least as tall as the screen, so an `EmptyState` centres itself in what is left. On iPhone the page paints its own background; on a Mac the hub's panel is behind it.

### Sections, cards, rows

```swift
PageSection(_ title: String, content:, trailing: = EmptyView)   // SectionLabel + optional control + content
SectionLabel(_ text: String)
Card(_ style: CardStyle = .filled, padding: CGFloat = 20) { ... }   // .filled or .outlined
CardList(_ data, style: CardStyle = .outlined) { item in row }       // hairlines between rows, lazy
ListRow(_ title: String, subtitle: String? = nil, leading:, trailing:, hoverActions:)
  .onTap { }       // must come before other modifiers
Hairline()
```

```swift
PageSection("Today") {
  CardList(dictations, style: .filled) { dictation in
    ListRow(dictation.text) {
      Text(time(dictation)).wisperText(.caption, color: Wisper.Color.textTertiary)
    } hoverActions: {
      IconButton("doc.on.doc", label: "Copy") { copy(dictation) }
      OverflowMenu { Button("Delete", role: .destructive) { delete(dictation) } }
    }
    .onTap { open(dictation) }
    .lineLimit(1)
  }
} trailing: {
  SearchField(text: $query)
}
```

`hoverActions` show while the pointer is over the row on a Mac and always on iPhone. Use `.filled` cards for a few rows that read as one block, `.outlined` for long lists.

### Buttons

```swift
.buttonStyle(.wisper(_ kind: = .secondary, size: = .regular, fullWidth: = false))
// kind: .primary .secondary .tertiary .ghost .destructive     size: .regular .small
IconButton(_ systemName: String, label: String, size: = .regular) { }
OverflowMenu(label: String = "More") { Button(...) ... }      // the "…" button
NavItem(_ title: String, systemImage: String, isSelected: Bool, badge: String? = nil) { }
.hoverHighlight(radius: = Wisper.Radius.control, isSelected: = false)
```

```swift
Button("Add word") { save() }.buttonStyle(.wisper(.primary))
Button { start() } label: { Label("Start a meeting", systemImage: "record.circle") }.buttonStyle(.wisper())
Button("Continue") { next() }.buttonStyle(.wisper(.primary, fullWidth: true))   // bottom of an iPhone screen
```

`NavItem` is the entry of the hub sidebar and of the settings navigation. `hoverHighlight` gives any custom clickable thing the same hover and selected look.

### Settings

```swift
SettingRow(_ title: String, description: String? = nil) { control }
ToggleRow(_ title: String, description: String? = nil, isOn: Binding<Bool>)
.toggleStyle(.wisper)
Dropdown(_ label: String, selection: Binding<Value>, options: [Value]) { value in title }
```

```swift
PageSection("App") {
  Card(padding: 0) {
    ToggleRow("Open at login", isOn: $launch)
    Hairline().padding(.horizontal, 20)
    SettingRow("Theme") {
      Dropdown("Theme", selection: $theme, options: Theme.allCases) { $0.title }
    }
  }
}
```

### Tabs and badges

```swift
Tabs(selection: Binding<Value>, options: [Value], style: TabsStyle = .underline, title: (Value) -> String,
     trailing: = EmptyView)                      // style: .underline or .segmented
Badge(_ text: String, tone: = .neutral)          // .neutral .accent .success .warning .danger
```

```swift
Tabs(selection: $tab, options: Tab.allCases) { $0.title } trailing: { SearchField(text: $query) }
Tabs(selection: $view, options: [.notes, .transcript], style: .segmented) { $0.title }
```

Underline tabs go at the top of a page. Segmented tabs are for a choice inside a card or on iPhone.

### Fields

```swift
WisperTextField(_ label: String? = nil, text:, placeholder: = "", error: String? = nil, isSecure: = false)
WisperTextEditor(_ label: String? = nil, text:, placeholder: = "", error: String? = nil, height: = 96)
SearchField(text:, placeholder: = "Search")
```

```swift
WisperTextField("OpenAI API key", text: $key, placeholder: "sk-...", error: keyError, isSecure: true)
  .onSubmit { save() }
```

`error` shows red text under the field and a red border. `SearchField` is an icon that opens into a field on a Mac (Escape closes it) and a plain field on iPhone.

### Keys

```swift
KeyCap(_ label: String)
KeyCapRow(_ labels: [String])      // KeyCapRow(["fn", "Space"])
```

The row takes labels, not key codes; the Mac app turns a `KeyCombo` into labels. (It is called `KeyCapRow` because `KeyCombo` is a model in `WisperDomain`.)

### Empty states, stats, progress, notices

```swift
EmptyState(_ title: String, message: String? = nil, illustration:, action:)
SymbolTile(_ systemName: String, size: = 64, tint: = textPrimary)   // our simple illustration
HeroCard(_ title: String, message: String? = nil) { buttons }.onDismiss { }
StatTile(_ value: String, label: String, layout: = .inline)          // .inline or .stacked
ProgressBar(value: Double, tint: = accent)                           // 0...1
Banner(_ tone: NoticeTone = .info, title: String, message: String? = nil) { action }
Toast(_ message: String, tone: = .success)   and   .toast(_ toast: Binding<Toast?>)
```

```swift
EmptyState("No snippets yet", message: "Save text you type often.") {
  SymbolTile("text.quote")
} action: {
  Button("Add snippet") { adding = true }.buttonStyle(.wisper(.tertiary))
}

Banner(.warning, title: "No API key yet", message: "Add your OpenAI key to start dictating.") {
  Button("Add key") { openKey() }.buttonStyle(.wisper(.tertiary, size: .small))
}

@State private var toast: Toast?
content.toast($toast)          // then: toast = Toast("Copied")
```

`HeroCard` is the one loud, dark card with a serif headline at the top of a feature's screen. It is always dark, so `.primary` inside it is the light button. Use at most one per screen.

Show `AppModel.errorMessage` as a `Banner(.error, ...)` or a `Toast(..., tone: .error)`, and set it to `nil` afterwards.

### Dialogs

```swift
.dialog(isPresented:, title:, subtitle: nil, width: 480, content:, footer:)
.modal(isPresented:) { anyView.modalSurface() }
DialogCard(title:, subtitle:, width:, onClose:, content:, footer:)   // only for custom layouts
```

```swift
.dialog(isPresented: $adding, title: "Add a word", subtitle: "It will be spelled this way from now on.") {
  WisperTextField(text: $word, placeholder: "Word or name")
} footer: {
  Button("Cancel") { adding = false }.buttonStyle(.wisper())
  Button("Add word") { save() }.buttonStyle(.wisper(.primary)).disabled(word.isEmpty)
}
```

On a Mac the dialog is a centred card on a dimmed layer that covers **the view the modifier is attached to**. Attach it to the outermost view you own (the `Page`); the Mac app attaches window-wide ones, such as settings, to the hub root. Escape, the close button and a click on the dim area close it. On iPhone it is a native sheet. `.modal` is the same thing without the title and footer, for big custom content such as the settings window.

### Voice

```swift
Waveform(level: Double, bars: = 9, tint: = textPrimary, height: = 20)       // level 0...1
ProcessingIndicator(bars: = 5, tint: = textPrimary, height: = 20)
RecordButton(_ mode: RecordButton.Mode, diameter: = 80) { }   // .idle, .recording(level:), .processing
```

```swift
Waveform(level: Double(model.dictation.level), tint: Wisper.Color.accent, height: 40)
RecordButton(isRecording ? .recording(level: level) : .idle, diameter: 96) { toggle() }
```

Give `Waveform` the newest level each time it changes; it smooths the motion itself. On a dark pill use `tint: Wisper.Color.onInverse`.

### Brand

```swift
Wordmark(size: = 20)                         // mark + "Open Wisper"
WisperGlyph(size: = 20, tint: = textPrimary) // the mark alone
```

## Recipes

**A standard page**: `Page` → optional `Tabs` → optional `Banner` → `PageSection`s holding a `CardList` or `Card`.

**A list of rows**: `CardList(items) { ListRow(...) }`. When it is empty, show `EmptyState` instead of the list.

**A settings group**: `PageSection("Name") { Card(padding: 0) { rows with Hairline().padding(.horizontal, 20) between } }`.

**A side column on a Mac**: `Page(title:, width: .wide)` with an `HStack(alignment: .top, spacing: Wisper.Space.xl)` of the main column and a fixed-width `Card`. On `.phone`, stack them.

## Snapshots

A snapshot case is one screen state drawn to a PNG, in light and dark, at 2x. Add cases to `Screens/<Area>/<Area>Snapshots.swift`:

```swift
enum HomeSnapshots {
  @MainActor static var cases: [SnapshotCase] {
    [
      SnapshotCase("home") { HomeScreen() },
      SnapshotCase("home-phone", canvas: .phone) { HomeScreen() },
      SnapshotCase("home-empty", model: { .demo(hasAPIKey: false) }) { HomeScreen() },
    ]
  }
}
```

- `.mac` (880 x 720) is the hub's content area: panel background, Mac idiom.
- `.phone` (393 x 852) is an iPhone: phone idiom, with the safe areas of the status bar and home indicator.
- `.custom(width:height:)` is a bare canvas on the window background.
- The view gets a loaded `AppModel.demo()` in the environment. Pass `model:` for another starting state.

Run and look:

```bash
cd packages/ui
../../scripts/swiftw run --scratch-path .build-<yours> wisper-snapshots <dir> --only <name>
../../scripts/swiftw run --scratch-path .build-<yours> wisper-snapshots <dir> --list
```

Files are `<dir>/<name>-light.png` and `<dir>/<name>-dark.png`. `--only` takes part of a name (`--only home`). The component gallery is `--only kit-`; `kit-hub` and `kit-settings-sheet` show the kit put together. The tool shows no window and does not take focus.

What a snapshot cannot show: hover, focus and pressed looks (they need a pointer), open menus, and motion. Things drawn by the system outside the view, such as an open `Menu`, are not in the picture. `.blur` does not draw in a snapshot (materials may not either), so the kit avoids both; use gradients.

From Swift (the Mac app does this for its own cases):

```swift
try await SnapshotRenderer().render(cases, to: folder)             // light and dark files
let data = try await SnapshotRenderer().png(of: snapshot, scheme: .dark)
```
