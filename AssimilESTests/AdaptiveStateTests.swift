import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Moteur adaptatif : référentiel et état de l'apprenant")
@MainActor
struct AdaptiveStateTests {

    /// Le paquet du dépôt, lu à sa place : le test suit les fichiers versionnés.
    static let packDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/curriculum/es", isDirectory: true)

    // MARK: Référentiel

    @Test("Le paquet espagnol se lit en entier, chaque objectif a sa micro-leçon et son défi")
    func packLoads() throws {
        let pack = try CurriculumPack.load(from: Self.packDirectory, language: "es")
        #expect(pack.objectives.count == 125)
        #expect(pack.objectives.first?.id == "obj_001" && pack.objectives.last?.id == "obj_125")
        #expect(Set(pack.objectives.map(\.level)).isSubset(of: CurriculumPack.levels))
        for objective in pack.objectives {
            let lesson = try #require(pack.microlessons[objective.id], "micro-leçon de \(objective.id)")
            #expect((1...5).contains(lesson.lines.count), "\(objective.id) : \(lesson.lines.count) lignes")
            #expect(lesson.examples.count == 3, "\(objective.id)")
            #expect(pack.challenges.contains { $0.objective == objective.id }, "défi de \(objective.id)")
        }
        for challenge in pack.challenges where challenge.type == .complete {
            #expect(challenge.prompt.components(separatedBy: "___").count == 2, "\(challenge.id) : un seul trou")
        }
        #expect(pack.challenges.allSatisfy { !$0.expected.isEmpty })
        // Une réponse juste qui contourne l'objectif n'est jamais aussi une réponse attendue.
        for challenge in pack.challenges {
            #expect(Set(challenge.expected).isDisjoint(with: challenge.alsoCorrect), "\(challenge.id)")
        }
        let probability = try #require(pack.challenges.first { $0.id == "pc_064" })
        #expect(probability.expected == ["estará"])
        #expect(probability.alsoCorrect == ["debe de estar"])
        #expect(pack.lexicon.count == 5000)
        #expect(pack.phonemes.count == 28)
        #expect(pack.pseudowords.count >= 40)
        // Aucun non-mot n'est un lemme du lexique.
        #expect(Set(pack.pseudowords).isDisjoint(with: pack.lexicon.map(\.lemma)))
    }

