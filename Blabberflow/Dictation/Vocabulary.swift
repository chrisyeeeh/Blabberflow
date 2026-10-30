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
        return result
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
