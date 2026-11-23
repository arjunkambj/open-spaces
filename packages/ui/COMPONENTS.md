# SpacesUI components

The one page to read before building a screen. Everything here is `public` in the module `SpacesUI` and works on macOS 14.4+.

The look: black and white, calm, with plenty of room. The greys are one neutral ramp with no hue (the steps are listed in `Design/Colors.swift`): a light grey window, a white page, and as few boxes as possible: lists sit right on the page with hairlines between their rows, and only groups of settings and things that are live get a soft grey fill. One type voice, the system sans (SF), with size, weight and space doing the work that colour and borders would. Headings are semibold, never bold. Buttons are capsules; the primary one is near-black (white in dark mode). There is no brand colour: the "accent" is that same ink. Red is kept for errors, deleting and a live recording. Dark mode is near-black.

## Rules

- **No literals in screens.** No `Color(...)`, `.font(.system(...))`, raw paddings or corner radii. Use `Spaces.Color`, `.spacesText`, `Spaces.Space`, `Spaces.Radius`. If a token is missing, add it to the kit, not to the screen.
- **Start every screen with `Page`.** It gives the title, the width, the scrolling and the paddings.
- **Build from the kit.** A list is a `CardList` of `ListRow`s. A settings group is a `Card(padding: 0)` of `SettingRow`s and `ToggleRow`s. An empty list is an `EmptyState`. A form in a popup is a `.dialog`.
- **A box needs a reason.** Never a fill and a border together. Content lists are plain (no box). A fill groups settings or marks something live. A border is for things you type or choose in, and for the one item set apart on a page.
- **Nothing that sells.** No banners that introduce a feature, no numbers shown off, no tips that must be dismissed. Say how a thing works in the empty state, or in one quiet line under the title.
- **One primary button per screen or dialog.** Everything else is secondary, tertiary or ghost.
- **Ink, not colour.** `accent` is black (white in dark mode). Show what is chosen or live with ink, weight or a fill, never with a hue. Red only for errors, deleting and recording.
- **Every control needs a VoiceOver name.** The kit asks for one where it cannot guess it (`IconButton(label:)`, `Dropdown("…")`).
- **Text is plain English.** Short sentences, no jargon.

## Tokens

### Colours: `Spaces.Color.<name>`

Each is a SwiftUI `Color` that follows light and dark mode by itself.

| Name | Use |
| --- | --- |
| `window` | Behind everything; the sidebar sits on it |
| `panel` | The content panel |
| `surface` | Cards and rows |
| `surfaceHover` | A row or control under the pointer |
| `surfaceSelected` | Selected item; fill of secondary buttons and key caps |
| `raised` | Fields, select boxes, dialogs |
| `border`, `borderStrong` | Hairlines; the border of fields and outline buttons |
| `textPrimary`, `textSecondary`, `textTertiary` | Text. Tertiary is for placeholders and timestamps, on window, panel and raised; on a card prefer secondary |
| `inverse`, `onInverse` | Near-black fill (primary button, pill, toast) and the text on it. They swap in dark mode |
| `accent`, `onAccent` | The same ink as `inverse`: what is chosen or live (a selected option, a badge, the live waveform) |
| `success`, `warning` | Ink too. The symbol beside them (a check, a warning sign) carries the meaning |
| `danger`, `onDanger` | The red of errors and destructive actions, and the text on it |
| `recording` | The red of a live recording. A fill, not a text colour |
| `scrim` | The dim layer behind a dialog |

```swift
Text("Saved").foregroundStyle(Spaces.Color.success)
RoundedRectangle(cornerRadius: Spaces.Radius.card).fill(Spaces.Color.surface)
```

### Text: `.spacesText(_ style:, color:)`

Sets font, letter spacing and colour. Every style is the system sans; only `.mono` is fixed-width. Sizes follow Dynamic Type. Body text gets about 20 points of line.

| Style | Size | Use |
| --- | --- | --- |
| `.pageTitle` | 24 semibold | Page titles (`Page` does this) |
| `.hero` | 32 semibold | The headline of a first-run step |
| `.cardTitle` | 16 semibold | Titles of cards and dialogs |
| `.body`, `.bodyStrong` | 14, regular and medium | Reading text; row titles that matter |
| `.caption`, `.captionStrong` | 12 | Helper text (secondary colour); field labels |
| `.sectionLabel` | 12 medium, secondary colour | Labels above groups (`SectionLabel` does this) |
| `.mono` | 12.5 fixed-width | Paths, commands |
| `.keyCap` | 12 medium | Inside key caps |
| `.nav`, `.navStrong` | 13 | Sidebar and settings navigation entries (strong for the chosen one) |

