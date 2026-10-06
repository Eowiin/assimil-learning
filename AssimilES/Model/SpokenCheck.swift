import Foundation

/// Une réponse dite à voix haute, comparée à la réponse attendue.
///
/// **« Identique », ou pas : c'est tout ce que l'app affirme.** La comparaison est la
/// règle de `SpanishMatch` — lettres et chiffres seuls, sans accents, ponctuation,
/// majuscules ni espaces —, qui vaut pour le français comme pour l'espagnol.
///
/// Elle ne juge pas le sens. Le corrigé d'Assimil n'est qu'une traduction possible
/// (« Comment vas-tu ? » ou « Comment tu vas ? »), et rien sur l'appareil ne sait
/// dire honnêtement si deux phrases veulent dire la même chose : le modèle de langue
/// local d'Apple exige Apple Intelligence, absent de l'iPhone 11, et la proximité
/// entre phrases de NaturalLanguage rapproche « je lis » de « je ne lis pas ». Quand
/// ce n'est pas identique, l'app montre la différence et laisse juger.
struct SpokenResult: Equatable {
    let heard: String
    let isIdentical: Bool
    /// Les mots de la forme attendue la plus proche, chacun dit entendu ou non.
    let words: [WordVerdict]
}

enum SpokenCheck {

    /// Les formes admises : le livre écrit « Je suis né/née en… » pour deux réponses.
    /// Une barre entre deux mots collés vaut alternative ; rien d'autre n'est déduit.
    static func references(_ expected: String) -> [String] {
        guard let match = slash.firstMatch(in: expected, range: NSRange(expected.startIndex..., in: expected)),
              let whole = Range(match.range, in: expected),
              let first = Range(match.range(at: 1), in: expected),
              let second = Range(match.range(at: 2), in: expected)
        else { return [expected] }

        let head = String(expected[..<whole.lowerBound])
        let tails = references(String(expected[whole.upperBound...]))
        return [String(expected[first]), String(expected[second])].flatMap { choice in
            tails.map { head + choice + $0 }
        }
    }

    private static let slash = try! NSRegularExpression(pattern: #"(\p{L}+)/(\p{L}+)"#)

    static func compare(heard: String, expected: String) -> SpokenResult {
        let variants = references(expected)
        let identical = variants.contains { SpanishMatch.isIdentical($0, heard) }
        let closest = variants
            .map { SpanishMatch.compare(reference: $0, heard: heard) }
            .max { $0.filter(\.isUnderstood).count < $1.filter(\.isUnderstood).count } ?? []
        return SpokenResult(heard: heard, isIdentical: identical, words: closest)
    }

    /// Faux quand la réponse contient des chiffres : la reconnaissance écrit « siete »
    /// là où le livre écrit « 7:00 », et un « pas identique » ne voudrait rien dire.
    static func isJudgeable(_ expected: String) -> Bool {
        !expected.contains { $0.isNumber }
    }
}
