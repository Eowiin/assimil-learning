import Foundation
import Observation

/// Le test de vocabulaire du placement (décision 6 du moteur adaptatif) : des mots du
/// lexique, du plus fréquent au plus rare, mêlés de non-mots, façon LexTALE. On répond
/// « je connais » ou non, sans traduire : c'est rapide, et les non-mots corrigent la
/// surestimation (dire oui à un mot inventé fait baisser le score).
///
/// Le lexique (5 000 lemmes) est coupé en tranches de 500 rangs. Chaque tranche donne
/// 6 mots pleins (noms, verbes, adjectifs, adverbes) et 2 non-mots, mélangés. Les mots
/// outils (el, de, que…) ne sont pas demandés : ils comptent comme connus.
enum VocabularyTest {

    static let bandSize = 500
    static let wordsPerBand = 6
    static let pseudowordsPerBand = 2
    /// Les catégories demandées. Les autres (déterminants, prépositions, pronoms…) sont
    /// les mots outils, tous dans les premiers rangs.
    static let askedPOS: Set<String> = ["NOUN", "VERB", "ADJ", "ADV"]
    /// Deux tranches de suite sous ce taux corrigé : le reste ne serait que des « non ».
    static let stopBelow = 0.2
    /// Au-delà de ce taux de oui aux non-mots, l'estimation n'est plus sûre.
    static let reliableFalseAlarms = 0.3
    /// Sous ce nombre de lemmes, le niveau est A0 (le lexique ne commence qu'en A1).
    static let minimumForA1 = 150

    /// Une question : un mot du lexique (sa tranche) ou un non-mot.
    struct Item: Codable, Equatable, Hashable, Sendable {
        let text: String
        /// La tranche du mot, de 0 à 9 ; nil pour un non-mot.
        let band: Int?

        var isPseudoword: Bool { band == nil }
    }

    struct Answer: Codable, Equatable, Sendable {
        let item: Item
        let known: Bool
    }

    /// Les tranches du lexique : combien de lemmes, dont combien de mots pleins.
    struct Band: Equatable {
        let lemmas: Int
        let content: Int
    }

    /// Le résultat, gardé tel quel dans `PlacementResult.details`.
    struct Outcome: Codable, Equatable, Sendable {
        /// Le vocabulaire passif estimé, en lemmes.
        let estimate: Int
        let level: String
        /// La part de oui aux non-mots.
        let falseAlarmRate: Double
        /// La part connue de chaque tranche demandée, corrigée par les non-mots.
        let bandRates: [Double]
        let stoppedEarly: Bool
        let answers: [Answer]

        var isReliable: Bool { falseAlarmRate <= VocabularyTest.reliableFalseAlarms }
        /// Les mots du lexique auxquels on a répondu oui.
        var knownWords: [String] { answers.filter { $0.known && !$0.item.isPseudoword }.map(\.item.text) }
    }

    // MARK: Tirage

    static func bands(of lexicon: [CurriculumPack.Lexeme]) -> [Band] {
        stride(from: 0, to: lexicon.count, by: bandSize).map { start in
            let slice = lexicon[start..<min(start + bandSize, lexicon.count)]
            return Band(lemmas: slice.count, content: slice.filter { askedPOS.contains($0.pos) }.count)
        }
    }

    /// Les questions, tranche par tranche, de la plus fréquente à la plus rare. Dans une
    /// tranche, mots et non-mots sont mélangés.
    static func make<G: RandomNumberGenerator>(lexicon: [CurriculumPack.Lexeme], pseudowords: [String],
                                               using generator: inout G) -> [[Item]] {
        var pseudo = pseudowords.shuffled(using: &generator)[...]
        return stride(from: 0, to: lexicon.count, by: bandSize).enumerated().map { band, start in
            let candidates = lexicon[start..<min(start + bandSize, lexicon.count)]
                .filter { askedPOS.contains($0.pos) }
            var items = candidates.shuffled(using: &generator).prefix(wordsPerBand)
                .map { Item(text: $0.lemma, band: band) }
            items += pseudo.prefix(pseudowordsPerBand).map { Item(text: $0, band: nil) }
            pseudo = pseudo.dropFirst(pseudowordsPerBand)
            return items.shuffled(using: &generator)
        }
    }

    static func make(lexicon: [CurriculumPack.Lexeme], pseudowords: [String]) -> [[Item]] {
        var generator = SystemRandomNumberGenerator()
        return make(lexicon: lexicon, pseudowords: pseudowords, using: &generator)
    }

    // MARK: Calcul

    static func falseAlarmRate(_ answers: [Answer]) -> Double {
        let pseudo = answers.filter(\.item.isPseudoword)
        guard !pseudo.isEmpty else { return 0 }
        return Double(pseudo.filter(\.known).count) / Double(pseudo.count)
    }

