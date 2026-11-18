import Foundation
import SwiftData
import Testing
@testable import AssimilES

/// Un hasard rejouable : le même germe donne toujours le même tirage.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite("Placement : le test de vocabulaire")
@MainActor
struct VocabularyTestTests {

    static let pack = try! CurriculumPack.load(from: AdaptiveStateTests.packDirectory, language: "es")

    /// Un lexique de 1 000 lemmes : 2 tranches, 400 mots pleins et 100 mots outils chacune.
    static func lexicon(count: Int = 1000) -> [CurriculumPack.Lexeme] {
        (1...count).map { rank in
            CurriculumPack.Lexeme(rank: rank, lemma: "mot\(rank)", pos: rank % 5 == 0 ? "ADP" : "NOUN",
                                  ipa: "", level: rank <= 600 ? "A1" : "A2")
        }
    }

    static func answers(band: Int, known: Int, of total: Int = 6) -> [VocabularyTest.Answer] {
        (0..<total).map { VocabularyTest.Answer(item: .init(text: "b\(band)-\($0)", band: band), known: $0 < known) }
    }

    static func pseudo(yes: Int, of total: Int) -> [VocabularyTest.Answer] {
        (0..<total).map { VocabularyTest.Answer(item: .init(text: "p\($0)", band: nil), known: $0 < yes) }
    }

    // MARK: Tirage

    @Test("Le paquet donne 10 tranches de 6 mots pleins et 2 non-mots, sans doublon")
    func drawFromPack() {
        var generator = SeededGenerator(state: 7)
        let blocks = VocabularyTest.make(lexicon: Self.pack.lexicon, pseudowords: Self.pack.pseudowords,
                                         using: &generator)
        #expect(blocks.count == 10)
        let lexicon = Dictionary(Self.pack.lexicon.map { ($0.lemma, $0) }, uniquingKeysWith: { a, _ in a })
        for (band, block) in blocks.enumerated() {
            #expect(block.count == 8)
            let words = block.filter { !$0.isPseudoword }
            #expect(words.count == 6)
            for word in words {
                let entry = lexicon[word.text]
                #expect(entry.map { VocabularyTest.askedPOS.contains($0.pos) } == true, "\(word.text)")
                #expect(entry.map { ($0.rank - 1) / VocabularyTest.bandSize } == band, "\(word.text)")
            }
        }
        let all = blocks.flatMap { $0 }.map(\.text)
        #expect(Set(all).count == all.count)
        #expect(all.filter { Self.pack.pseudowords.contains($0) }.count == 20)
    }

    @Test("Le tirage change d'une fois à l'autre, pas avec le même germe")
    func drawIsRandom() {
        var a = SeededGenerator(state: 1), b = SeededGenerator(state: 1), c = SeededGenerator(state: 2)
        let first = VocabularyTest.make(lexicon: Self.pack.lexicon, pseudowords: Self.pack.pseudowords, using: &a)
        #expect(first == VocabularyTest.make(lexicon: Self.pack.lexicon, pseudowords: Self.pack.pseudowords, using: &b))
        #expect(first != VocabularyTest.make(lexicon: Self.pack.lexicon, pseudowords: Self.pack.pseudowords, using: &c))
    }

    @Test("Aucun lemme inventé par spaCy ne reste dans le lexique")
    func noFakeLemmas() {
        let lemmas = Set(Self.pack.lexicon.map(\.lemma))
        for fake in ["erar", "seriar", "dimir", "dir", "distar", "rugir", "salgar", "empecer", "vendar", "morar"] {
            #expect(!lemmas.contains(fake), "\(fake)")
        }
    }

    // MARK: Calcul

    @Test("La correction LexTALE : (oui aux mots − oui aux non-mots) / (1 − oui aux non-mots)")
    func correction() {
        #expect(VocabularyTest.correctedRate(hits: 1, falseAlarms: 0) == 1)
        #expect(VocabularyTest.correctedRate(hits: 0.75, falseAlarms: 0.5) == 0.5)
        #expect(VocabularyTest.correctedRate(hits: 0.2, falseAlarms: 0.5) == 0)
        #expect(VocabularyTest.correctedRate(hits: 1, falseAlarms: 1) == 0)
    }

    @Test("Tout connu, aucun non-mot accepté : tout le lexique")
    func perfect() {
        let lexicon = Self.lexicon()
        let answers = Self.answers(band: 0, known: 6) + Self.answers(band: 1, known: 6) + Self.pseudo(yes: 0, of: 4)
        let outcome = VocabularyTest.outcome(answers: answers, lexicon: lexicon, stoppedEarly: false)
        #expect(outcome.estimate == 1000)
        #expect(outcome.level == "A2")
        #expect(outcome.isReliable)
    }