```swift
Text("Hold fn and speak.").spacesText(.body)
Text("9:41 am").spacesText(.caption, color: Spaces.Color.textTertiary)
```

### Space, radius, stroke, motion

```swift
Spaces.Space.xxs / xs / s / m / l / xl / xxl / xxxl   // 2 4 8 12 16 24 32 48
Spaces.Radius.small / control / card / panel           // 6 10 16 24 (buttons are capsules)
Spaces.Stroke.hairline / focus                         // 1 1.5
Spaces.Motion.quick / smooth / spring                  // hover; in-screen moves; dialogs and the pill
```

`Spaces.Motion` presets turn into a short fade when Reduce Motion is on. `Spaces.Motion.reduceMotion` tells you if it is.

```swift
VStack(spacing: Spaces.Space.l) { ... }
withAnimation(Spaces.Motion.spring) { isOpen = true }
```

## Components

### Page

```swift
Page(title: String, subtitle: String? = nil, width: PageWidth = .regular,   // .regular 780, .wide 1080
     toolbar: () -> Toolbar = { EmptyView() }, content: () -> Content)
  .onBack { }                    // optional back button
  .titleAccessory { anyView }    // a line under the title that needs more than text, e.g. key caps

Page(title: "Dictionary", subtitle: "Words Spaces should know.") {
  Button("Add word") { adding = true }.buttonStyle(.spaces(.primary))
} content: {
  CardList(model.words) { word in ListRow(word.text) }
}
```

The content is a leading-aligned column with 32 points between children, inside 48-point side margins. It is at least as tall as the screen, so an `EmptyState` centres itself in what is left. The hub's panel is behind it.

### Sections, cards, rows

```swift
PageSection(_ title: String, content:, trailing: = EmptyView)   // SectionLabel + optional control + content
SectionLabel(_ text: String)
Card(_ style: CardStyle = .filled, padding: CGFloat = 24) { ... }   // .filled or .outlined
CardList(_ data, style: CardStyle = .plain) { item in row }          // hairlines between rows, lazy
ListRow(_ title: String, subtitle: String? = nil, leading:, trailing:, hoverActions:)
  .onTap { }       // must come before other modifiers
Hairline()
```

