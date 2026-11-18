import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Placement : la conversation de calibrage")
@MainActor
struct CalibrationTests {

    static func review(corrections: Int, noise: Int = 0) -> ConversationReview {
        let real = (0..<corrections).map {
            ConversationCorrection(said: "Yo soy cansado \($0)", corrected: "Estoy cansado \($0)", explanation: "")
        }
        let fake = (0..<noise).map {
            ConversationCorrection(said: "que tal \($0)", corrected: "¿Qué tal \($0)?", explanation: "")
        }
        return ConversationReview(corrections: real + fake, objectiveUses: nil, lemmasProduced: ["estar"])
    }

    @Test("Plus de la moitié des phrases corrigées : un cran plus bas")
    func lowered() {
        let outcome = CalibrationOutcome.make(review: Self.review(corrections: 3), learnerSentences: 5,
                                              level: "B1", objectiveID: "obj_051")
        #expect(outcome.proposedLevel == "A2")
        #expect(outcome.lowered)
        #expect(outcome.corrected == 3)
        #expect(outcome.lemmasProduced == ["estar"])
    }

    @Test("La moitié ou moins : le niveau reste ; une correction qui ne change rien ne compte pas")
    func kept() {
        #expect(CalibrationOutcome.make(review: Self.review(corrections: 2, noise: 2), learnerSentences: 4,
                                        level: "B1", objectiveID: nil).proposedLevel == "B1")
    }

    @Test("Trop peu de phrases pour juger, ou déjà en A0 : rien ne change")
    func edges() {
        #expect(CalibrationOutcome.make(review: Self.review(corrections: 2), learnerSentences: 2,
                                        level: "B1", objectiveID: nil).proposedLevel == "B1")
        #expect(CalibrationOutcome.make(review: Self.review(corrections: 5), learnerSentences: 5,
                                        level: "A0", objectiveID: nil).proposedLevel == "A0")
        let skipped = CalibrationOutcome.skipped(level: "B2")
        #expect(skipped.skipped && skipped.proposedLevel == "B2" && !skipped.lowered)
    }

    @Test("Un mot produit est reconnu, et actif au deuxième jour où on le produit")
    func production() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let ranks = ["estar": 12]
        try KnownVocabulary.recordProduction(["estar", "estar"], language: "es", ranks: ranks, source: "conversation",
                                             at: Fixture.date(day: 1), in: context)
        try KnownVocabulary.recordProduction(["estar"], language: "es", ranks: ranks, source: "conversation",
                                             at: Fixture.date(day: 1, hour: 18), in: context)
        var state = try #require(try context.fetch(FetchDescriptor<LexemeState>()).first)
        #expect(state.status == LexemeState.Status.recognized)
        #expect(state.productionDays == 1)
        #expect(state.productions == 2)
        #expect(state.rank == 12)
        try KnownVocabulary.recordProduction(["estar"], language: "es", ranks: ranks, source: "conversation",
                                             at: Fixture.date(day: 3), in: context)
        state = try #require(try context.fetch(FetchDescriptor<LexemeState>()).first)
        #expect(state.status == LexemeState.Status.active)
        #expect(state.productionDays == 2)
        #expect(try context.fetchCount(FetchDescriptor<LexemeState>()) == 1)
    }

    @Test("Les lemmes connus : la frontière du placement, plus les mots reconnus, sans doublon")
    func known() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let pack = VocabularyTestTests.pack
        let rare = try #require(pack.lexicon.last).lemma
        let seen = LexemeState(language: "es", lemma: "vu", rank: nil, source: "input", at: .now)
        let recognized = LexemeState(language: "es", lemma: rare, rank: 5000, source: "assimil", at: .now)
        recognized.raise(to: LexemeState.Status.recognized, at: .now)
        let first = LexemeState(language: "es", lemma: pack.lexicon[0].lemma, rank: 1, source: "assimil", at: .now)
        first.raise(to: LexemeState.Status.active, at: .now)
        let lemmas = KnownVocabulary.lemmas(pack: pack, estimate: 100, states: [seen, recognized, first])
        #expect(lemmas.count == 101)
        #expect(lemmas.prefix(100) == pack.lexicon.prefix(100).map(\.lemma)[...])
        #expect(lemmas.last == rare)
        #expect(!lemmas.contains("vu"))
    }

    @Test("Un passage sans calibrage se relit")
    func oldDetails() throws {
        let details = try JSONDecoder().decode(PlacementDetails.self, from: Data(#"{"challenges":[]}"#.utf8))
        #expect(details.calibration == nil)
    }
}
