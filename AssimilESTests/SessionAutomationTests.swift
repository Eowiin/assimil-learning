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

    @Test("La rafale : mode speed, ni objectif ni mots du jour, mesurée sur les seuls mots connus")
    func speedProfile() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let session = AbsorptionTests.session(in: context)
        Absorption.store(try AbsorptionTests.text(), in: session)
        for lemma in ["viejo", "activo"] {
            let state = LexemeState(language: "es", lemma: lemma, rank: nil, source: "test", at: Fixture.date(day: 1))
            state.raise(to: lemma == "activo" ? LexemeState.Status.active : LexemeState.Status.recognized,
                        at: Fixture.date(day: 1, hour: 8))
            context.insert(state)
        }
        let profile = SessionAutomation.speedProfile(for: session, pack: Self.pack, in: context)
        #expect(profile.mode == "speed")
        #expect(profile.objective == nil && profile.watch == nil && profile.words.isEmpty)
        #expect(profile.level == Self.pack.objectives.first?.level)
        #expect(Set(profile.allowedLemmas) == ["viejo", "activo"])

        session.objectiveID = nil
        #expect(SessionAutomation.speedProfile(for: session, pack: Self.pack, in: context).level == nil)
    }

    @Test("Le thème de la rafale : celui d'une séance d'avant qui diffère du jour ; à la première, celui du jour")
    func familiarTheme() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let session = AbsorptionTests.session(in: context)
        let themes = Self.pack.themes
        #expect(SessionAutomation.familiarTheme(for: session, pack: Self.pack, in: context)?.id == themes[0].id)

        for (day, theme) in [(0, themes[1]), (1, themes[0]), (3, themes[2])] {
            let other = StudySession(language: "es", day: Fixture.date(day: day), objectiveID: nil,
                                     startedAt: Fixture.date(day: day), calendar: Fixture.calendar)
            other.theme = theme.id
            context.insert(other)
        }
        #expect(SessionAutomation.familiarTheme(for: session, pack: Self.pack, in: context)?.id == themes[1].id)
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
        let prompt = SessionAutomation.writingPrompt(for: session, pack: Self.pack, level: "B1")
        #expect(prompt.hasPrefix("Écris 50 à 80 mots sur ce thème : \(theme.fr.lowercasedFirst)."))
        #expect(prompt.hasSuffix("« \(reinject.title) »."))
        // Un débutant écrit un message court (étape 5b).
        #expect(SessionAutomation.writingPrompt(for: session, pack: Self.pack, level: "A1").hasPrefix("Écris 15 à 30 mots"))
        #expect(SessionAutomation.writingWords(level: "A0") == 15...30)
        #expect(SessionAutomation.writingWords(level: "C1") == 50...80)
        #expect(SessionAutomation.writingWords(level: nil) == 50...80)
    }

    @Test("L'orthographe reprise dans deux productions ajoute un rappel des accents à la consigne")
    func accentReminder() throws {
        let container = try Fixture.container()
        let session = AbsorptionTests.session(in: container.mainContext)
        let accent = ConversationCorrection(said: "compre", corrected: "compré", explanation: "",
                                            category: .spelling, tag: "accent écrit")
        let tilde = ConversationCorrection(said: "manana", corrected: "mañana", explanation: "",
                                           category: .spelling, tag: "tilde")
        let once = ErrorPatterns(productions: [.init(date: Fixture.date(day: 1), kind: .writing,
                                                     corrections: [accent, tilde])])
        #expect(!SessionAutomation.writingPrompt(for: session, pack: Self.pack, level: "B1", patterns: once)
            .contains("Attention aux accents écrits."))
        // Deux points différents, mais deux productions : l'orthographe revient.
        let twice = ErrorPatterns(productions: [
            .init(date: Fixture.date(day: 1), kind: .writing, corrections: [accent]),
            .init(date: Fixture.date(day: 2), kind: .conversation, corrections: [tilde]),
        ])
        #expect(SessionAutomation.writingPrompt(for: session, pack: Self.pack, level: "B1", patterns: twice)
            .hasSuffix("». Attention aux accents écrits."))
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