    @Test("Les mots outils comptent toujours ; les mots pleins selon la part connue")
    func functionWordsCount() {
        let lexicon = Self.lexicon()
        // Tranche 0 : moitié connue ; tranche 1 : rien. 100 + 400 × 0,5 + 100 + 0.
        let answers = Self.answers(band: 0, known: 3) + Self.answers(band: 1, known: 0) + Self.pseudo(yes: 0, of: 4)
        let outcome = VocabularyTest.outcome(answers: answers, lexicon: lexicon, stoppedEarly: false)
        #expect(outcome.estimate == 400)
        #expect(outcome.level == "A1")
    }

    @Test("Dire oui à tout ne donne rien, et l'écran prévient")
    func yesToEverything() {
        let lexicon = Self.lexicon()
        let answers = Self.answers(band: 0, known: 6) + Self.answers(band: 1, known: 6) + Self.pseudo(yes: 4, of: 4)
        let outcome = VocabularyTest.outcome(answers: answers, lexicon: lexicon, stoppedEarly: false)
        #expect(outcome.estimate == 200) // les mots outils seuls
        #expect(!outcome.isReliable)
    }

    @Test("Sous 150 lemmes, le niveau est A0")
    func levelA0() {
        #expect(VocabularyTest.level(estimate: 149, lexicon: Self.pack.lexicon) == "A0")
        #expect(VocabularyTest.level(estimate: 150, lexicon: Self.pack.lexicon) == "A1")
        #expect(VocabularyTest.level(estimate: 2300, lexicon: Self.pack.lexicon) == "B1")
        #expect(VocabularyTest.level(estimate: 9000, lexicon: Self.pack.lexicon) == "C1")
    }

    @Test("Arrêt après deux tranches de suite sous 20 %")
    func stopRule() {
        let base = Self.answers(band: 0, known: 6) + Self.pseudo(yes: 0, of: 2)
        #expect(!VocabularyTest.shouldStop(after: base))
        let oneLow = base + Self.answers(band: 1, known: 1)
        #expect(!VocabularyTest.shouldStop(after: oneLow))
        let twoLow = oneLow + Self.answers(band: 2, known: 0)
        #expect(VocabularyTest.shouldStop(after: twoLow))
    }

    @Test("« Environ 2 300 mots » : à la cinquantaine")
    func rounding() {
        #expect(VocabularyTest.rounded(2_318) == 2_300)
        #expect(VocabularyTest.rounded(2_330) == 2_350)
    }

    // MARK: Passage

    @Test("Un passage s'arrête tôt quand on ne connaît plus rien, et le doigt qui glisse se rattrape")
    func run() {
        let lexicon = Self.lexicon(count: 2000)
        let blocks = (0..<4).map { band in
            (0..<6).map { VocabularyTest.Item(text: "b\(band)-\($0)", band: band) }
                + [VocabularyTest.Item(text: "p\(band)", band: nil)]
        }
        let run = VocabularyTestRun(blocks: blocks, lexicon: lexicon)
        #expect(run.items.count == 28)
        run.answer(known: true)
        #expect(run.canUndo)
        run.undo()
        #expect(run.answers.isEmpty)
        for item in run.items {
            guard run.current != nil else { break }
            run.answer(known: item.band == 0)
        }
        #expect(run.outcome?.stoppedEarly == true)
        #expect(run.answers.count == 21) // trois tranches, pas quatre
        #expect(run.current == nil)
        #expect(!run.canUndo)
    }

    @Test("Le vocabulaire fini ouvre un passage non validé, qui remplace le précédent")
    func draft() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let outcome = VocabularyTest.outcome(answers: Self.answers(band: 0, known: 6) + Self.pseudo(yes: 0, of: 2),
                                             lexicon: Self.pack.lexicon, stoppedEarly: true)
        PlacementStore.startWithVocabulary(outcome, at: Fixture.date(day: 1), in: context)
        let second = PlacementStore.startWithVocabulary(outcome, at: Fixture.date(day: 2), in: context)
        #expect(try context.fetchCount(FetchDescriptor<PlacementResult>()) == 1)
        #expect(PlacementStore.draft(in: context) === second)
        #expect(second.placementDetails.vocabulary == outcome)
        #expect(second.lexiconEstimate == outcome.estimate)
        #expect(PlacementStore.latestCompleted(in: context) == nil)

        // Un passage validé n'est jamais remplacé.
        second.completedAt = Fixture.date(day: 2)
        PlacementStore.startWithVocabulary(outcome, at: Fixture.date(day: 3), in: context)
        #expect(try context.fetchCount(FetchDescriptor<PlacementResult>()) == 2)
        #expect(PlacementStore.latestCompleted(in: context) === second)
    }
}
