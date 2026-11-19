import SwiftUI

/// The inside of a dialog: title, optional helper text, a close button, the content and
/// footer buttons. `.dialog(isPresented:...)` builds one for you; use this type with
/// `.modal(isPresented:)` only when you need to lay a dialog out yourself.
public struct DialogCard<Content: View, Footer: View>: View {
  private let title: String
  private let subtitle: String?
  private let width: CGFloat
  private let onClose: (() -> Void)?
  private let content: Content
  private let footer: Footer

  @Environment(\.wisperIdiom) private var idiom

  /// - onClose: called by the close button; `nil` hides it.
  /// - footer: buttons. Put a `Spacer()` between the ones that belong left and right.
  public init(
    title: String,
    subtitle: String? = nil,
    width: CGFloat = 480,
    onClose: (() -> Void)? = nil,
    @ViewBuilder content: () -> Content,
    @ViewBuilder footer: () -> Footer = { EmptyView() }
  ) {
    self.title = title
    self.subtitle = subtitle
    self.width = width
    self.onClose = onClose
    self.content = content()
    self.footer = footer()
  }

  public var body: some View {
    let phone = idiom == .phone
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: Wisper.Space.m) {
        VStack(alignment: .leading, spacing: 6) {
          Text(title)
            .wisperText(.cardTitle)
            .accessibilityAddTraits(.isHeader)
          if let subtitle {
            Text(subtitle)
              .wisperText(.body, color: Wisper.Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let onClose {
          // Escape closes the dialog wherever the cursor is.
          IconButton("xmark", label: "Close", action: onClose)
            .keyboardShortcut(.cancelAction)
            .padding(.top, -6)
            .padding(.trailing, -6)
        }
      }
      .padding(.bottom, Wisper.Space.l)

      VStack(alignment: .leading, spacing: Wisper.Space.l) { content }
        .frame(maxWidth: .infinity, alignment: .leading)

      if Footer.self != EmptyView.self {
        HStack(spacing: Wisper.Space.s) { footer }
          .frame(maxWidth: .infinity, alignment: .trailing)
          .padding(.top, Wisper.Space.xl)
      }
    }
    .padding(phone ? 20 : Wisper.Space.xl)
    .frame(maxWidth: phone ? .infinity : width, alignment: .topLeading)
    .modalSurface()
  }
}

private struct ModalSurface: ViewModifier {
  @Environment(\.wisperIdiom) private var idiom

  func body(content: Content) -> some View {
    if idiom == .phone {
      // The sheet is the surface.
      content
    } else {
      let shape = RoundedRectangle(cornerRadius: Wisper.Radius.panel, style: .continuous)
      content
        .background {
          shape.fill(Wisper.Color.raised).shadow(color: .black.opacity(0.22), radius: 30, y: 12)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Wisper.Color.border, lineWidth: Wisper.Stroke.hairline) }
    }
  }
}

extension View {
  /// The look of something shown with `.modal(isPresented:)` on a Mac: a raised card with
  /// large round corners, a hairline border and a soft shadow. Does nothing on iPhone,
  /// where the sheet is the surface. `DialogCard` already has it.
  public func modalSurface() -> some View {
    modifier(ModalSurface())
  }
}

/// A dimmed layer with something centred on it. Clicking the dim area or pressing
/// Escape calls `onDismiss`.
struct ScrimOverlay<Content: View>: View {
  let onDismiss: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    ZStack {
      Wisper.Color.scrim
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityLabel("Close")
        .accessibilityAddTraits(.isButton)
      content
        .padding(Wisper.Space.xl)
    }
    #if os(macOS)
      .onExitCommand(perform: onDismiss)
    #endif
    .accessibilityAddTraits(.isModal)
  }
}

private struct ModalModifier<ModalContent: View>: ViewModifier {
  @Binding var isPresented: Bool
  let modalContent: () -> ModalContent

  @Environment(\.wisperIdiom) private var idiom

  func body(content: Content) -> some View {
    #if os(iOS)
      content.sheet(isPresented: $isPresented) {
        ScrollView { modalContent() }
          .background(Wisper.Color.panel)
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
      }
    #else
      // What is under the dim layer is out of reach while it is there: for the pointer, for
      // Tab and for VoiceOver. A phone layout drawn on a Mac only stands in for the native sheet.
      content
        .disabled(isPresented && idiom == .mac)
        .accessibilityHidden(isPresented)
        .overlay {
          if isPresented {
            if idiom == .phone {
              sheetPreview
            } else {
              ScrimOverlay(onDismiss: { isPresented = false }) {
                modalContent()
                  .transition(.scale(scale: 0.97).combined(with: .opacity))
              }
              .transition(.opacity)
            }
          }
        }
        .animation(Wisper.Motion.spring, value: isPresented)
    #endif
  }

  #if !os(iOS)
    /// Stands in for the native sheet when a phone layout is drawn on a Mac (snapshots).
    private var sheetPreview: some View {
      ZStack(alignment: .bottom) {
        Wisper.Color.scrim.ignoresSafeArea()
        modalContent()
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, Wisper.Space.m)
          .overlay(alignment: .top) {
            Capsule().fill(Wisper.Color.borderStrong).frame(width: 36, height: 5).padding(.top, 6)
          }
          .padding(.bottom, Wisper.Space.l)
          .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
              .fill(Wisper.Color.panel)
              .ignoresSafeArea(edges: .bottom)
          }
      }
    }
  #endif
}

extension View {
  /// Presents any view over this one. On a Mac it sits centred on a dimmed layer that
  /// covers this view, so attach it to the root of the window (or of the screen it belongs
  /// to); give the content `.modalSurface()`. On iPhone it is a native sheet.
  ///
  /// While it shows, the view under it cannot be used: not with the pointer, not with Tab
  /// and not with VoiceOver.
  ///
  ///     .modal(isPresented: $showSettings) {
  ///       SettingsScreen(onClose: { showSettings = false })
  ///         .frame(width: 860, height: 600)
  ///         .modalSurface()
  ///     }
  public func modal<ModalContent: View>(
    isPresented: Binding<Bool>,
    @ViewBuilder content: @escaping () -> ModalContent
  ) -> some View {
    modifier(ModalModifier(isPresented: isPresented, modalContent: content))
  }

  /// Presents a dialog over this view: a title, your content and footer buttons.
  /// See `modal(isPresented:content:)` for where to attach it.
  ///
  ///     .dialog(isPresented: $isAdding, title: "Add a word") {
  ///       WisperTextField(text: $word, placeholder: "Word or name", focusOnAppear: true)
  ///     } footer: {
  ///       Button("Cancel") { isAdding = false }.buttonStyle(.wisper())
  ///       Button("Add word") { save() }.buttonStyle(.wisper(.primary)).keyboardShortcut(.defaultAction)
  ///     }
  ///
  /// Escape presses the close button. Give the button Return should press
  /// `.keyboardShortcut(.defaultAction)`: the primary one, but Cancel when the other button
  /// deletes something. Do not give a footer button `.cancelAction`; the close button has it.
  public func dialog<DialogContent: View, Footer: View>(
    isPresented: Binding<Bool>,
    title: String,
    subtitle: String? = nil,
    width: CGFloat = 480,
    @ViewBuilder content: @escaping () -> DialogContent,
    @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }
  ) -> some View {
    modal(isPresented: isPresented) {
      DialogCard(
        title: title,
        subtitle: subtitle,
        width: width,
        onClose: { isPresented.wrappedValue = false },
        content: content,
        footer: footer
      )
    }
  }
}
