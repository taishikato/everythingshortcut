/// The characters labels are built from.
/// Invariant: two or more distinct lowercase ASCII letters, in priority order.
/// Earlier characters start the most labels. When labels must grow, the earliest characters become prefixes first, so the single-character labels that remain are the last ones.
public struct Alphabet: Hashable, Sendable {
    public let characters: [Character]

    /// Returns nil unless `string` is two or more distinct lowercase ASCII letters.
    public init?(_ string: String) {
        let chars = Array(string)
        guard chars.count >= 2,
              Set(chars).count == chars.count,
              chars.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter })
        else { return nil }
        characters = chars
    }

    /// Vimium's default order: home row first, then the easiest reaches.
    public static let homeRow = Alphabet("sadfjklewcmpgh")!

    public func contains(_ c: Character) -> Bool { characters.contains(c) }
}

public enum LabelGenerator {
    /// Returns `count` labels over `alphabet`, shortest first.
    ///
    /// Guarantees, all covered by tests:
    /// - No label is a prefix of another, so a typed string equal to a label selects exactly one hint.
    /// - The longest label is as short as possible for `count`.
    /// - Within that length, as many labels as possible are one character shorter.
    ///
    /// Breadth-first expansion of the label tree. Each step replaces the shortest leaf with its
    /// children, so leaves = k + steps * (k - 1). Stop at the first step count that covers `count`,
    /// then drop surplus leaves from the back, which are the longest.
    public static func labels(count: Int, alphabet: Alphabet) -> [String] {
        guard count > 0 else { return [] }
        var leaves = alphabet.characters.map { String($0) }
        var head = 0
        while leaves.count - head < count {
            let parent = leaves[head]
            head += 1
            leaves.append(contentsOf: alphabet.characters.map { parent + String($0) })
        }
        return Array(leaves[head..<(head + count)])
    }
}
