import Testing
import WisperDomain

@testable import WisperUI

@Suite struct StyleTextTests {
  @Test func everyKindOfAppHasItsWords() {
    for category in AppCategory.allCases {
      #expect(!StyleText.shortLabel(category).isEmpty)
      #expect(StyleText.shortLabel(category).count <= 8)
      #expect(StyleText.apps(category).hasSuffix("."))
      #expect(!StyleText.symbol(category).isEmpty)
    }
    #expect(Set(AppCategory.allCases.map(StyleText.shortLabel)).count == AppCategory.allCases.count)
    #expect(Set(AppCategory.allCases.map(StyleText.apps)).count == AppCategory.allCases.count)
  }

  @Test func theWriterOfASampleIsThePersonOrYou() {
    #expect(StyleText.writer(" Alex ") == "Alex")
    #expect(StyleText.writer("") == "You")
    #expect(StyleText.initial("alex morgan") == "A")
    #expect(StyleText.initial("  ") == "Y")
  }
}
