import Foundation
import Testing
import WisperDomain
import WisperEngine

@testable import WisperUI

/// A fixed calendar and clock, so day names do not depend on where the tests run.
private let calendar: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Europe/London")!
  return calendar
}()
private let english = Locale(identifier: "en_US")

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
  calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private let now = date(2026, 11, 19, 15)

private func dictation(_ text: String, at created: Date, app: String? = nil, raw: String? = nil) -> Dictation
{
  Dictation(createdAt: created, rawText: raw ?? text, text: text, duration: 5, appName: app)
}

@Suite struct HomeHistoryTests {
  @Test func groupsByDayNewestFirst() {
    let entries = [
      dictation("two days ago", at: date(2026, 11, 17, 9)),
      dictation("this morning", at: date(2026, 11, 19, 8)),
      dictation("last night", at: date(2026, 11, 18, 23, 50)),
      dictation("just now", at: date(2026, 11, 19, 14, 59)),
    ]
    let days = HomeHistory.days(entries, now: now, calendar: calendar, locale: english)

    #expect(days.map(\.title) == ["Today", "Yesterday", "Tuesday, November 17"])
    #expect(days[0].entries.map(\.text) == ["just now", "this morning"])
    #expect(days[1].entries.map(\.text) == ["last night"])
    #expect(Set(days.map(\.id)).count == days.count)
  }

  @Test func splitsDaysAtMidnightOfTheCalendar() {
    let entries = [
      dictation("after midnight", at: date(2026, 11, 19, 0, 1)),
      dictation("before midnight", at: date(2026, 11, 18, 23, 59)),
    ]
    let days = HomeHistory.days(entries, now: now, calendar: calendar, locale: english)
    #expect(days.map(\.title) == ["Today", "Yesterday"])
  }

  @Test func noEntriesMakeNoDays() {
    #expect(HomeHistory.days([], now: now, calendar: calendar, locale: english).isEmpty)
  }

  @Test func otherYearsShowTheYear() {
    let title = HomeHistory.dayTitle(date(2025, 12, 31), now: now, calendar: calendar, locale: english)
    #expect(title == "Wednesday, December 31, 2025")
  }

  @Test func tomorrowIsNotCalledToday() {
    // A clock that was set back can leave entries dated in the future.
    let title = HomeHistory.dayTitle(date(2026, 11, 20), now: now, calendar: calendar, locale: english)
    #expect(title == "Friday, November 20")
  }

  @Test func searchLooksAtTextWhatWasHeardAndTheApp() {
    let entries = [
      dictation("Move the review to Thursday", at: now, app: "Mail"),
      dictation("Café opens at nine", at: now, app: "Messages"),
      dictation("Thanks, Thursday works.", at: now, app: "Slack", raw: "make this shorter"),
    ]
    #expect(HomeHistory.filter(entries, query: "thursday").count == 2)
    #expect(HomeHistory.filter(entries, query: "  CAFE ").map(\.appName) == ["Messages"])
    #expect(HomeHistory.filter(entries, query: "slack").map(\.appName) == ["Slack"])
    #expect(HomeHistory.filter(entries, query: "shorter").map(\.appName) == ["Slack"])
    #expect(HomeHistory.filter(entries, query: "giraffe").isEmpty)
  }

  @Test func anEmptySearchKeepsEverythingInOrder() {
    let entries = [dictation("one", at: now), dictation("two", at: now)]
    #expect(HomeHistory.filter(entries, query: "") == entries)
    #expect(HomeHistory.filter(entries, query: "  \n ") == entries)
  }

  @Test func timeIsLowerCase() {
    let time = HomeHistory.time(date(2026, 11, 19, 9, 41), calendar: calendar, locale: english)
    #expect(time.hasPrefix("9:41"))
    #expect(time.hasSuffix("am"))
  }

  @Test(arguments: [(0.0, "0:00"), (6.4, "0:06"), (59.6, "1:00"), (65, "1:05"), (600, "10:00"), (-3, "0:00")])
  func clockShowsMinutesAndSeconds(seconds: Double, expected: String) {
    #expect(HomeHistory.clock(seconds) == expected)
  }

  @Test func clockSurvivesNonsense() {
    #expect(HomeHistory.clock(.nan) == "0:00")
    #expect(HomeHistory.clock(.infinity) == "0:00")
  }

  @Test func onlyTextThatCouldWrapIsMeasured() {
    #expect(!HomeHistory.mayNeedCutting("Thanks, see you at ten."))
    #expect(HomeHistory.mayNeedCutting(String(repeating: "word ", count: 40)))
    #expect(HomeHistory.mayNeedCutting("one\ntwo"))
  }
}

