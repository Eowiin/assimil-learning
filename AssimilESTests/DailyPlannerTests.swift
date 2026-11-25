import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Séance adaptative : le choix du jour")
@MainActor
struct DailyPlannerTests {

    static let pack = VocabularyTestTests.pack

    /// Un placement validé en B1 le jour 1 : A2 réussi avec un défi raté, B1 raté avec un défi montré.
    static func placed(in context: ModelContext) throws -> (start: String, failedA2: String) {
        let (result, failedA2, _) = PlacementCompletionTests.draft(in: context)
        let start = try #require(try PlacementCompletion.complete(result, workingLevel: "B1", pack: pack,
                                                                  at: Fixture.date(day: 1), in: context))
        return (start, failedA2)
    }

    static func status(_ id: String, in context: ModelContext) throws -> String? {
        try PlacementCompletionTests.status(id, in: context)
    }

    @Test("Sans placement validé, pas de séance")
    func needsPlacement() throws {
        let container = try Fixture.container()
        #expect(try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 1), in: container.mainContext) == nil)
    }

    @Test("La séance du jour : l'objectif de départ, le rappel, les mots nouveaux, le premier thème ; une seule par jour")
    func firstDay() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let (start, failedA2) = try Self.placed(in: context)
        let session = try #require(try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 1, hour: 10),
                                                          in: context))
        #expect(session.objectiveID == start)
        #expect(session.reinjectObjectiveID == failedA2)
        #expect(session.theme == Self.pack.themes.first?.id)
        #expect(session.key == "es:2026-09-01")

        // Les mots nouveaux : 7 mots pleins, au-delà de la frontière (500 ici), inconnus.
        #expect(session.newLemmas.count == DailyPlanner.newLemmaCount)
        let ranks = Self.pack.ranks
        let frontier = try #require(PlacementStore.latestCompleted(in: context)).lexiconEstimate
        for lemma in session.newLemmas {
            #expect((ranks[lemma] ?? 0) > frontier, "\(lemma)")
            #expect(Self.pack.lexicon.first { $0.lemma == lemma }.map { DailyPlanner.newLemmaPOS.contains($0.pos) } == true)
        }

        let again = try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 1, hour: 20), in: context)
        #expect(again === session)
        #expect(try context.fetchCount(FetchDescriptor<StudySession>()) == 1)
    }

    @Test("Un mot déjà vu n'est plus proposé")
    func seenWordsSkipped() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        _ = try Self.placed(in: context)
        let first = try DailyPlanner.newLemmas(pack: Self.pack, frontier: 500, in: context)
        context.insert(LexemeState(language: "es", lemma: first[0], rank: nil, source: "input", at: .now))
        let second = try DailyPlanner.newLemmas(pack: Self.pack, frontier: 500, in: context)
        #expect(!second.contains(first[0]))
        #expect(Array(second.prefix(6)) == Array(first.dropFirst()))
    }

    @Test("Deux jours actif sans être acquis : il passe à réinjecter, le suivant s'ouvre ; le thème tourne")
    func softUnlock() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let (start, _) = try Self.placed(in: context)
        try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 1, hour: 10), in: context)
        let dayTwo = try #require(try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 2, hour: 10), in: context))
        #expect(dayTwo.objectiveID == start)
        #expect(dayTwo.theme == Self.pack.themes[1].id)

        let dayThree = try #require(try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 3, hour: 10),
                                                           in: context))
        #expect(dayThree.objectiveID != start)
        #expect(try Self.status(start, in: context) == ObjectiveProgress.Status.toReinject)
        #expect(try Self.status(try #require(dayThree.objectiveID), in: context) == ObjectiveProgress.Status.active)
        // Le suivant dans l'ordre du parcours, au même niveau.
        let order = Self.pack.objectives.map(\.id)
        #expect((order.firstIndex(of: dayThree.objectiveID!) ?? 0) > (order.firstIndex(of: start) ?? 0))
    }

    @Test("Un objectif acquis : le suivant s'ouvre le lendemain")
    func acquiredMovesOn() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let (start, _) = try Self.placed(in: context)
        let progress = try ObjectiveTracker.progress(language: "es", objectiveID: start, at: .now, in: context)
        for day in 1...3 {
            ObjectiveTracker.record(ObjectiveEvidence(objectiveKey: progress.key, at: Fixture.date(day: day),
                                                      source: ObjectiveEvidence.Source.conversation, valid: true),
                                    on: progress, in: context)
        }
        #expect(progress.isAcquired)
        let session = try #require(try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 2), in: context))
        #expect(session.objectiveID != start)
        #expect(session.objectiveID.flatMap(Self.pack.objective)?.level == "B1")
    }

    // MARK: Les cycles (étape 5a)

    static func finish(_ session: StudySession, at date: Date) {
        for block in StudyBlock.allCases { StudySessionProgress.skip(block, seconds: 0, in: session, at: date) }
    }

    @Test("Un cycle de plus une fois le précédent fait : un objectif repris, les mots du jour, un autre thème")
    func secondCycle() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let (start, failedA2) = try Self.placed(in: context)
        let first = try #require(try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 1, hour: 10), in: context))
        // Pas tant que le premier n'est pas fait.
        #expect(try DailyPlanner.newCycle(pack: Self.pack, now: Fixture.date(day: 1, hour: 10, minute: 5), in: context) == nil)

        Self.finish(first, at: Fixture.date(day: 1, hour: 10, minute: 20))
        let second = try #require(try DailyPlanner.newCycle(pack: Self.pack, now: Fixture.date(day: 1, hour: 10, minute: 21),
                                                            in: context))
        #expect(second.cycle == 2)
        #expect(second.key == "es:2026-09-01#2")
        #expect(first.key == "es:2026-09-01")
        // L'objectif laissé de côté au placement, pas celui du jour ; le parcours n'avance pas.
        #expect(second.objectiveID == failedA2)
        #expect(second.reinjectObjectiveID == nil)
        #expect(try Self.status(start, in: context) == ObjectiveProgress.Status.active)
        #expect(second.newLemmas == first.newLemmas)
        #expect(second.theme == Self.pack.themes[1].id)
        // L'accueil montre désormais le deuxième.
        #expect(try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 1, hour: 11), in: context) === second)
        // Pas de troisième tant que le deuxième n'est pas fait.
        #expect(try DailyPlanner.newCycle(pack: Self.pack, now: Fixture.date(day: 1, hour: 11), in: context) == nil)

        // Plus rien à réinjecter de neuf : un acquis à entretenir.
        Self.finish(second, at: Fixture.date(day: 1, hour: 10, minute: 40))
        let third = try #require(try DailyPlanner.newCycle(pack: Self.pack, now: Fixture.date(day: 1, hour: 10, minute: 41),
                                                           in: context))
        let thirdID = try #require(third.objectiveID)
        #expect(thirdID != start && thirdID != failedA2)
        #expect(try Self.status(thirdID, in: context) == ObjectiveProgress.Status.acquired)
        #expect(third.newLemmas == first.newLemmas)
        #expect(try DailyPlanner.cycles(language: "es", day: Fixture.date(day: 1), in: context).map(\.cycle) == [1, 2, 3])

        // Le lendemain, un premier cycle neuf, de nouveaux mots.
        let dayTwo = try #require(try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 2, hour: 9), in: context))
        #expect(dayTwo.cycle == 1 && dayTwo.objectiveID == start)
        #expect(dayTwo.key == "es:2026-09-02")
    }

    @Test("Chaque cycle ne relit que son écrit ; la rafale prend le thème du cycle d'avant")
    func cycleScoped() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        _ = try Self.placed(in: context)
        let first = try #require(try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 1, hour: 10), in: context))
        let writing = WritingRecord(writtenAt: Fixture.date(day: 1, hour: 10, minute: 15), language: "es",
                                    objectiveID: first.objectiveID, prompt: nil, text: "Hola")
        context.insert(writing)
        Self.finish(first, at: Fixture.date(day: 1, hour: 10, minute: 20))
        let second = try #require(try DailyPlanner.newCycle(pack: Self.pack, now: Fixture.date(day: 1, hour: 10, minute: 21),
                                                            in: context))
        #expect(SessionAutomation.writing(for: first, in: context) === writing)
        #expect(SessionAutomation.writing(for: second, in: context) == nil)
        #expect(SessionAutomation.familiarTheme(for: second, pack: Self.pack, in: context)?.id == first.theme)
    }
}