    /// La part connue d'une tranche, corrigée de la tendance à dire oui :
    /// (oui aux mots − oui aux non-mots) / (1 − oui aux non-mots), entre 0 et 1.
    static func correctedRate(hits: Double, falseAlarms: Double) -> Double {
        guard falseAlarms < 1 else { return 0 }
        return min(1, max(0, (hits - falseAlarms) / (1 - falseAlarms)))
    }

    /// Les parts corrigées des tranches demandées jusqu'ici, dans l'ordre.
    static func bandRates(_ answers: [Answer]) -> [Double] {
        let falseAlarms = falseAlarmRate(answers)
        let byBand = Dictionary(grouping: answers.filter { !$0.item.isPseudoword }) { $0.item.band ?? 0 }
        guard let last = byBand.keys.max() else { return [] }
        return (0...last).map { band in
            let words = byBand[band] ?? []
            guard !words.isEmpty else { return 0 }
            return correctedRate(hits: Double(words.filter(\.known).count) / Double(words.count),
                                 falseAlarms: falseAlarms)
        }
    }

    /// Faut-il s'arrêter, une tranche finie ? Oui quand ses deux dernières tranches sont
    /// sous `stopBelow` : on ne connaît presque plus rien, les suivantes sont plus rares.
    static func shouldStop(after answers: [Answer]) -> Bool {
        let rates = bandRates(answers)
        guard rates.count >= 2 else { return false }
        return rates.suffix(2).allSatisfy { $0 < stopBelow }
    }

    /// L'estimation : dans chaque tranche demandée, les mots outils plus la part connue
    /// des mots pleins. Les tranches non demandées (arrêt anticipé) comptent pour zéro.
    static func outcome(answers: [Answer], lexicon: [CurriculumPack.Lexeme], stoppedEarly: Bool) -> Outcome {
        let bands = bands(of: lexicon)
        let rates = bandRates(answers)
        let estimate = zip(bands, rates).reduce(0.0) { total, pair in
            let (band, rate) = pair
            return total + Double(band.lemmas - band.content) + Double(band.content) * rate
        }
        let lemmas = Int(estimate.rounded())
        return Outcome(estimate: lemmas, level: level(estimate: lemmas, lexicon: lexicon),
                       falseAlarmRate: falseAlarmRate(answers), bandRates: rates,
                       stoppedEarly: stoppedEarly, answers: answers)
    }

    /// Le niveau du lemme dont le rang vaut l'estimation : connaître les 2 300 premiers
    /// mots, c'est le vocabulaire de B1 (`build_lexicon.py`, `NIVEAUX`). Le lexique
    /// s'arrête en C1.
    static func level(estimate: Int, lexicon: [CurriculumPack.Lexeme]) -> String {
        guard estimate >= minimumForA1, !lexicon.isEmpty else { return "A0" }
        return lexicon[min(estimate, lexicon.count) - 1].level
    }

    /// « environ 2 300 mots » : la cinquantaine près suffit, le test n'est pas plus précis.
    static func rounded(_ estimate: Int) -> Int {
        Int((Double(estimate) / 50).rounded()) * 50
    }
}

/// Un passage du test, question par question. La règle est ici, l'écran affiche.
@Observable
@MainActor
final class VocabularyTestRun {
    private let lexicon: [CurriculumPack.Lexeme]
    /// Toutes les questions à la suite, et l'indice de fin de chaque tranche.
    let items: [VocabularyTest.Item]
    private let bandEnds: Set<Int>
    private(set) var answers: [VocabularyTest.Answer] = []
    /// Le résultat, une fois le test fini (au bout, ou par l'arrêt anticipé).
    private(set) var outcome: VocabularyTest.Outcome?

    init(blocks: [[VocabularyTest.Item]], lexicon: [CurriculumPack.Lexeme]) {
        self.lexicon = lexicon
        items = blocks.flatMap { $0 }
        var ends = Set<Int>()
        var total = 0
        for block in blocks {
            total += block.count
            ends.insert(total)
        }
        bandEnds = ends
    }

    convenience init(pack: CurriculumPack) {
        self.init(blocks: VocabularyTest.make(lexicon: pack.lexicon, pseudowords: pack.pseudowords),
                  lexicon: pack.lexicon)
    }

    var current: VocabularyTest.Item? { outcome == nil && answers.count < items.count ? items[answers.count] : nil }
    var progress: Double { items.isEmpty ? 1 : Double(answers.count) / Double(items.count) }
    var canUndo: Bool { outcome == nil && !answers.isEmpty }

    func answer(known: Bool) {
        guard let item = current else { return }
        answers.append(VocabularyTest.Answer(item: item, known: known))
        let count = answers.count
        if count == items.count {
            outcome = VocabularyTest.outcome(answers: answers, lexicon: lexicon, stoppedEarly: false)
        } else if bandEnds.contains(count), VocabularyTest.shouldStop(after: answers) {
            outcome = VocabularyTest.outcome(answers: answers, lexicon: lexicon, stoppedEarly: true)
        }
    }

    /// Un doigt qui a glissé : on revient sur la dernière réponse.
    func undo() {
        guard canUndo else { return }
        answers.removeLast()
    }
}