@Suite struct HomeTextTests {
  @Test func theTitleIsTheNameOfThePlace() {
    #expect(HomeText.title(.mac) == "Home")
    #expect(HomeText.title(.phone) == "History")
  }

  @Test(arguments: [
    (0, "0"), (7, "7"), (999, "999"), (1_000, "1K"), (1_049, "1K"), (1_250, "1.2K"), (12_440, "12.4K"),
    (99_950, "99.9K"), (120_000, "120K"), (999_999, "999K"), (1_000_000, "1M"), (2_540_000, "2.5M"),
    (-5, "0"),
  ])
  func countsAreShortened(count: Int, expected: String) {
    #expect(HomeText.compact(count) == expected)
  }

  @Test func theNumbersAreOneQuietLine() {
    let stats = DictationStats(totalWords: 12_440, wordsPerMinute: 136, dayStreak: 3, dictationCount: 90)
    #expect(HomeText.summary(stats) == "12.4K words dictated · 136 words a minute")
    #expect(HomeText.summary(DictationStats(totalWords: 1, dictationCount: 1)) == "1 word dictated")
    #expect(HomeText.summary(DictationStats(totalWords: 40, dictationCount: 2)) == "40 words dictated")
  }

  @Test func thereAreNoNumbersBeforeTheFirstDictation() {
    #expect(HomeText.summary(DictationStats()) == nil)
    // A failed dictation has no words to count.
    #expect(HomeText.summary(DictationStats(dictationCount: 1)) == nil)
  }

  @Test func shortcutsBecomeKeyLabels() {
    #expect(HomeText.keyLabels(KeyCombo(modifiers: [.function])) == ["fn"])
    #expect(
      HomeText.keyLabels(KeyCombo(keyCode: KeyCombo.KeyCode.space, modifiers: [.function])) == [
        "fn", "Space",
      ]
    )
    #expect(
      HomeText.keyLabels(KeyCombo(keyCode: KeyCombo.KeyCode.v, modifiers: [.command, .control])) == [
        "⌃", "⌘", "V",
      ]
    )
    #expect(HomeText.keyLabels(KeyCombo(keyCode: 200)) == ["Key 200"])
    #expect(HomeText.keyLabels(nil).isEmpty)
    #expect(HomeText.keyLabels(KeyCombo()).isEmpty)
  }

  @Test func theDefaultShortcutsAllHaveNames() {
    for combo in Settings.defaultShortcuts.values {
      #expect(!HomeText.keyLabels(combo).contains { $0.hasPrefix("Key ") })
    }
  }
}

// MARK: Retry from Home

@Test func aRetryThatWorkedCopiesTheTextAndSaysSo() {
  let done = Dictation(rawText: "hello there", text: "Hello there.", duration: 2)
  let outcome = HomeRetry(done)
  #expect(outcome.textToCopy == "Hello there.")
  #expect(outcome.toast == Toast("Copied to the clipboard"))
}

@Test func aRetryThatFailedCopiesNothing() {
  let outcome = HomeRetry(nil)
  #expect(outcome.textToCopy == nil)
  #expect(outcome.toast.tone == .error)
  // An entry that is still a failure has no text to copy either.
  let stillFailed = Dictation(rawText: "", text: "", duration: 2, audioFile: "a.m4a", failure: "No.")
  #expect(HomeRetry(stillFailed).textToCopy == nil)
}

@Test @MainActor func aRetryFromHomeNeverTypesIntoAnotherApp() async throws {
  // What a quit in the middle of a dictation leaves behind: a failed entry with its audio.
  let unfinished = Dictation(
    rawText: "",
    text: "",
    duration: 3,
    audioFile: "kept-\(UUID().uuidString).m4a",
    failure: "Open Wisper closed before this dictation was finished. Try it again."
  )
  let library = InMemoryLibrary(
    settings: Settings(userName: "Alex", onboardedAt: Date()),
    dictations: [unfinished]
  )
  let audio = try await library.dictationAudioDirectory().appendingPathComponent(unfinished.audioFile ?? "")
  try Data([1, 2, 3]).write(to: audio)
  defer { try? FileManager.default.removeItem(at: audio) }
  let target = FakeTextTarget()
  let engine = DictationEngine(
    library: library,
    capture: FakeAudioCapture(),
    transcriber: FakeTranscriber(text: "See you at ten."),
    languageModel: FakeLanguageModel(text: "See you at ten."),
    target: target
  )

  let outcome = HomeRetry(await engine.retry(unfinished.id, insert: false))

  #expect(outcome.textToCopy == "See you at ten.")
  #expect(await target.inserted.isEmpty)
  let stored = try await library.dictations().first { $0.id == unfinished.id }
  #expect(stored?.failed == false)
  #expect(stored?.text == "See you at ten.")
}
