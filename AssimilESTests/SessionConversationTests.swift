import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Séance adaptative : le bloc Conversation")
@MainActor
struct SessionConversationTests {

    static let pack = VocabularyTestTests.pack

    static func review(uses: [(String, Bool)]?, lemmas: [String]? = ["cumbre", "subir"]) -> ConversationReview {
        ConversationReview(corrections: [],
                           objectiveUses: uses?.map { ObjectiveUse(said: $0.0, valid: $0.1, analysis: "—") },
                           lemmasProduced: lemmas)
    }

    static func progress(of session: StudySession, in context: ModelContext) throws -> ObjectiveProgress {
        try ObjectiveTracker.progress(language: "es", objectiveID: try #require(session.objectiveID),
                                      at: Fixture.date(day: 2), in: context)
    }

    @Test("Le profil : jeu de rôle, niveau et objectif du jour, mots connus et mots du texte, sans faute à surveiller")
    func profile() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        _ = try DailyPlannerTests.placed(in: context)
        let session = AbsorptionTests.session(in: context)
        let objective = try #require(Self.pack.objectives.first)

        // Sans texte, pas de mots du jour.
        let before = try #require(SessionConversation.profile(for: session, pack: Self.pack, in: context))
        #expect(before.mode == "roleplay")
        #expect(before.level == objective.level)
        #expect(before.objective?.id == objective.id)
        #expect(before.watch == nil)
        #expect(before.words.isEmpty)
        #expect(!before.allowedLemmas.contains("madrugar"))
        #expect(before.allowedLemmas.count >= 500)

        // Avec le texte : les mots que l'IA a employés, pas ceux qu'elle a laissés.
        session.newLemmas = ["cumbre", "mochila", "madrugar", "inexistente"]
        Absorption.store(try AbsorptionTests.text(), in: session)
        let after = try #require(SessionConversation.profile(for: session, pack: Self.pack, in: context))
        #expect(after.words == ["cumbre", "mochila", "madrugar"])
        #expect(after.allowedLemmas.contains("madrugar"))
        #expect(!after.allowedLemmas.contains("inexistente"))
        #expect(Set(after.allowedLemmas).count == after.allowedLemmas.count)

        session.objectiveID = nil
        #expect(SessionConversation.profile(for: session, pack: Self.pack, in: context) == nil)
    }

    @Test("Le récapitulatif : chaque emploi au journal, une réussite au plus par conversation, mots produits, partie cochée")
    func record() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let session = AbsorptionTests.session(in: context)
        let progress = try Self.progress(of: session, in: context)
        #expect(progress.successes == 0)

        try SessionConversation.record(Self.review(uses: [("a", true), ("b", false), ("c", true)]), in: session,
                                       pack: Self.pack, at: Fixture.date(day: 2, hour: 10), in: context)
        let evidences = try context.fetch(FetchDescriptor<ObjectiveEvidence>())
        #expect(evidences.count == 3)
        #expect(evidences.allSatisfy { $0.source == ObjectiveEvidence.Source.conversation && $0.objectiveKey == progress.key })
        #expect(progress.successes == 1)
        #expect(!progress.isAcquired)
        #expect(session.blocks.parts[SessionConversation.part] != nil)
        let states = try context.fetch(FetchDescriptor<LexemeState>())
        #expect(Set(states.map(\.lemma)) == ["cumbre", "subir"])
        #expect(states.allSatisfy { $0.status == LexemeState.Status.recognized })
        let tally = SessionConversation.tally(for: session, language: "es", in: context)
        #expect(tally.valid == 2 && tally.total == 3)

        // Une conversation sans réussite ne compte pas ; deux autres réussies l'acquièrent.
        try SessionConversation.record(Self.review(uses: [("d", false)]), in: session, pack: Self.pack,
                                       at: Fixture.date(day: 2, hour: 11), in: context)
        #expect(progress.successes == 1)
        try SessionConversation.record(Self.review(uses: [("e", true)]), in: session, pack: Self.pack,
                                       at: Fixture.date(day: 2, hour: 12), in: context)
        #expect(progress.successes == 2)
        try SessionConversation.record(Self.review(uses: [("f", true), ("g", true)]), in: session, pack: Self.pack,
                                       at: Fixture.date(day: 3), in: context)
        #expect(progress.successes == 3)
        #expect(progress.isAcquired)
        #expect(progress.acquiredAt == Fixture.date(day: 3))
    }

    @Test("Sans objectif jugé ni spaCy : aucune preuve, aucun mot, la partie est cochée quand même")
    func recordWithoutObjective() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let session = AbsorptionTests.session(in: context)
        try SessionConversation.record(Self.review(uses: nil, lemmas: nil), in: session, pack: Self.pack,
                                       at: Fixture.date(day: 2), in: context)
        #expect(try context.fetch(FetchDescriptor<ObjectiveEvidence>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<LexemeState>()).isEmpty)
        #expect(session.blocks.parts[SessionConversation.part] != nil)
        #expect(SessionConversation.tally(for: session, language: "es", in: context) == (0, 0))
    }

    @Test("Une seule preuve isolée compte comme avant")
    func singleEvidence() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let progress = ObjectiveProgress(language: "es", objectiveID: "obj_x", status: ObjectiveProgress.Status.active,
                                         at: Fixture.date(day: 1))
        context.insert(progress)
        for day in 1...3 {
            ObjectiveTracker.record(ObjectiveEvidence(objectiveKey: progress.key, at: Fixture.date(day: day),
                                                      source: ObjectiveEvidence.Source.writing, valid: true),
                                    on: progress, in: context)
        }
        #expect(progress.isAcquired)
        // Le placement situe, il ne compte pas.
        let other = ObjectiveProgress(language: "es", objectiveID: "obj_y", at: Fixture.date(day: 1))
        context.insert(other)
        ObjectiveTracker.recordProduction(
            [ObjectiveEvidence(objectiveKey: other.key, at: Fixture.date(day: 1), source: ObjectiveEvidence.Source.placement,
                               valid: true)], on: other, in: context)
        #expect(other.successes == 0)
    }
}
