import Foundation

/// Makes dictionary words come out spelled exactly as the user wrote them.
enum Vocabulary {
    /// Replaces close matches of each term with the term itself: "github" or "git hub" → "GitHub",
    /// "a p i" or "a.p.i." → "API". Longer terms go first so "GitHub Actions" wins over "GitHub".
    static func apply(_ terms: [String], to text: String) -> String {
        var result = text
        for term in terms.sorted(by: { $0.count > $1.count }) where !term.isEmpty {
            guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + pattern(for: term) + "(?![\\p{L}\\p{N}])", options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: term))
        }
        return replacingSoundAlikes(of: terms, in: result)
    }

    /// Names the recogniser misspells ("Cleo" for Clio, "Mini" for Miny). Only words it capitalised
    /// mid-sentence, as it does for names it doesn't know, so ordinary words like "many" are left alone.
    /// The word must start with the same letter, have the same consonants and differ by a letter or two.
    private static func replacingSoundAlikes(of terms: [String], in text: String) -> String {
        let candidates = terms.filter { $0.count >= 3 && $0.allSatisfy(\.isLetter) }
        guard !candidates.isEmpty, let wordPattern = try? NSRegularExpression(pattern: "\\p{Lu}\\p{Ll}+") else { return text }
        var result = text
        let matches = wordPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            guard let range = Range(match.range, in: result), !startsSentence(at: range.lowerBound, in: result) else { continue }
            let word = String(result[range])
            let lowered = word.lowercased()
            guard let term = candidates.first(where: { term in
                let target = term.lowercased()
                guard target != lowered, target.first == lowered.first, consonants(target) == consonants(lowered) else { return false }
                return distance(target, lowered) <= (target.count >= 7 ? 2 : 1)
            }) else { continue }
            result.replaceSubrange(range, with: term)
        }
        return result
    }

    private static func startsSentence(at index: String.Index, in text: String) -> Bool {
        let before = text[..<index].reversed().drop(while: \.isWhitespace)
        guard let previous = before.first else { return true }
        return ".!?\n".contains(previous)
    }

    /// The word's consonants with repeats collapsed: "cleo" and "clio" → "cl", "mini" and "miny" → "mn".
    private static func consonants(_ word: String) -> String {
        var skeleton = ""
        for character in word where !"aeiouy".contains(character) && character != skeleton.last {
            skeleton.append(character)
        }
        return skeleton
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func pattern(for term: String) -> String {
        // Short all-caps acronyms are often heard letter by letter. A dot after the last letter is left
        // alone, since it's usually the end of the sentence.
        if term.count <= 6, term.count > 1, term.allSatisfy({ $0.isLetter && $0.isUppercase }) {
            return term.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s.]?")
        }
        // Long single words are often heard as two ("blabber flow"), so allow one space anywhere in them.
        if term.count >= 7, term.allSatisfy(\.isLetter) {
            let letters = term.map { NSRegularExpression.escapedPattern(for: String($0)) }
            return letters.joined(separator: "\\s?")
        }
        // Otherwise allow a space wherever the term changes from lower to upper case ("Git Hub").
        var pattern = ""
        var previous: Character?
        for character in term {
            if let previous, previous.isLowercase, character.isUppercase { pattern += "\\s?" }
            pattern += character == " " ? "\\s+" : NSRegularExpression.escapedPattern(for: String(character))
            previous = character
        }
        return pattern
    }
}
