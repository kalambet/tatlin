import Foundation
import Testing
@testable import TatlinKit

@Suite("WER")
struct WERTests {

    // MARK: - Tokenization

    @Test("identical strings produce WER 0")
    func identicalStrings() {
        let r = WER.compute(reference: "hello world", hypothesis: "hello world")
        #expect(r.rate == 0.0)
        #expect(r.substitutions == 0)
        #expect(r.insertions == 0)
        #expect(r.deletions == 0)
    }

    @Test("empty hypothesis is all deletions")
    func emptyHypothesis() {
        let r = WER.compute(reference: "one two three", hypothesis: "")
        #expect(r.deletions == 3)
        #expect(r.substitutions == 0)
        #expect(r.insertions == 0)
        #expect(r.rate == 1.0)
    }

    @Test("empty reference with non-empty hypothesis is all insertions")
    func emptyReference() {
        let r = WER.compute(reference: "", hypothesis: "one two three")
        #expect(r.insertions == 3)
        #expect(r.deletions == 0)
        #expect(r.substitutions == 0)
        // rate = insertions / 0 → special-cased to 1.0
        #expect(r.rate == 1.0)
    }

    @Test("both empty gives WER 0")
    func bothEmpty() {
        let r = WER.compute(reference: "", hypothesis: "")
        #expect(r.rate == 0.0)
    }

    @Test("single substitution: 1/3 ≈ 33.3%")
    func singleSubstitution() {
        // ref: ["the", "cat", "sat"]
        // hyp: ["the", "cat", "mat"]  → 1 substitution
        let r = WER.compute(reference: "the cat sat", hypothesis: "the cat mat")
        #expect(r.substitutions == 1)
        #expect(r.insertions == 0)
        #expect(r.deletions == 0)
        #expect(r.referenceLength == 3)
        #expect(abs(r.rate - 1.0 / 3.0) < 0.001)
    }

    @Test("one insertion: 1/3 extra word")
    func singleInsertion() {
        // ref: ["a", "b"]  hyp: ["a", "x", "b"]  → 1 insertion
        let r = WER.compute(referenceTokens: ["a", "b"], hypothesisTokens: ["a", "x", "b"])
        #expect(r.insertions == 1)
        #expect(r.substitutions == 0)
        #expect(r.deletions == 0)
        #expect(r.referenceLength == 2)
        #expect(abs(r.rate - 0.5) < 0.001)
    }

    @Test("one deletion: 1/3 missing word")
    func singleDeletion() {
        // ref: ["a", "b", "c"]  hyp: ["a", "c"]  → 1 deletion
        let r = WER.compute(referenceTokens: ["a", "b", "c"], hypothesisTokens: ["a", "c"])
        #expect(r.deletions == 1)
        #expect(r.substitutions == 0)
        #expect(r.insertions == 0)
        #expect(r.referenceLength == 3)
        #expect(abs(r.rate - 1.0 / 3.0) < 0.001)
    }

    @Test("completely different sequences = all substitutions")
    func completelyDifferent() {
        let r = WER.compute(referenceTokens: ["a", "b", "c"], hypothesisTokens: ["x", "y", "z"])
        #expect(r.substitutions == 3)
        #expect(r.insertions == 0)
        #expect(r.deletions == 0)
        #expect(r.rate == 1.0)
    }

    // MARK: - Normalization

    @Test("case folding: uppercase matches lowercase")
    func caseFolding() {
        let r = WER.compute(reference: "Hello World", hypothesis: "hello world")
        #expect(r.rate == 0.0)
    }

    @Test("punctuation stripped before comparison")
    func punctuationStripped() {
        // "hello, world!" vs "hello world" → should be identical after normalization
        let r = WER.compute(reference: "hello, world!", hypothesis: "hello world")
        #expect(r.rate == 0.0)
    }

    @Test("extra whitespace collapsed")
    func extraWhitespace() {
        let r = WER.compute(reference: "one  two   three", hypothesis: "one two three")
        #expect(r.rate == 0.0)
    }

    // MARK: - Tokenizer unit tests

    @Test("tokenize lowercases and strips punctuation")
    func tokenize() {
        let tokens = WER.tokenize("Hello, World! It's 2026.")
        // "hello" "world" "it's" "2026"  (apostrophe preserved as part of contraction)
        #expect(tokens.contains("hello"))
        #expect(tokens.contains("world"))
        #expect(!tokens.contains("Hello,"))
    }

    @Test("tokenize empty string returns empty array")
    func tokenizeEmpty() {
        #expect(WER.tokenize("").isEmpty)
    }
}