@Suite("Séance adaptative : l'avancement des blocs")
@MainActor
struct StudyBlockProgressTests {

    @Test("Ordre fixe ; un bloc passé compte comme réglé ; fait, il n'est plus passé")
    func order() {
        var blocks = StudyBlockProgress()
        #expect(blocks.next == .surgery)
        blocks.skip(.surgery, at: Fixture.date(day: 1))
        #expect(blocks.next == .absorption)
        blocks.complete(.surgery, at: Fixture.date(day: 1))
        #expect(blocks.skipped[.surgery] == nil && blocks.completed[.surgery] != nil)
        // Un bloc fait ne devient pas passé.
        blocks.skip(.surgery, at: Fixture.date(day: 1))
        #expect(blocks.skipped[.surgery] == nil)
        blocks.add(90, to: .absorption)
        blocks.add(30, to: .absorption)
        blocks.add(-5, to: .absorption)
        #expect(blocks.seconds[.absorption] == 120)
        #expect(blocks.totalSeconds == 120)
    }

    @Test("La séance est faite quand les quatre blocs sont faits ou passés")
    func sessionDone() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let session = StudySession(language: "es", day: Fixture.date(day: 1), objectiveID: "obj_051",
                                   startedAt: Fixture.date(day: 1))
        context.insert(session)
        StudySessionProgress.complete(.surgery, seconds: 600, in: session, at: Fixture.date(day: 1))
        StudySessionProgress.skip(.absorption, seconds: 0, in: session, at: Fixture.date(day: 1))
        StudySessionProgress.addTime(120, to: .conversation, in: session)
        StudySessionProgress.complete(.conversation, seconds: 300, in: session, at: Fixture.date(day: 1))
        #expect(session.completedAt == nil)
        StudySessionProgress.complete(.automation, seconds: 900, in: session, at: Fixture.date(day: 1, hour: 11))
        #expect(session.completedAt == Fixture.date(day: 1, hour: 11))
        #expect(session.blocks.seconds[.conversation] == 420)
        #expect(AdaptiveSessionView.detail(.absorption, blocks: session.blocks) == "Passé")
        #expect(AdaptiveSessionView.detail(.surgery, blocks: session.blocks) == "Fait · 10 min")
    }

    @Test("Une partie de bloc se coche une fois, et se relit")
    func parts() throws {
        let session = StudySession(language: "es", day: Fixture.date(day: 1), objectiveID: nil,
                                   startedAt: Fixture.date(day: 1))
        StudySessionProgress.markPart(SurgeryPart.microlesson.key, in: session, at: Fixture.date(day: 1, hour: 10))
        StudySessionProgress.markPart(SurgeryPart.microlesson.key, in: session, at: Fixture.date(day: 1, hour: 11))
        #expect(session.blocks.parts == ["surgery.microlesson": Fixture.date(day: 1, hour: 10)])
        let decoded = try JSONDecoder().decode(StudyBlockProgress.self, from: session.blocksData)
        #expect(decoded.parts.count == 1)
        #expect(!decoded.isSettled(.surgery))
    }

    @Test("Un avancement d'avant les blocs passés se relit")
    func oldJSON() throws {
        let blocks = try JSONDecoder().decode(StudyBlockProgress.self, from: Data(#"{"completed":{},"seconds":{}}"#.utf8))
        #expect(blocks.skipped.isEmpty && blocks.next == .surgery)
    }

    @Test("Le temps d'un bloc ne court qu'au premier plan")
    func clock() {
        var clock = BlockClock()
        clock.resume(at: Fixture.date(day: 1, hour: 10))
        clock.pause(at: Fixture.date(day: 1, hour: 10, minute: 5))
        // En arrière-plan : rien ne s'ajoute.
        clock.resume(at: Fixture.date(day: 1, hour: 11))
        #expect(clock.seconds(at: Fixture.date(day: 1, hour: 11, minute: 2)) == 7 * 60)
        #expect(clock.take(at: Fixture.date(day: 1, hour: 11, minute: 2)) == 7 * 60)
        #expect(clock.seconds(at: Fixture.date(day: 1, hour: 11, minute: 3)) == 60)
    }

    @Test("La carte de l'accueil dit où l'on en est")
    func homeLine() {
        var blocks = StudyBlockProgress()
        blocks.complete(.surgery, at: .now)
        #expect(TodayView.adaptiveProgress(blocks) == "Bloc 2 sur 4 · Absorption")
        for block in StudyBlock.allCases { blocks.skip(block, at: .now) }
        #expect(TodayView.adaptiveProgress(blocks) == "Faite")
    }

    @Test("Les thèmes du paquet : une trentaine, chacun en espagnol et en français, sans doublon")
    func themes() {
        let themes = DailyPlannerTests.pack.themes
        #expect((25...40).contains(themes.count))
        #expect(Set(themes.map(\.id)).count == themes.count)
        #expect(themes.allSatisfy { !$0.es.isEmpty && !$0.fr.isEmpty })
    }
}