```swift
PageSection("Today") {
  CardList(dictations) { dictation in
    ListRow(dictation.text) {
      Text(time(dictation)).spacesText(.caption, color: Spaces.Color.textTertiary)
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

`hoverActions` show while the pointer is over the row, and while the keyboard is on the row or on one of the actions. A row you draw yourself must do the same: Tab reaches an action even while it is unseen, so show the actions when one of them has focus (`.focused` on the group of actions).

The three styles:

- `.plain` (the default for `CardList`): no box. Rows line up with the page title, and the hover fill is a rounded shape that reaches a little into the page margin. For every list of content: dictations, meetings, words, snippets.
- `.filled`: a light grey fill, no border. For a group of settings, a short menu of places, or something live (the recording card).
- `.outlined`: a hairline border, no fill. For one thing set apart on a page, such as an answer.

A row you draw yourself ends with `.rowChrome(isHighlighted:)` (after its vertical padding) instead of its own side padding and hover background. That gives it the right inset and hover shape in whichever list it is put.

### Buttons

```swift
.buttonStyle(.spaces(_ kind: = .secondary, size: = .regular, fullWidth: = false))
// kind: .primary .secondary .tertiary .ghost .destructive     size: .regular .small
IconButton(_ systemName: String, label: String, size: = .regular) { }
OverflowMenu(label: String = "More") { Button(...) ... }      // the "…" button
NavItem(_ title: String, systemImage: String, isSelected: Bool, badge: String? = nil) { }
.hoverHighlight(radius: = Spaces.Radius.control, isSelected: = false)
```

```swift
Button("Add word") { save() }.buttonStyle(.spaces(.primary))
Button { start() } label: { Label("Start a meeting", systemImage: "record.circle") }.buttonStyle(.spaces())
Button("Continue") { next() }.buttonStyle(.spaces(.primary, fullWidth: true))   // the width it is given
```

Every button is a capsule: 36 points tall (28 small). Primary is solid ink, secondary a grey fill, tertiary an outline, ghost text only, destructive red. `IconButton` is a round spot that fills grey under the pointer.

`NavItem` is the entry of the hub sidebar and of the settings navigation. `hoverHighlight` gives any custom clickable thing the same hover and selected look.

### Settings

```swift
SettingRow(_ title: String, description: String? = nil) { control }
ToggleRow(_ title: String, description: String? = nil, isOn: Binding<Bool>)
.toggleStyle(.spaces)
Dropdown(_ label: String, selection: Binding<Value>, options: [Value]) { value in title }
```

```swift
PageSection("App") {
  Card(padding: 0) {
    ToggleRow("Open at login", isOn: $launch)
    Hairline().padding(.horizontal, Spaces.Space.xl)
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
// .accent is solid ink, .warning an outline, .danger red; .neutral and .success a quiet grey
```

```swift
Tabs(selection: $tab, options: Tab.allCases) { $0.title } trailing: { SearchField(text: $query) }
Tabs(selection: $view, options: [.notes, .transcript], style: .segmented) { $0.title }
```

Underline tabs go at the top of a page. Segmented tabs are for a choice inside a card.

### Fields

```swift
SpacesTextField(_ label: String? = nil, text:, placeholder: = "", error: String? = nil, isSecure: = false,
                focusOnAppear: = false)
SpacesTextEditor(_ label: String? = nil, text:, placeholder: = "", error: String? = nil, height: = 96)
SearchField(text:, placeholder: = "Search")
```

```swift
SpacesTextField("OpenAI API key", text: $key, placeholder: "sk-...", error: keyError, isSecure: true)
  .onSubmit { save() }
```

`error` shows red text under the field and a red border. `focusOnAppear: true` puts the cursor in the field when it shows: give it to the first field of a dialog. `SearchField` is an icon that opens into a field (Escape closes it).

### Keys

```swift
KeyCap(_ label: String)
KeyCapRow(_ labels: [String])      // KeyCapRow(["fn", "Space"])
```

The row takes labels, not key codes; the Mac app turns a `KeyCombo` into labels. (It is called `KeyCapRow` because `KeyCombo` is a model in `SpacesDomain`.)

### Empty states, stats, progress, notices

```swift
EmptyState(_ title: String, message: String? = nil, illustration:, action:)
SymbolTile(_ systemName: String, size: = 64, tint: = textSecondary) // one quiet symbol, no box
ProgressBar(value: Double, tint: = accent)                           // 0...1
Banner(_ tone: NoticeTone = .info, title: String, message: String? = nil) { action }
Toast(_ message: String, tone: = .success)   and   .toast(_ toast: Binding<Toast?>)
```

```swift
EmptyState("No snippets yet", message: "Save text you type often.") {
  SymbolTile("text.quote")
} action: {
  Button("Add snippet") { adding = true }.buttonStyle(.spaces(.tertiary))
}

Banner(.warning, title: "No API key yet", message: "Add your OpenAI key to start dictating.") {
  Button("Add key") { openKey() }.buttonStyle(.spaces(.tertiary, size: .small))
}

@State private var toast: Toast?
content.toast($toast)          // then: toast = Toast("Copied")
```

A `Banner` is a soft grey fill with no border; an error one is faintly red. The symbol tells the tones apart. Use one only for something the person must act on or know now (a missing key, a permission, an error), never to introduce a feature.

Show `AppModel.errorMessage` as a `Banner(.error, ...)` or a `Toast(..., tone: .error)`, and set it to `nil` afterwards.

### Dialogs

```swift
.dialog(isPresented:, title:, subtitle: nil, width: 480, content:, footer:)
.modal(isPresented:) { anyView.modalSurface() }
DialogCard(title:, subtitle:, width:, onClose:, content:, footer:)   // only for custom layouts
```

```swift
.dialog(isPresented: $adding, title: "Add a word", subtitle: "It will be spelled this way from now on.") {
  SpacesTextField(text: $word, placeholder: "Word or name", focusOnAppear: true)
} footer: {
  Button("Cancel") { adding = false }.buttonStyle(.spaces())
  Button("Add word") { save() }.buttonStyle(.spaces(.primary)).keyboardShortcut(.defaultAction)
    .disabled(word.isEmpty)
}
```

Keys in a dialog:

- **Escape** presses the close button. `DialogCard` gives it `.cancelAction`; do not give a footer button that shortcut too.
- **Return** presses the button you give `.keyboardShortcut(.defaultAction)`. That is the primary button. When the other button deletes or removes something, give it to **Cancel** instead: Return must never delete.
- A field's `.onSubmit` and the default button can both fire for one Return. Make the action safe to run twice (`guard isAdding else { return }`).
- The first text field takes `focusOnAppear: true`, so typing can start at once.

While a dialog or modal is open on a Mac, the view under it is disabled and hidden from VoiceOver: Tab and the pointer stay inside the dialog.

The dialog is a centred card on a dimmed layer that covers **the view the modifier is attached to**. Attach it to the outermost view you own (the `Page`); the Mac app attaches window-wide ones, such as settings, to the hub root. Escape, the close button and a click on the dim area close it. `.modal` is the same thing without the title and footer, for big custom content such as the settings window.

### Voice

```swift
Waveform(level: Double, bars: = 9, tint: = textPrimary, height: = 20, axis: = .horizontal)   // level 0...1
ProcessingIndicator(bars: = 5, tint: = textPrimary, height: = 20, axis: = .horizontal)
RecordButton(_ mode: RecordButton.Mode, diameter: = 80) { }   // .idle, .recording(level:), .processing
```

```swift
Waveform(level: Double(model.dictation.level), height: 40)
RecordButton(isRecording ? .recording(level: level) : .idle, diameter: 96) { toggle() }
```

Give `Waveform` the newest level each time it changes; it smooths the motion itself. On a dark pill use `tint: Spaces.Color.onInverse`. With `axis: .vertical` the bars lie on their side, one under the other, for a tall thin place (the pill at the side of a screen); `height` is then how wide the row is.

### Brand

```swift
Wordmark(size: = 20)                         // mark + "Spaces", in semibold SF
SpacesGlyph(size: = 20, tint: = textPrimary) // the mark alone; twice as wide as `size`
```

The mark is the space bar, speaking: a solid capsule with three voice bars cut out of it, short, tall, short. The bars are holes, so whatever is behind shows through. `scripts/make-icon.swift` draws the same mark for the app icon (white on a near-black plate), the menu bar and the website.

## Recipes

**A standard page**: `Page` → optional `Tabs` → optional `Banner` → `PageSection`s holding a `CardList` or `Card`. Search and the one primary button go in the page's toolbar.

**A list of rows**: `CardList(items) { ListRow(...) }`. When it is empty, show `EmptyState` instead of the list.

**A settings group**: `PageSection("Name") { Card(padding: 0) { rows with Hairline().padding(.horizontal, Spaces.Space.xl) between } }`.

**Something extra on a row**: put quiet text (the app's name, a meeting's tags) at the trailing end and let the hover actions take its place, as the history and meetings lists do. Keep badges for problems.

## Snapshots

A snapshot case is one screen state drawn to a PNG, in light and dark, at 2x. Add cases to `Screens/<Area>/<Area>Snapshots.swift`:

```swift
enum HomeSnapshots {
  @MainActor static var cases: [SnapshotCase] {
    [
      SnapshotCase("home") { HomeScreen() },
      SnapshotCase("home-empty", model: { .demo(hasAPIKey: false) }) { HomeScreen() },
    ]
  }
}
```

- `.mac` (880 x 720) is the hub's content area, on the panel background.
- `.custom(width:height:)` is a bare canvas on the window background.
- The view gets a loaded `AppModel.demo()` in the environment. Pass `model:` for another starting state.

Run and look:

```bash
cd packages/ui
../../scripts/swiftw run --scratch-path .build-<yours> spaces-snapshots <dir> --only <name>
../../scripts/swiftw run --scratch-path .build-<yours> spaces-snapshots <dir> --list
```

Files are `<dir>/<name>-light.png` and `<dir>/<name>-dark.png`. `--only` takes part of a name (`--only home`). The component gallery is `--only kit-`; `kit-hub` and `kit-settings-sheet` show the kit put together. The tool shows no window and does not take focus.

What a snapshot cannot show: hover, focus and pressed looks (they need a pointer), open menus, and motion. Things drawn by the system outside the view, such as an open `Menu`, are not in the picture. `.blur` does not draw in a snapshot (materials may not either), so the kit avoids both; use gradients.

From Swift (the Mac app does this for its own cases):

```swift
try await SnapshotRenderer().render(cases, to: folder)             // light and dark files
```
