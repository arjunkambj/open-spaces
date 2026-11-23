import SpacesDomain
import SwiftUI

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
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.card, style: .continuous)
    let hovered = isHovered || simulatedHover
    Button(action: action) {
      VStack(alignment: .leading, spacing: Spaces.Space.l) {
        HStack(alignment: .top, spacing: Spaces.Space.s) {
          VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
            Text(style.label).spacesText(.cardTitle)
            Text(style.summary).spacesText(.caption)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .spacesText(.cardTitle, color: isSelected ? Spaces.Color.accent : Spaces.Color.borderStrong)
            .accessibilityHidden(true)
        }
        StyleSample(text: style.example, category: category, userName: userName)
          .frame(maxHeight: isCompact ? nil : .infinity, alignment: .top)
      }
      .padding(Spaces.Space.l)
      .frame(maxWidth: .infinity, maxHeight: isCompact ? nil : .infinity, alignment: .topLeading)
      .background(hovered && !isSelected ? Spaces.Color.surfaceHover : Spaces.Color.surface, in: shape)
      .overlay {
        shape.strokeBorder(
          isSelected ? Spaces.Color.accent : .clear,
          lineWidth: Spaces.Stroke.focus
        )
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .contentShape(.focusEffect, shape)
    .onHover { isHovered = $0 }
    .animation(Spaces.Motion.quick, value: isHovered)
    .animation(Spaces.Motion.smooth, value: isSelected)
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
    let shape = RoundedRectangle(cornerRadius: Spaces.Radius.control, style: .continuous)
    Group {
      switch category {
      case .personalMessages: message
      case .workMessages: post
      case .email: email
      case .other: note
      }
    }
    .padding(Spaces.Space.m)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(Spaces.Color.raised, in: shape)
  }

  private var sample: some View {
    Text(text)
      .spacesText(.body)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// A chat bubble on the sending side.
  private var message: some View {
    VStack(alignment: .trailing, spacing: Spaces.Space.xs) {
      sample
        .padding(.horizontal, Spaces.Space.m)
        .padding(.vertical, Spaces.Space.s)
        .background(
          Spaces.Color.surfaceSelected,
          in: UnevenRoundedRectangle(
            topLeadingRadius: Spaces.Radius.card,
            bottomLeadingRadius: Spaces.Radius.card,
            bottomTrailingRadius: Spaces.Radius.small,
            topTrailingRadius: Spaces.Radius.card,
            style: .continuous
          )
        )
      Text("Delivered").spacesText(.caption, color: Spaces.Color.textTertiary)
    }
    .padding(.leading, Spaces.Space.l)
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  /// A post in a team chat: a small picture, a name and the time.
  private var post: some View {
    HStack(alignment: .top, spacing: Spaces.Space.s) {
      Text(StyleText.initial(userName))
        .spacesText(.captionStrong)
        .frame(width: Self.pictureSize, height: Self.pictureSize)
        .background(
          Spaces.Color.surfaceSelected,
          in: RoundedRectangle(cornerRadius: Spaces.Radius.small, style: .continuous)
        )
      VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
        HStack(alignment: .firstTextBaseline, spacing: Spaces.Space.s) {
          Text(StyleText.writer(userName)).spacesText(.captionStrong).lineLimit(1)
          Text("9:41 am").spacesText(.caption, color: Spaces.Color.textTertiary).lineLimit(1)
        }
        sample
      }
    }
  }

  /// The top of an email: who it is to, the subject, then the text.
  private var email: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.s) {
      VStack(alignment: .leading, spacing: Spaces.Space.xxs) {
        emailLine("To", "Sam")
        emailLine("Subject", "Lunch tomorrow")
      }
      Hairline()
      sample
    }
  }

  private func emailLine(_ name: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spaces.Space.s) {
      Text(name).spacesText(.caption, color: Spaces.Color.textTertiary)
      Text(value).spacesText(.caption, color: Spaces.Color.textPrimary).lineLimit(1)
    }
  }

  /// A page of notes with the cursor after the text.
  private var note: some View {
    VStack(alignment: .leading, spacing: Spaces.Space.s) {
      Text("Note").spacesText(.sectionLabel)
      sample
    }
  }
}
