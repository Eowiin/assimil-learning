import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Séance adaptative : le bloc Automatisation")
@MainActor
struct SessionAutomationTests {

    static let pack = VocabularyTestTests.pack

    static func review(uses: [(String, Bool)]?, category: String = "orthographe") throws -> WritingReview {
        let usesJSON = uses.map { list in
            "[" + list.map { #"{"said": "\#($0.0)", "valide": \#($0.1), "analyse_courte": "—"}"# }
                .joined(separator: ",") + "]"
        } ?? "null"
        let json = #"""
        {"corrections": [{"said": "compre pan", "corrected": "compré pan", "explanation": "Accent.",
                          "category": "\#(category)", "tag": "accent écrit"}],
         "corrected_text": "Ayer compré pan.", "objective_uses": \#(usesJSON), "lemmas_produced": ["comprar", "pan"]}
        """#
        return try JSONDecoder().decode(WritingReview.self, from: Data(json.utf8))
    }

    @Test("La correction se lit, catégorie orthographe comprise ; une catégorie inconnue ne perd rien")
    func decoding() throws {
        let review = try Self.review(uses: [("Ayer compré pan.", true)])
        #expect(review.corrections.first?.category == .spelling)
        #expect(review.correctedText == "Ayer compré pan.")
        #expect(review.objectiveUses?.first?.valid == true)
        #expect(review.lemmasProduced == ["comprar", "pan"])
        let unknown = try Self.review(uses: nil, category: "ponctuation")
        #expect(unknown.corrections.count == 1 && unknown.corrections.first?.category == nil)
        #expect(unknown.objectiveUses == nil)
    }

    @Test("La rafale : mode speed, l'objectif du jour, les mots du jour puis les reconnus les plus récents")
    func speedProfile() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let session = AbsorptionTests.session(in: context)
        Absorption.store(try AbsorptionTests.text(), in: session)
        for (index, lemma) in ["viejo", "nuevo", "activo"].enumerated() {
            let state = LexemeState(language: "es", lemma: lemma, rank: nil, source: "test", at: Fixture.date(day: 1))
            state.raise(to: lemma == "activo" ? LexemeState.Status.active : LexemeState.Status.recognized,
                        at: Fixture.date(day: 1, hour: 8 + index))
            context.insert(state)
        }
        let profile = try #require(SessionAutomation.speedProfile(for: session, pack: Self.pack, in: context))
        #expect(profile.mode == "speed")
        #expect(profile.objective?.id == session.objectiveID)
        #expect(profile.watch == nil)
        #expect(profile.words == ["cumbre", "mochila", "madrugar", "nuevo", "viejo"])

        session.objectiveID = nil
        #expect(SessionAutomation.speedProfile(for: session, pack: Self.pack, in: context) == nil)
    }

    @Test("L'écrit rappelle l'objectif à réinjecter, sinon celui du jour ; la consigne dit le thème et l'objectif")
    func prompt() throws {
        let container = try Fixture.container()
        let session = AbsorptionTests.session(in: container.mainContext)
        let today = try #require(Self.pack.objectives.first)
        let reinject = Self.pack.objectives[1]
        let theme = try #require(Self.pack.themes.first)
        #expect(SessionAutomation.writingObjective(for: session, pack: Self.pack)?.id == today.id)
        session.reinjectObjectiveID = reinject.id
        #expect(SessionAutomation.writingObjective(for: session, pack: Self.pack)?.id == reinject.id)
        let prompt = SessionAutomation.writingPrompt(for: session, pack: Self.pack)
        #expect(prompt.hasPrefix("Écris 80 à 120 mots sur ce thème : \(theme.fr.lowercasedFirst)."))
        #expect(prompt.hasSuffix("« \(reinject.title) »."))
    }

    @Test("À l'écrit, un accent changé ressort ; à l'oral, non")
    func accentDiff() {
        let written = WordDiff.compare(said: "Ayer compre pan.", corrected: "Ayer compré pan.", accents: true)
        #expect(written.said.map(\.changed) == [false, true, false])
        #expect(written.corrected.map(\.changed) == [false, true, false])
        let spoken = WordDiff.compare(said: "Ayer compre pan.", corrected: "Ayer compré pan.")
        #expect(spoken.said.allSatisfy { !$0.changed })
    }

    @Test("Le compteur : les mots, pas la ponctuation seule")
    func wordCount() {
        #expect(SessionAutomation.wordCount("Hola, ¿qué tal?  Bien — gracias.\nAdiós") == 6)
        #expect(SessionAutomation.wordCount("  ") == 0)
    }

    @Test("La correction arrivée : gardée, une réussite au plus, mots produits, partie cochée, une seule fois")
    func recordWriting() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let session = AbsorptionTests.session(in: context)
        let reinject = Self.pack.objectives[1]
        session.reinjectObjectiveID = reinject.id
        let record = WritingRecord(writtenAt: Fixture.date(day: 2, hour: 9), language: "es", objectiveID: reinject.id,
                                   prompt: "p", text: "Ayer compre pan.")
        context.insert(record)
        #expect(SessionAutomation.writing(for: session, in: context) === record)

        let review = try Self.review(uses: [("a", true), ("b", true), ("c", false)])
        try SessionAutomation.recordWriting(review, on: record, in: session, pack: Self.pack,
                                            at: Fixture.date(day: 2, hour: 10), in: context)
        #expect(record.writingReview == review)
        let evidences = try context.fetch(FetchDescriptor<ObjectiveEvidence>())
        #expect(evidences.count == 3)
        #expect(evidences.allSatisfy { $0.source == ObjectiveEvidence.Source.writing
                                         && $0.objectiveKey == "es:\(reinject.id)" })
        let progress = try ObjectiveTracker.progress(language: "es", objectiveID: reinject.id,
                                                     at: Fixture.date(day: 2), in: context)
        #expect(progress.successes == 1)
        #expect(Set(try context.fetch(FetchDescriptor<LexemeState>()).map(\.lemma)) == ["comprar", "pan"])
        #expect(session.blocks.parts[AutomationPart.writing.key] != nil)

        // Une deuxième remise de la même correction ne compte rien de plus.
        try SessionAutomation.recordWriting(review, on: record, in: session, pack: Self.pack,
                                            at: Fixture.date(day: 2, hour: 11), in: context)
        #expect(try context.fetch(FetchDescriptor<ObjectiveEvidence>()).count == 3)
        #expect(progress.successes == 1)
    }

    @Test("La rafale coche sa partie, pas celle du jeu de rôle")
    func speedPart() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let session = AbsorptionTests.session(in: context)
        let review = ConversationReview(corrections: [], objectiveUses: [ObjectiveUse(said: "x", valid: true, analysis: "")],
                                        lemmasProduced: [])
        try SessionConversation.record(review, in: session, pack: Self.pack, part: AutomationPart.speed.key,
                                       at: Fixture.date(day: 2), in: context)
        #expect(session.blocks.parts[AutomationPart.speed.key] != nil)
        #expect(session.blocks.parts[SessionConversation.part] == nil)
    }
}
