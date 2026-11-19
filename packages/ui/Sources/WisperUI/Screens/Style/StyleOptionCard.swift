import SwiftUI
import WisperDomain

/// One writing style to pick: its name, its rule and a sample of how a message comes out.
/// The chosen one has an accent ring and a tick; the others have no border at all.
struct StyleOptionCard: View {
  let style: WritingStyle
  let category: AppCategory
  let userName: String
  let isSelected: Bool
  /// Stacked under the other cards, so it is as tall as its content only.
  let isCompact: Bool
  let action: () -> Void

  @Environment(\.simulatedHover) private var simulatedHover
  @State private var isHovered = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.card, style: .continuous)
    let hovered = isHovered || simulatedHover
    Button(action: action) {
      VStack(alignment: .leading, spacing: Wisper.Space.l) {
        HStack(alignment: .top, spacing: Wisper.Space.s) {
          VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
            Text(style.label).wisperText(.cardTitle)
            Text(style.summary).wisperText(.caption)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .wisperText(.cardTitle, color: isSelected ? Wisper.Color.accent : Wisper.Color.borderStrong)
            .accessibilityHidden(true)
        }
        StyleSample(text: style.example, category: category, userName: userName)
          .frame(maxHeight: isCompact ? nil : .infinity, alignment: .top)
      }
      .padding(Wisper.Space.l)
      .frame(maxWidth: .infinity, maxHeight: isCompact ? nil : .infinity, alignment: .topLeading)
      .background(hovered && !isSelected ? Wisper.Color.surfaceHover : Wisper.Color.surface, in: shape)
      .overlay {
        shape.strokeBorder(
          isSelected ? Wisper.Color.accent : .clear,
          lineWidth: Wisper.Stroke.focus
        )
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .focusRingShape(shape)
    .onHover { isHovered = $0 }
    .animation(Wisper.Motion.quick, value: isHovered)
    .animation(Wisper.Motion.smooth, value: isSelected)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(style.label). \(style.summary)")
    .accessibilityValue("Example: \(style.example)")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

/// The sample sentence drawn as the kind of thing it would be: a chat message, a work
/// chat post, an email or a note.
private struct StyleSample: View {
  let text: String
  let category: AppCategory
  let userName: String

  private static let pictureSize: CGFloat = 28

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: Wisper.Radius.control, style: .continuous)
    Group {
      switch category {
      case .personalMessages: message
      case .workMessages: post
      case .email: email
      case .other: note
      }
    }
    .padding(Wisper.Space.m)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Wisper.Color.raised, in: shape)
  }

  private var sample: some View {
    Text(text)
      .wisperText(.body)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// A chat bubble on the sending side.
  private var message: some View {
    VStack(alignment: .trailing, spacing: Wisper.Space.xs) {
      sample
        .padding(.horizontal, Wisper.Space.m)
        .padding(.vertical, Wisper.Space.s)
        .background(
          Wisper.Color.surfaceSelected,
          in: UnevenRoundedRectangle(
            topLeadingRadius: Wisper.Radius.card,
            bottomLeadingRadius: Wisper.Radius.card,
            bottomTrailingRadius: Wisper.Radius.small,
            topTrailingRadius: Wisper.Radius.card,
            style: .continuous
          )
        )
      Text("Delivered").wisperText(.caption, color: Wisper.Color.textTertiary)
    }
    .padding(.leading, Wisper.Space.l)
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  /// A post in a team chat: a small picture, a name and the time.
  private var post: some View {
    HStack(alignment: .top, spacing: Wisper.Space.s) {
      Text(StyleText.initial(userName))
        .wisperText(.captionStrong)
        .frame(width: Self.pictureSize, height: Self.pictureSize)
        .background(
          Wisper.Color.surfaceSelected,
          in: RoundedRectangle(cornerRadius: Wisper.Radius.small, style: .continuous)
        )
      VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
        HStack(alignment: .firstTextBaseline, spacing: Wisper.Space.s) {
          Text(StyleText.writer(userName)).wisperText(.captionStrong).lineLimit(1)
          Text("9:41 am").wisperText(.caption, color: Wisper.Color.textTertiary).lineLimit(1)
        }
        sample
      }
    }
  }

  /// The top of an email: who it is to, the subject, then the text.
  private var email: some View {
    VStack(alignment: .leading, spacing: Wisper.Space.s) {
      VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
        emailLine("To", "Sam")
        emailLine("Subject", "Lunch tomorrow")
      }
      Hairline()
      sample
    }
  }

  private func emailLine(_ name: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Wisper.Space.s) {
      Text(name).wisperText(.caption, color: Wisper.Color.textTertiary)
      Text(value).wisperText(.caption, color: Wisper.Color.textPrimary).lineLimit(1)
    }
  }

  /// A page of notes with the cursor after the text.
  private var note: some View {
    VStack(alignment: .leading, spacing: Wisper.Space.s) {
      Text("Note").wisperText(.sectionLabel)
      sample
    }
  }
}