    @Test("Un fichier d'une autre langue est refusé")
    func wrongLanguage() {
        #expect(throws: CurriculumPack.LoadError.wrongLanguage("objectives.json")) {
            try CurriculumPack.load(from: Self.packDirectory, language: "it")
        }
    }

    // MARK: Objectifs

    @Test("Trois productions spontanées réussies acquièrent l'objectif ; un défi ne compte pas")
    func objectiveAcquisition() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let progress = try ObjectiveTracker.progress(language: "es", objectiveID: "obj_029", at: Fixture.date(day: 1),
                                                     in: context)
        ObjectiveTracker.activate(progress, at: Fixture.date(day: 1))
        #expect(progress.status == ObjectiveProgress.Status.active)

        let key = progress.key
        #expect(key == "es:obj_029")
        ObjectiveTracker.record(ObjectiveEvidence(objectiveKey: key, at: Fixture.date(day: 1), source: "placement",
                                                  valid: true), on: progress, in: context)
        ObjectiveTracker.record(ObjectiveEvidence(objectiveKey: key, at: Fixture.date(day: 2), source: "conversation",
                                                  valid: true), on: progress, in: context)
        ObjectiveTracker.record(ObjectiveEvidence(objectiveKey: key, at: Fixture.date(day: 2, hour: 10),
                                                  source: "conversation", valid: false), on: progress, in: context)
        ObjectiveTracker.record(ObjectiveEvidence(objectiveKey: key, at: Fixture.date(day: 3), source: "writing",
                                                  valid: true), on: progress, in: context)
        #expect(progress.successes == 2)
        #expect(!progress.isAcquired)

        ObjectiveTracker.record(ObjectiveEvidence(objectiveKey: key, at: Fixture.date(day: 4), source: "conversation",
                                                  valid: true), on: progress, in: context)
        #expect(progress.isAcquired)
        #expect(progress.acquiredAt == Fixture.date(day: 4))
        #expect(try context.fetch(FetchDescriptor<ObjectiveEvidence>()).count == 5)
        // La même ligne est rendue, pas une deuxième.
        let again = try ObjectiveTracker.progress(language: "es", objectiveID: "obj_029", at: Fixture.date(day: 5),
                                                  in: context)
        #expect(again === progress)
    }

    @Test("Après deux jours actif sans être acquis, l'objectif passe à réinjecter")
    func softUnlock() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let progress = try ObjectiveTracker.progress(language: "es", objectiveID: "obj_051", at: Fixture.date(day: 1),
                                                     in: context)
        ObjectiveTracker.activate(progress, at: Fixture.date(day: 1, hour: 9))
        #expect(!ObjectiveTracker.softUnlockIfDue(progress, now: Fixture.date(day: 3, hour: 8)))
        #expect(ObjectiveTracker.softUnlockIfDue(progress, now: Fixture.date(day: 3, hour: 9)))
        #expect(progress.status == ObjectiveProgress.Status.toReinject)
    }

    // MARK: Lexique

    func vocabCard(_ lemma: String, _ angle: String, created: Int, known: Bool, in context: ModelContext) throws {
        let item = try #require(VocabItem(lemma: lemma)).itemID()
        let card = Card(item: item, angle: angle, language: "es", scheduler: Card.Scheduler.fsrs,
                        at: Fixture.date(day: created))
        if known {
            card.fsrsState = FSRS.State.review.rawValue
            card.lastReviewedAt = Fixture.date(day: created + 2)
        }
        context.insert(card)
    }

    @Test("Les mots révisés dans Assimil entrent dans le lexique : vu, reconnu, actif")
    func assimilWordsMigrate() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        try vocabCard("hablar", Card.Angle.recognize, created: 1, known: true, in: context)
        try vocabCard("hablar", Card.Angle.recall, created: 4, known: true, in: context)
        try vocabCard("casa", Card.Angle.recognize, created: 2, known: true, in: context)
        try vocabCard("aprovechar", Card.Angle.recognize, created: 3, known: false, in: context)
        try vocabCard("qué tal", Card.Angle.recognize, created: 3, known: false, in: context)
        // Une phrase désactivée n'est pas un mot.
        let phrase = Card(item: AssimilItem(lesson: 1, isExercise: false, number: 1).itemID(), angle: Card.Angle.listen,
                          language: "es", scheduler: Card.Scheduler.ladder, at: Fixture.date(day: 1))
        phrase.isActive = false
        context.insert(phrase)
        try context.save()

        let outcome = LexiconMigration.finishIfNeeded(ranks: { ["hablar": 60, "casa": 90] }, in: context,
                                                       now: Fixture.date(day: 10))
        #expect(outcome == .finished(.init(created: 4, raised: 0)))

        let states = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<LexemeState>()).map { ($0.key, $0) })
        #expect(states.count == 4)
        let hablar = try #require(states["es:hablar"])
        #expect(hablar.status == LexemeState.Status.active)
        #expect(hablar.rank == 60)
        #expect(hablar.firstSeenAt == Fixture.date(day: 1))
        #expect(hablar.activeAt == Fixture.date(day: 6))
        #expect(hablar.recognizedAt == Fixture.date(day: 6))
        #expect(states["es:casa"]?.status == LexemeState.Status.recognized)
        #expect(states["es:aprovechar"]?.status == LexemeState.Status.seen)
        #expect(states["es:aprovechar"]?.rank == nil)
        #expect(states["es:qué tal"]?.source == "assimil")

        // Une seule fois.
        #expect(LexiconMigration.finishIfNeeded(ranks: { [:] }, in: context) == .alreadyDone)
    }

    @Test("La reprise ne fait que monter les statuts")
    func absorbOnlyRaises() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let active = LexemeState(language: "es", lemma: "casa", rank: 90, source: "conversation", at: Fixture.date(day: 1))
        active.raise(to: LexemeState.Status.active, at: Fixture.date(day: 2))
        context.insert(active)
        try vocabCard("casa", Card.Angle.recognize, created: 3, known: false, in: context)
        try vocabCard("perro", Card.Angle.recognize, created: 3, known: false, in: context)
        try context.save()

        let first = try LexiconMigration.absorbAssimilCards(ranks: [:], in: context, now: Fixture.date(day: 9),
                                                            calendar: Fixture.calendar)
        #expect(first == .init(created: 1, raised: 0))
        #expect(active.status == LexemeState.Status.active)
        #expect(active.source == "conversation")

        let card = try #require(try context.fetch(FetchDescriptor<Card>()).first { $0.key.contains("perro") })
        card.fsrsState = FSRS.State.review.rawValue
        card.lastReviewedAt = Fixture.date(day: 8)
        let second = try LexiconMigration.absorbAssimilCards(ranks: [:], in: context, now: Fixture.date(day: 9),
                                                             calendar: Fixture.calendar)
        #expect(second == .init(created: 0, raised: 1))
    }

    // MARK: Séance et stockage

    @Test("La séance du jour : une par jour et par langue, ses blocs dans l'ordre")
    func studySession() throws {
        let session = StudySession(language: "es", day: Fixture.date(day: 17, hour: 21), objectiveID: "obj_029",
                                   startedAt: Fixture.date(day: 17, hour: 21), calendar: Fixture.calendar)
        #expect(session.key == "es:2026-09-17")
        #expect(session.blocks.next == .surgery)
        var blocks = session.blocks
        blocks.completed[.surgery] = Fixture.date(day: 17, hour: 21)
        blocks.completed[.absorption] = Fixture.date(day: 17, hour: 22)
        session.blocks = blocks
        #expect(session.blocks.next == .conversation)
        // Rangé en objet JSON lisible, pas en tableau clé-valeur.
        let json = try #require(String(data: session.blocksData, encoding: .utf8))
        #expect(json.contains("\"surgery\""))
    }

    @Test("Un stockage d'avant le moteur adaptatif s'ouvre, cartes intactes, et garde les nouvelles tables")
    func storeBeforeAdaptiveOpens() throws {
        let url = Fixture.storeURL()
        let adaptive: [any PersistentModel.Type] = [ObjectiveProgress.self, ObjectiveEvidence.self, LexemeState.self,
                                                    PlacementResult.self, StudySession.self, WritingRecord.self]
        let ids = Set(adaptive.map { ObjectIdentifier($0) })
        let previous = AssimilESApp.models.filter { !ids.contains(ObjectIdentifier($0)) }
        #expect(previous.count == AssimilESApp.models.count - 6)

        do {
            let container = try Fixture.container(at: url, models: previous)
            try vocabCard("hablar", Card.Angle.recognize, created: 1, known: true, in: container.mainContext)
            try container.mainContext.save()
        }

        let current = try Fixture.container(at: url)
        let context = current.mainContext
        #expect(try context.fetch(FetchDescriptor<Card>()).count == 1)
        context.insert(PlacementResult(takenAt: Fixture.date(day: 5), language: "es", lexiconEstimate: 2400,
                                       level: "A2", startObjectiveID: "obj_029"))
        context.insert(WritingRecord(writtenAt: Fixture.date(day: 5), language: "es", objectiveID: "obj_029",
                                     prompt: nil, text: "Ayer fui al mercado y compré fruta."))
        #expect(LexiconMigration.finishIfNeeded(ranks: { [:] }, in: context) == .finished(.init(created: 1, raised: 0)))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<WritingRecord>()).first?.wordCount == 7)
        #expect(try context.fetch(FetchDescriptor<LexemeState>()).first?.status == LexemeState.Status.recognized)
    }
}
