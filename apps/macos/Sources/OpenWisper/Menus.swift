import AppKit
import WisperDomain
import WisperMac
import WisperMacUI

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
  private let handler: @MainActor () -> Void

  init(
    _ title: String,
    key: String = "",
    modifiers: NSEvent.ModifierFlags = [.command],
    handler: @escaping @MainActor () -> Void
  ) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: key)
    keyEquivalentModifierMask = modifiers
    target = self
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("ActionMenuItem is made in code.")
  }

  @MainActor @objc private func run() {
    handler()
  }
}

/// Turns menu lines into a real menu.
@MainActor
enum Menus {
  static func menu(_ entries: [MenuEntry], perform: @escaping @MainActor (MenuEntry.Command) -> Void)
    -> NSMenu
  {
    let menu = NSMenu()
    menu.autoenablesItems = false
    fill(menu, with: entries, perform: perform)
    return menu
  }

  static func fill(
    _ menu: NSMenu,
    with entries: [MenuEntry],
    perform: @escaping @MainActor (MenuEntry.Command) -> Void
  ) {
    menu.removeAllItems()
    for entry in entries {
      menu.addItem(item(for: entry, perform: perform))
    }
  }

  private static func item(
    for entry: MenuEntry,
    perform: @escaping @MainActor (MenuEntry.Command) -> Void
  ) -> NSMenuItem {
    let item: NSMenuItem
    switch entry.kind {
    case .separator:
      return .separator()
    case .note:
      item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
      item.isEnabled = false
    case .submenu(let children):
      item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
      item.submenu = menu(children, perform: perform)
    case .action(let command):
      let key = entry.shortcut.flatMap(keyEquivalent)
      var title = entry.title
      if let shortcut = entry.shortcut, key == nil {
        // A shortcut a menu cannot draw (modifier keys alone) goes into the title.
        title += "  (\(shortcut.keyCaps.joined(separator: " ")))"
      }
      item = ActionMenuItem(title, key: key?.key ?? "", modifiers: key?.modifiers ?? []) { perform(command) }
    }
    item.state = entry.isChecked ? .on : .off
    return item
  }

  /// The shortcut in the form a menu shows at the right of an item, when it can.
  static func keyEquivalent(_ combo: KeyCombo) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
    guard combo.keyCode != nil, let cap = combo.keyCaps.last else { return nil }
    let key: String
    switch cap {
    case "Space": key = " "
    case "Return": key = "\r"
    case "Tab": key = "\t"
    default:
      guard cap.count == 1 else { return nil }
      key = cap.lowercased()
    }
    var flags: NSEvent.ModifierFlags = []
    for modifier in combo.modifiers {
      switch modifier {
      case .function: flags.insert(.function)
      case .control: flags.insert(.control)
      case .option: flags.insert(.option)
      case .shift: flags.insert(.shift)
      case .command: flags.insert(.command)
      }
    }
    return (key, flags)
  }
}

/// The menu bar across the top of the screen while the main window is open.
@MainActor
enum MainMenu {
  static func make(navigation: HubNavigation, controls: MacControls, showHub: @escaping @MainActor () -> Void)
    -> NSMenu
  {
    let main = NSMenu()

    let app = NSMenu()
    app.addItem(
      NSMenuItem(
        title: "About Open Wisper",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        keyEquivalent: ""
      )
    )
    app.addItem(.separator())
    app.addItem(ActionMenuItem("Settings…", key: ",") { controls.open(.settings) })
    app.addItem(.separator())
    app.addItem(
      NSMenuItem(title: "Hide Open Wisper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    )
    let hideOthers = NSMenuItem(
      title: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    app.addItem(hideOthers)
    app.addItem(
      NSMenuItem(
        title: "Show All",
        action: #selector(NSApplication.unhideAllApplications(_:)),
        keyEquivalent: ""
      )
    )
    app.addItem(.separator())
    app.addItem(
      NSMenuItem(
        title: "Quit Open Wisper",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
      )
    )
    add(app, titled: "Open Wisper", to: main)

    let file = NSMenu()
    file.addItem(ActionMenuItem("Start or Stop Dictation", modifiers: []) { controls.toggleHandsFree() })
    file.addItem(
      ActionMenuItem("Start or Stop Meeting Recording", modifiers: []) { controls.toggleMeeting() }
    )
    file.addItem(.separator())
    file.addItem(
      NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    )
    add(file, titled: "File", to: main)

    let edit = NSMenu()
    edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
    let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    edit.addItem(redo)
    edit.addItem(.separator())
    edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    edit.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
    edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    add(edit, titled: "Edit", to: main)

    let view = NSMenu()
    for (index, section) in HubNavigation.Section.allCases.enumerated() {
      view.addItem(
        ActionMenuItem(section.title, key: "\(index + 1)") {
          showHub()
          navigation.show(section)
        }
      )
    }
    view.addItem(.separator())
    view.addItem(
      ActionMenuItem("Show or Hide Sidebar", key: "s", modifiers: [.command, .control]) {
        navigation.sidebarHidden.toggle()
      }
    )
    let fullScreen = NSMenuItem(
      title: "Enter Full Screen",
      action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "f"
    )
    fullScreen.keyEquivalentModifierMask = [.command, .control]
    view.addItem(fullScreen)
    add(view, titled: "View", to: main)

    let window = NSMenu()
    window.addItem(
      NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    )
    window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
    window.addItem(.separator())
    window.addItem(ActionMenuItem("Open Wisper", key: "0") { showHub() })
    add(window, titled: "Window", to: main)
    NSApp.windowsMenu = window

    return main
  }

  private static func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
    menu.title = title
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = menu
    main.addItem(item)
  }
}
