import Testing
@testable import HintCore

struct LabelsTests {
    @Test func zeroCountHasNoLabels() {
        #expect(LabelGenerator.labels(count: 0, alphabet: .homeRow).isEmpty)
    }

    @Test func singleLettersWhenTheyFit() {
        #expect(LabelGenerator.labels(count: 3, alphabet: .homeRow) == ["s", "a", "d"])
    }

    @Test(arguments: Array(1...600))
    func labelsArePrefixFreeAndShortest(count: Int) {
        let alphabet = Alphabet.homeRow
        let labels = LabelGenerator.labels(count: count, alphabet: alphabet)
        let k = alphabet.characters.count

        #expect(labels.count == count)
        #expect(Set(labels).count == count)
        #expect(labels.allSatisfy { $0.allSatisfy(alphabet.contains) })
        let all = Set(labels)
        for label in labels {
            let properPrefixes = (1..<label.count).map { String(label.prefix($0)) }
            #expect(properPrefixes.allSatisfy { !all.contains($0) }, "a prefix of \(label) is also a label")
        }

        var longest = 1
        var capacity = k
        while capacity < count { longest += 1; capacity *= k }
        #expect(labels.map(\.count).max() == longest)

        let short = labels.filter { $0.count == longest - 1 }.count
        let slots = capacity / k
        func fits(_ s: Int) -> Bool { s + (count - s + k - 1) / k <= slots }
        #expect(fits(short))
        if short < count, longest > 1 { #expect(!fits(short + 1), "one more short label would still fit") }
    }

    @Test func alphabetRejectsInvalidInput() {
        #expect(Alphabet("a") == nil)
        #expect(Alphabet("aa") == nil)
        #expect(Alphabet("aB") == nil)
        #expect(Alphabet("a1") == nil)
        #expect(Alphabet("ab") != nil)
    }
}
