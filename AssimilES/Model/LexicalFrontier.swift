import Foundation

/// La frontière lexicale (`docs/moteur-adaptatif.md`, étape 5c) : combien des 5 000
/// lemmes du lexique l'apprenant connaît, et quelle part de l'espagnol courant ils
/// couvrent. Les lemmes connus sont ceux de `KnownVocabulary` (la frontière du
/// placement, plus les mots reconnus ou actifs) ; un mot hors du lexique ne compte pas.
struct LexicalFrontier: Equatable {
    /// Les lemmes connus, parmi ceux du lexique.
    let known: Int
    /// La taille du lexique (5 000).
    let size: Int
    /// La part des mots du corpus (sous-titres) que ces lemmes couvrent, de 0 à 1. Nil
    /// sans le total du corpus.
    let coverage: Double?

    static func measure(pack: CurriculumPack, known lemmas: [String]) -> LexicalFrontier {
        let knownSet = Set(lemmas)
        let entries = pack.lexicon.filter { knownSet.contains($0.lemma) }
        let covered = entries.reduce(0) { $0 + ($1.count ?? 0) }
        let coverage = pack.lexiconTotal > 0 ? min(1, Double(covered) / Double(pack.lexiconTotal)) : nil
        return LexicalFrontier(known: entries.count, size: pack.lexicon.count, coverage: coverage)
    }

    /// « 1 240 mots sur 5 000 », en chiffres à la française.
    var wordsLabel: String {
        let french = IntegerFormatStyle<Int>.number.locale(Locale(identifier: "fr_FR"))
        return "\(known.formatted(french)) \(known > 1 ? "mots" : "mot") sur \(size.formatted(french))"
    }

    /// « Environ 84 % de l'espagnol courant », arrondi à l'unité inférieure : une
    /// estimation, pas une promesse.
    var coverageLabel: String? {
        guard let coverage, known > 0 else { return nil }
        return "Environ \(Int((coverage * 100).rounded(.down))) % de l'espagnol courant"
    }
}
