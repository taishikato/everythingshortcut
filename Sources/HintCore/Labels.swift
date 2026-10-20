/// The characters labels are built from.
/// Invariant: two or more distinct lowercase ASCII letters, in priority order.
/// Earlier characters start the most labels. When labels must grow, the earliest characters become prefixes first, so the single-character labels that remain are the last ones.
public struct Alphabet: Hashable, Sendable {
    public let characters: [Character]

    private init(checked characters: [Character]) { self.characters = characters }

    /// Returns nil unless `string` already satisfies the invariant, so "aB" is nil here
    /// although `parse` accepts it as "ab".
    public init?(_ string: String) {
        guard case .success(let parsed) = Self.parse(string), parsed.string == string else { return nil }
        self = parsed
    }

    /// Parses user input. Lowercases first, so "ASDF" becomes "asdf".
    public static func parse(_ input: String) -> Result<Alphabet, AlphabetError> {
        let chars = Array(input.lowercased())
        var seen = Set<Character>()
        for c in chars {
            guard c.isASCII, c.isLetter else { return .failure(.notALetter(c)) }
            guard seen.insert(c).inserted else { return .failure(.repeated(c)) }
        }
        guard chars.count >= 2 else { return .failure(.tooShort) }
        return .success(Alphabet(checked: chars))
    }

    /// Vimium's default order: home row first, then the easiest reaches.
    public static let homeRow = Alphabet("sadfjklewcmpgh")!

    public var string: String { String(characters) }

    public func contains(_ c: Character) -> Bool { characters.contains(c) }
}

public enum AlphabetError: Error, Hashable, Sendable {
    case tooShort
    case notALetter(Character)
    case repeated(Character)

    /// One line for the inline error label in Settings.
    public var message: String {
        switch self {
        case .tooShort: "Use at least two letters."
        case .notALetter(let c): "'\(c)' is not a letter a-z."
        case .repeated(let c): "'\(c)' appears twice."
        }
    }
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
