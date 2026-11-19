import SwiftUI
import WisperDomain
import WisperEngine

/// The three numbers of the home screen: words spoken, speed and streak.
///
/// It is its own view so the numbers are worked out when the history changes, not on
/// every key typed into the search field.
struct HomeStats: View {
  enum Layout {
    /// A card for the side column of a Mac, with a line about the time saved.
    case card
    /// Three tiles in a row, above the history.
    case row
  }

  let layout: Layout

  @Environment(AppModel.self) private var model
  @Environment(\.wisperIdiom) private var idiom

  var body: some View {
    let stats = model.stats
    switch layout {
    case .card: card(stats)
    case .row: row(stats)
    }
  }

  private func card(_ stats: DictationStats) -> some View {
    Card {
      VStack(alignment: .leading, spacing: Wisper.Space.s) {
        StatTile(HomeText.compact(stats.totalWords), label: "words spoken")
        StatTile("\(stats.wordsPerMinute)", label: "words a minute")
        StatTile("\(stats.dayStreak)", label: "day streak")
      }
      Hairline().padding(.vertical, Wisper.Space.l)
      VStack(alignment: .leading, spacing: Wisper.Space.xs) {
        if stats.dictationCount == 0 {
          Text("Nothing to count yet").wisperText(.cardTitle)
          Text("Your numbers show up here after your first dictation.").wisperText(.caption)
        } else if let saved = HomeText.timeSaved(stats) {
          Text("Time saved").wisperText(.cardTitle)
          Text("About \(saved), next to typing at \(HomeText.typingSpeed) words a minute.")
            .wisperText(.caption)
        } else {
          Text("Nice work").wisperText(.cardTitle)
          Text("Keep going. The time you save shows up here.").wisperText(.caption)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func row(_ stats: DictationStats) -> some View {
    Card(padding: 0) {
      HStack(alignment: .top, spacing: 0) {
        // Three columns on an iPhone are too narrow for the longer labels.
        column(HomeText.compact(stats.totalWords), idiom == .phone ? "words" : "words spoken")
        divider
        column("\(stats.wordsPerMinute)", idiom == .phone ? "per minute" : "words a minute")
        divider
        column("\(stats.dayStreak)", "day streak")
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func column(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: Wisper.Space.xxs) {
      Text(value)
        .wisperText(.statNumber)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      Text(label)
        .wisperText(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(Wisper.Space.m)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var divider: some View {
    Rectangle()
      .fill(Wisper.Color.border)
      .frame(width: Wisper.Stroke.hairline)
      .accessibilityHidden(true)
  }
}
