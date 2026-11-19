import Foundation
import Testing
import WisperDomain

@testable import WisperUI

private let calendarLink = Snippet(trigger: "my calendar link", expansion: "https://cal.example.com/alex")
private let snippets = [calendarLink, Snippet(trigger: "intro email", expansion: "Hi! Great to meet you.")]

@Suite struct SnippetRulesTests {
  @Test func aNewSnippetIsFine() {
    #expect(SnippetRules.check(trigger: "my address", expansion: "42 Orchard Lane", in: snippets).isValid)
  }

  @Test func bothFieldsAreNeeded() {
    let check = SnippetRules.check(trigger: "  ", expansion: " \n ", in: snippets)
    #expect(check.trigger == .emptyTrigger)
    #expect(check.expansion == .emptyExpansion)
    #expect(!check.isValid)
    #expect(
      SnippetRules.check(trigger: "my address", expansion: "", in: snippets).expansion == .emptyExpansion
    )
  }

  @Test(arguments: ["sig", "a", "ok.", "hi!", "I'm"])
  func oneShortWordIsRefused(trigger: String) {
    #expect(SnippetRules.check(trigger: trigger, expansion: "text", in: []).trigger == .tooShort)
  }

  @Test(arguments: ["addr", "signature", "my sig", "a b", "sign-off", "área"])
  func twoWordsOrFourLettersAreEnough(trigger: String) {
    #expect(SnippetRules.check(trigger: trigger, expansion: "text", in: []).trigger == nil)
  }

  @Test func theReasonForTooShortIsExplained() {
    let message = SnippetRules.Problem.tooShort.message
    #expect(message.contains("two or more words"))
    #expect(message.contains("4 letters"))
    #expect(message.contains("by accident"))
  }

  @Test(arguments: ["my calendar link", "My Calendar Link", " my  calendar-link. "])
  func theSamePhraseAgainIsRefused(trigger: String) {
    let check = SnippetRules.check(trigger: trigger, expansion: "text", in: snippets)
    #expect(check.trigger == .duplicate("my calendar link"))
  }

  @Test func editingASnippetDoesNotClashWithItself() {
    #expect(
      SnippetRules.check(
        trigger: "My calendar link",
        expansion: "new",
        editing: calendarLink.id,
        in: snippets
      )
      .isValid
    )
    #expect(
      SnippetRules.check(trigger: "intro email", expansion: "new", editing: calendarLink.id, in: snippets)
        .trigger
        == .duplicate("intro email")
    )
  }

  @Test func savedSnippetsKeepTheirLineBreaks() {
    let snippet = SnippetRules.snippet(trigger: "  my   sign off ", expansion: "\n Thanks,\nAlex \n\n")
    #expect(snippet.trigger == "my sign off")
    #expect(snippet.expansion == "Thanks,\nAlex")
  }

  @Test func editingKeepsIdentityAndDate() {
    let old = Snippet(trigger: "old", expansion: "old", createdAt: Date(timeIntervalSince1970: 1_000))
    let snippet = SnippetRules.snippet(trigger: "new phrase", expansion: "new", replacing: old)
    #expect(snippet.id == old.id)
    #expect(snippet.createdAt == old.createdAt)
  }

  @Test func thePreviewIsOneLine() {
    #expect(SnippetRules.preview("Thanks,\n\n  Alex\tMorgan ") == "Thanks, Alex Morgan")
  }

  @Test func searchLooksAtThePhraseAndTheText() {
    #expect(SnippetRules.filter(snippets, query: "calendar") == [calendarLink])
    #expect(SnippetRules.filter(snippets, query: "GREAT to meet").map(\.trigger) == ["intro email"])
    #expect(SnippetRules.filter(snippets, query: "") == snippets)
    #expect(SnippetRules.filter(snippets, query: "giraffe").isEmpty)
  }

  @Test func countsReadNaturally() {
    #expect(SnippetRules.count(1) == "1 snippet")
    #expect(SnippetRules.count(3) == "3 snippets")
  }

  @Test func everyExamplePassesTheRules() {
    for userName in ["Alex", ""] {
      let samples = SnippetSample.all(userName: userName)
      #expect(samples.count == 3)
      #expect(Set(samples.map(\.id)).count == samples.count)
      for sample in samples {
        #expect(SnippetRules.check(trigger: sample.trigger, expansion: sample.expansion, in: []).isValid)
      }
    }
    #expect(SnippetSample.all(userName: "Alex").contains { $0.expansion.hasSuffix("Alex") })
  }
}
