import Testing
@testable import Wherever

@Suite struct ContentTermsTests {
    @Test func eachTermGoesAsItIsTrimmed() {
        #expect(ContentTerms(terms: ["alpha", "two words"]).words(draft: "") == ["alpha", "two words"])
        #expect(ContentTerms(terms: [" beta ", "\talpha\n"], match: .all).words(draft: "") == ["beta", "alpha"])
        #expect(ContentTerms().words(draft: "") == [])
    }

    @Test func quotesStayAndBlanksAndRepeatsGo() {
        #expect(ContentTerms(terms: ["\"alpha\"", "  ", "a \"b\" c", "\"alpha\""]).words(draft: "") == ["\"alpha\"", "a \"b\" c"])
    }

    @Test func aDraftCountsAtAnyLength() {
        #expect(ContentTerms().words(draft: "a") == ["a"])
        #expect(ContentTerms().words(draft: "é") == ["é"])
        #expect(ContentTerms(terms: ["ab"]).words(draft: "cd") == ["ab", "cd"])
        #expect(ContentTerms(terms: ["ab"]).words(draft: " ab ") == ["ab"])
        #expect(ContentTerms().words(draft: "   ") == [])
    }
}
