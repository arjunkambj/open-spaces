import Foundation
import Testing
import WisperDomain

@testable import WisperUI

private let kubernetes = DictionaryWord(text: "Kubernetes", replaces: "cooper netties")
private let priya = DictionaryWord(text: "Priya Raman")
private let words = [kubernetes, priya]

@Suite struct DictionaryRulesTests {
  @Test func aNewWordIsFine() {
    let check = DictionaryRules.check(text: "PostgreSQL", heardAs: "post gres", in: words)
    #expect(check.isValid)
  }

  @Test(arguments: ["", "   ", "\n"])
  func anEmptyWordIsRefused(text: String) {
    let check = DictionaryRules.check(text: text, heardAs: "", in: words)
    #expect(check.word == .empty)
    #expect(!check.isValid)
  }

  @Test(arguments: ["Priya Raman", "priya raman", "  PRIYA   RAMAN "])
  func theSameWordAgainIsRefusedWhateverTheCase(text: String) {
    let check = DictionaryRules.check(text: text, heardAs: "", in: words)
    #expect(check.word == .duplicate("Priya Raman"))
    #expect(check.word?.message == "“Priya Raman” is already in your dictionary.")
  }

  @Test func accentsMakeADifferentWord() {
    let zoe = [DictionaryWord(text: "Zoe")]
    #expect(DictionaryRules.check(text: "Zoë", heardAs: "", in: zoe).isValid)
  }

  @Test func aWordMayGetASecondHeardAsPhrase() {
    #expect(DictionaryRules.check(text: "Kubernetes", heardAs: "kuber net ease", in: words).isValid)
    // ...but not the same phrase twice, and not without a phrase.
    #expect(
      DictionaryRules.check(text: "kubernetes", heardAs: "Cooper-Netties", in: words).word
        == .duplicate("Kubernetes")
    )
    #expect(
      DictionaryRules.check(text: "kubernetes", heardAs: "", in: words).word == .duplicate("Kubernetes")
    )
  }

  @Test func aHeardAsPhraseBelongsToOneWord() {
    let check = DictionaryRules.check(text: "Cooper Nettie's", heardAs: "cooper  netties.", in: words)
    #expect(check.word == nil)
    #expect(check.heardAs == .heardAsTaken(by: "Kubernetes"))
    #expect(!check.isValid)
  }

  @Test func editingAWordDoesNotClashWithItself() {
    #expect(
      DictionaryRules.check(text: "kubernetes", heardAs: "cooper netties", editing: kubernetes.id, in: words)
        .isValid
    )
    #expect(
      DictionaryRules.check(text: "Priya Raman", heardAs: "", editing: kubernetes.id, in: words).word
        == .duplicate("Priya Raman")
    )
  }

  @Test func savedWordsAreTidy() {
    let word = DictionaryRules.word(text: "  Priya \n Raman ", heardAs: "  pria   ramen ")
    #expect(word.text == "Priya Raman")
    #expect(word.replaces == "pria ramen")
  }

  @Test func anEmptyOrPointlessHeardAsIsDropped() {
    #expect(DictionaryRules.word(text: "Figma", heardAs: "  ").replaces == nil)
    #expect(DictionaryRules.word(text: "Figma", heardAs: "...").replaces == nil)
    #expect(DictionaryRules.word(text: "Figma", heardAs: "Figma").replaces == nil)
    // Fixing only the capital letters is a real replacement.
    #expect(DictionaryRules.word(text: "Figma", heardAs: "figma").replaces == "figma")
  }

  @Test func editingKeepsIdentityAndDate() {
    let old = DictionaryWord(text: "Kubernets", createdAt: Date(timeIntervalSince1970: 1_000))
    let word = DictionaryRules.word(text: "Kubernetes", heardAs: "", replacing: old)
    #expect(word.id == old.id)
    #expect(word.createdAt == old.createdAt)
    #expect(word.text == "Kubernetes")
  }

  @Test func searchLooksAtTheWordAndWhatItReplaces() {
    #expect(DictionaryRules.filter(words, query: "priya") == [priya])
    #expect(DictionaryRules.filter(words, query: "NETTIES") == [kubernetes])
    #expect(DictionaryRules.filter(words, query: " ") == words)
    #expect(DictionaryRules.filter(words, query: "giraffe").isEmpty)
  }

  @Test func countsReadNaturally() {
    #expect(DictionaryRules.count(1) == "1 word")
    #expect(DictionaryRules.count(14) == "14 words")
  }

  @Test func theSamplesStartWithThePersonsName() {
    #expect(DictionarySamples.words(userName: " Alex ").first?.text == "Alex")
    #expect(DictionarySamples.words(userName: "").count == 2)
    // Every sample passes the rules for an empty dictionary.
    for sample in DictionarySamples.words(userName: "Alex") {
      #expect(DictionaryRules.check(text: sample.text, heardAs: sample.replaces ?? "", in: []).isValid)
    }
  }
}

@Suite struct SpokenPhraseTests {
  @Test func phrasesAreComparedTheWayDictationHearsThem() {
    #expect(SpokenPhrase.key("My Calendar-Link.") == "my calendar link")
    #expect(SpokenPhrase.key("  “post   gres” ") == "post gres")
    #expect(SpokenPhrase.key("Priya’s") == "priya's")
    #expect(SpokenPhrase.key("?!") == "")
    // A sign inside a phrase is part of it.
    #expect(SpokenPhrase.key("C#") == "c#")
  }

  @Test func tidyKeepsTheSpellingAndDropsSpareSpace() {
    #expect(SpokenPhrase.tidy("  Open \n\t Wisper ") == "Open Wisper")
    #expect(SpokenPhrase.tidy("") == "")
  }
}
