import Foundation
import Testing
@testable import AssimilES

/// La frontière lexicale de l'accueil (étape 5c) : les lemmes connus sur 5 000, et la
/// part du corpus qu'ils couvrent.
@MainActor
struct LexicalFrontierTests {

    static let pack = try! CurriculumPack.load(from: AdaptiveStateTests.packDirectory, language: "es")

    @Test("Le paquet porte le total du corpus et les occurrences de chaque lemme")
    func packCounts() throws {
        #expect(Self.pack.lexiconTotal == 413_264_052)
        let first = try #require(Self.pack.lexicon.first)
        #expect(first.lemma == "el" && first.count == 21_204_074)
    }

    @Test("Les 1 000 premiers lemmes couvrent environ 84 % ; tout le lexique, environ 92 %")
    func coverageCurve() throws {
        let thousand = LexicalFrontier.measure(pack: Self.pack, known: Self.pack.lexicon.prefix(1000).map(\.lemma))
        #expect(thousand.known == 1000 && thousand.size == 5000)
        #expect(thousand.coverageLabel == "Environ 84 % de l'espagnol courant")
        let all = LexicalFrontier.measure(pack: Self.pack, known: Self.pack.lexicon.map(\.lemma))
        #expect(try #require(all.coverage) < 0.93)
    }

    @Test("Un mot hors du lexique ou en double ne compte pas ; rien de connu, pas de couverture affichée")
    func outsideAndEmpty() {
        let frontier = LexicalFrontier.measure(pack: Self.pack, known: ["el", "el", "zzzinconnu"])
        #expect(frontier.known == 1)
        #expect(LexicalFrontier.measure(pack: Self.pack, known: []).coverageLabel == nil)
    }

    @Test("Sans total du corpus (un paquet plus ancien), pas de pourcentage")
    func withoutTotal() {
        var pack = Self.pack
        pack.lexiconTotal = 0
        let frontier = LexicalFrontier.measure(pack: pack, known: ["el"])
        #expect(frontier.coverage == nil && frontier.coverageLabel == nil)
        #expect(frontier.wordsLabel.hasPrefix("1 mot sur 5"))
    }
}
