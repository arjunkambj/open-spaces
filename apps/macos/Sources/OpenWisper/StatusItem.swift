import AppKit
import WisperDomain
import WisperEngine
import WisperMacUI

/// The Open Wisper item in the menu bar: a small mark that changes while
/// dictating or recording a meeting, and a menu.
@MainActor
final class StatusItem: NSObject, NSMenuDelegate {
  private let model: AppModel
  private let controls: MacControls
  private let item: NSStatusItem
  private let menu = NSMenu()
  private var microphones: [AudioDevice] = []
  private var iconWatch: Watch<MenuBarContent.Icon>?

  init(model: AppModel, controls: MacControls) {
    self.model = model
    self.controls = controls
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()
    menu.delegate = self
    menu.autoenablesItems = false
    item.menu = menu
    item.button?.toolTip = "Open Wisper"
    item.button?.setAccessibilityLabel("Open Wisper")
    iconWatch = Watch({ [model, controls] in MenuBarContent.icon(for: model, controls: controls) }) {
      [weak self] icon in self?.show(icon)
    }
    refreshMicrophones()
  }

  /// The lines of the menu as they are right now.
  var entries: [MenuEntry] {
    MenuBarContent.entries(for: model, microphones: microphones)
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuild()
    // The list of microphones is asked for each time; the menu fills in when the answer comes.
    refreshMicrophones()
  }

  private func rebuild() {
    Menus.fill(menu, with: entries) { [model, controls] command in
      MenuBarContent.perform(command, model: model, controls: controls)
    }
  }

  private func refreshMicrophones() {
    Task { [weak self, model] in
      let found = await model.capture.microphones()
      guard let self, found != self.microphones else { return }
      self.microphones = found
      self.rebuild()
    }
  }

  private func show(_ icon: MenuBarContent.Icon) {
    guard let button = item.button else { return }
    switch icon {
    case .idle:
      button.image = Self.mark
      button.contentTintColor = nil
    case .dictating:
      button.image = Self.symbol("mic.fill", says: "Open Wisper, dictating")
      button.contentTintColor = nil
    case .meeting:
      button.image = Self.symbol("record.circle.fill", says: "Open Wisper, recording a meeting")
      button.contentTintColor = .systemRed
    }
  }

  /// The Open Wisper mark from the app bundle. Run outside the bundle it is not there, so a system symbol stands in.
  private static let mark: NSImage? = {
    if let url = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "pdf"),
      let image = NSImage(contentsOf: url)
    {
      image.isTemplate = true
      let height: CGFloat = 16
      if image.size.height > 0 {
        image.size = CGSize(width: image.size.width * height / image.size.height, height: height)
      }
      image.accessibilityDescription = "Open Wisper"
      return image
    }
    return symbol("waveform", says: "Open Wisper")
  }()

  private static func symbol(_ name: String, says description: String) -> NSImage? {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
    image?.isTemplate = true
    return image
  }
}
