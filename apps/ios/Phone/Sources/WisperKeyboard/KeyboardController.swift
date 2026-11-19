#if canImport(UIKit)
  import SwiftUI
  import UIKit
  import WisperDomain
  import WisperStore

  /// The keyboard extension's view controller. The extension target only names a subclass
  /// of it as its principal class; everything the keyboard does is here and in `KeyboardModel`.
  open class KeyboardController: UIInputViewController {
    private var model: KeyboardModel?

    open override func viewDidLoad() {
      super.viewDidLoad()

      let folder = SharedFolder()
      // Without the shared folder there is nothing of the app's to read: say so, never guess.
      let library: (any Library)? = folder.isShared ? FileLibrary(root: folder.root) : nil
      let model = KeyboardModel(library: library, dataFolder: folder.isShared ? folder.root : nil, host: host)
      self.model = model

      let hosting = UIHostingController(rootView: KeyboardPanel(model: model))
      hosting.view.backgroundColor = .clear
      hosting.view.translatesAutoresizingMaskIntoConstraints = false
      hosting.safeAreaRegions = []
      addChild(hosting)
      view.addSubview(hosting.view)
      let height = view.heightAnchor.constraint(equalToConstant: KeyboardPanel.height)
      // Just under "required", so the system can still size the keyboard during rotation.
      height.priority = UILayoutPriority(999)
      NSLayoutConstraint.activate([
        hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
        hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        height,
      ])
      hosting.didMove(toParent: self)
    }

    open override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      // The person may be coming back from the app with a new dictation.
      Task { await model?.refresh() }
    }

    private var host: KeyboardHost {
      KeyboardHost(
        insert: { [weak self] text in self?.textDocumentProxy.insertText(text) },
        deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
        nextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
        open: { [weak self] url in await self?.openInApp(url) ?? false },
        hasFullAccess: { [weak self] in self?.hasFullAccess ?? false },
        needsGlobeKey: { [weak self] in self?.needsInputModeSwitchKey ?? true }
      )
    }

    /// Opens a link from inside the keyboard.
    ///
    /// An extension may not use `UIApplication.shared`, and the compiler refuses a direct
    /// call to its `open` method here. But the app object that hosts the keyboard sits at
    /// the end of the responder chain, and it opens links once the person has allowed Full
    /// Access. So the method is found by name and called through the Objective-C runtime.
    private func openInApp(_ url: URL) async -> Bool {
      let selector = NSSelectorFromString("openURL:options:completionHandler:")
      var responder: UIResponder? = self
      while let current = responder {
        // Only the app object. A window scene on the way answers to the same name with
        // different arguments.
        if let application = current as? UIApplication, application.responds(to: selector),
          let method = application.method(for: selector)
        {
          typealias Completion = @convention(block) @Sendable (Bool) -> Void
          typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, Completion?) -> Void
          let open = unsafeBitCast(method, to: Open.self)
          return await withCheckedContinuation { continuation in
            open(application, selector, url as NSURL, NSDictionary()) { opened in
              continuation.resume(returning: opened)
            }
          }
        }
        responder = current.next
      }
      return false
    }
  }
#endif
