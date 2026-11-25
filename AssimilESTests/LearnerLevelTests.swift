import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Le niveau de l'apprenant (étape 5b)")
@MainActor
struct LearnerLevelTests {

    static let pack = VocabularyTestTests.pack

    @Test("Sans placement ni objectif actif : aucun niveau")
    func none() throws {
        let container = try Fixture.container()
        #expect(LearnerLevel.current(pack: Self.pack, in: container.mainContext) == nil)
    }

    @Test("Le niveau de l'objectif actif, pas celui d'un objectif repris au cycle 2")
    func activeObjective() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let (start, failedA2) = try DailyPlannerTests.placed(in: context)
        let first = try #require(try DailyPlanner.today(pack: Self.pack, now: Fixture.date(day: 1, hour: 10), in: context))
        #expect(LearnerLevel.current(pack: Self.pack, in: context) == Self.pack.objective(start)?.level)
        #expect(LearnerLevel.current(pack: Self.pack, in: context) == "B1")

        DailyPlannerTests.finish(first, at: Fixture.date(day: 1, hour: 10, minute: 20))
        let second = try #require(try DailyPlanner.newCycle(pack: Self.pack, now: Fixture.date(day: 1, hour: 10, minute: 21),
                                                            in: context))
        #expect(second.objectiveID == failedA2)
        // Le jeu de rôle, la rafale et le texte du bloc 2 restent au niveau B1.
        let roleplay = try #require(SessionConversation.profile(for: second, pack: Self.pack, in: context))
        #expect(roleplay.level == "B1" && !roleplay.hints)
        #expect(SessionAutomation.speedProfile(for: second, pack: Self.pack, in: context).level == "B1")
        guard case .success(let request) = Absorption.request(for: second, pack: Self.pack, in: context) else {
            Issue.record("la demande du texte")
            return
        }
        #expect(request.level == "B1")
    }

    @Test("Sans objectif actif (tout acquis) : le niveau du placement")
    func placementFallback() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let (start, _) = try DailyPlannerTests.placed(in: context)
        let progress = try ObjectiveTracker.progress(language: "es", objectiveID: start, at: .now, in: context)
        progress.status = ObjectiveProgress.Status.acquired
        #expect(LearnerLevel.current(pack: Self.pack, in: context) == PlacementStore.latestCompleted(in: context)?.level)
    }

    @Test("Débutant en A0 et A1 : voix ralentie")
    func beginner() {
        #expect(LearnerLevel.isBeginner("A0") && LearnerLevel.isBeginner("A1"))
        #expect(!LearnerLevel.isBeginner("A2") && !LearnerLevel.isBeginner(nil))
        #expect(LearnerLevel.playbackRate("A1") == 0.85)
        #expect(LearnerLevel.playbackRate("B2") == 1)
    }
}
