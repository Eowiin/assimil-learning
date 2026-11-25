import Foundation
import SwiftData
import Testing
@testable import AssimilES

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite("Placement : les défis, niveau par niveau")
@MainActor
struct ChallengeWalkTests {

    static let pack = VocabularyTestTests.pack
    static var challenges: [PlacementChallenge] { pack.challenges }

    /// Les défis d'un niveau jugés, dans l'ordre, sans en reprendre un déjà posé.
    static func judge(_ level: String, _ verdicts: [ChallengeVerdict],
                      after records: [ChallengeRecord] = []) -> [ChallengeRecord] {
        let used = Set(records.map(\.challengeID))
        let available = challenges.filter { $0.level == level && !used.contains($0.id) }
        return records + zip(available, verdicts).map { challenge, verdict in
            ChallengeRecord(challengeID: challenge.id, objectiveID: challenge.objective, level: level,
                            answer: "réponse", verdict: verdict, analysis: "")
        }
    }

    static func next(_ records: [ChallengeRecord], start: String = "B1") -> ChallengeWalk.Step {
        var generator = SeededGenerator(state: 3)
        return ChallengeWalk.next(records: records, start: start, challenges: challenges, using: &generator)
    }

    static func asked(_ step: ChallengeWalk.Step) -> (level: String, count: Int)? {
        if case .ask(let level, let challenges) = step { return (level, challenges.count) }
        return nil
    }

    @Test("On commence au niveau du vocabulaire, par 4 défis de ce niveau")
    func start() {
        guard case .ask(let level, let drawn) = Self.next([]) else { Issue.record("rien à poser"); return }
        #expect(level == "B1")
        #expect(drawn.count == 4)
        #expect(drawn.allSatisfy { $0.level == "B1" })
        #expect(Set(drawn.map(\.id)).count == 4)
        // A0 n'a que 3 défis.
        #expect(Self.asked(Self.next([], start: "A0"))?.count == 3)
        // Le vocabulaire s'arrête en C1 ; un niveau inconnu repart du plus proche en dessous.
        #expect(ChallengeWalk.startLevel(vocabulary: "C1", challenges: Self.challenges) == "C1")
    }

    @Test("On monte tant que ça passe ; le premier échec est le niveau de travail")
    func goingUp() {
        let b1 = Self.judge("B1", [.shown, .shown, .shown, .wrong])
        #expect(Self.asked(Self.next(b1))?.level == "B2")
        let b2 = Self.judge("B2", [.shown, .wrong, .shown, .wrong], after: b1)
        #expect(Self.next(b2) == .done(workingLevel: "B2"))
    }

    @Test("Le premier niveau raté : on descend jusqu'à un niveau réussi, et on travaille au-dessus")
    func goingDown() {
        let b1 = Self.judge("B1", [.wrong, .wrong, .shown, .wrong])
        #expect(Self.asked(Self.next(b1))?.level == "A2")
        let a2 = Self.judge("A2", [.wrong, .shown, .wrong, .shown], after: b1)
        #expect(Self.asked(Self.next(a2))?.level == "A1")
        let a1 = Self.judge("A1", [.shown, .shown, .shown, .shown], after: a2)
        #expect(Self.next(a1) == .done(workingLevel: "A2"))
    }

    @Test("Tout raté jusqu'en A0 : on travaille en A0 ; tout réussi jusqu'en C2 : en C2")
    func ends() {
        let a0 = Self.judge("A0", [.wrong, .wrong, .wrong])
        #expect(Self.next(a0, start: "A0") == .done(workingLevel: "A0"))
        let c2 = Self.judge("C2", [.shown, .shown, .shown, .shown])
        #expect(Self.next(c2, start: "C2") == .done(workingLevel: "C2"))
    }

    @Test("Un défi contourné en fait poser un autre du même niveau, deux fois au plus")
    func replacements() {
        let first = Self.judge("B1", [.shown, .correctNotShown, .shown, .shown])
        #expect(Self.asked(Self.next(first))! == ("B1", 1))
        let second = Self.judge("B1", [.shown], after: first)
        #expect(Self.asked(Self.next(second))?.level == "B2")

        let many = Self.judge("B1", [.correctNotShown, .correctNotShown, .correctNotShown, .shown])
        #expect(Self.asked(Self.next(many))! == ("B1", 2))
        let more = Self.judge("B1", [.correctNotShown, .wrong], after: many)
        // 6 défis posés, la limite : 1 montré sur 2 tranchés, le niveau est raté.
        #expect(Self.asked(Self.next(more))?.level == "A2")
    }

    @Test("Seuil : les trois quarts des défis tranchés")
    func passRate() {
        #expect(ChallengeWalk.LevelOutcome(level: "B1", shown: 3, wrong: 1, notShown: 0).passed)
        #expect(!ChallengeWalk.LevelOutcome(level: "B1", shown: 2, wrong: 1, notShown: 1).passed)
        #expect(ChallengeWalk.LevelOutcome(level: "B1", shown: 2, wrong: 0, notShown: 2).passed)
        #expect(!ChallengeWalk.LevelOutcome(level: "B1", shown: 0, wrong: 0, notShown: 4).passed)
    }

    @Test("Aucun défi n'est posé deux fois")
    func noRepeat() {
        var records: [ChallengeRecord] = []
        var generator = SeededGenerator(state: 11)
        while case .ask(let level, let drawn) = ChallengeWalk.next(records: records, start: "A1",
                                                                    challenges: Self.challenges, using: &generator) {
            records += drawn.map { ChallengeRecord(challengeID: $0.id, objectiveID: $0.objective, level: level,
                                                   answer: "", verdict: .shown, analysis: "") }
        }
        #expect(Set(records.map(\.challengeID)).count == records.count)
        #expect(ChallengeWalk.outcomes(records).map(\.level) == ["A1", "A2", "B1", "B2", "C1", "C2"])
    }
}

@Suite("Placement : le juge et la validation")
@MainActor
struct PlacementCompletionTests {

    static let pack = VocabularyTestTests.pack

    @Test("La requête suit le contrat du serveur, la réponse se lit")
    func client() async throws {
        let challenge = try #require(Self.pack.challenges.first { $0.id == "pc_064" })
        var sent: [String: Any] = [:]
        let session = StubProtocol.session(host: "placement.ts.net") { request in
            #expect(request.url?.path() == "/placement/evaluate")
            sent = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
            return (200, Data(#"[{"objective_id":"obj_064","verdict":"correct_not_shown","analyse_courte":"Contourne."}]"#.utf8))
        }
        let client = PlacementClient(baseURL: URL(string: "https://placement.ts.net")!, session: session)
        let verdicts = try await client.evaluate(level: "B1", items: [PlacementItem(challenge, answer: "debe de estar")])
        #expect(verdicts == [PlacementJudgement(objectiveID: "obj_064", verdict: .correctNotShown, analysis: "Contourne.")])
        #expect(sent["level"] as? String == "B1")
        let item = try #require((sent["items"] as? [[String: Any]])?.first)
        #expect(item["objective_id"] as? String == "obj_064")
        #expect(item["also_correct"] as? [String] == ["debe de estar"])
        #expect(item["answer"] as? String == "debe de estar")
        #expect(item["expected"] as? [String] == ["estará"])
    }

    @Test("Un verdict qui manque est une erreur, pas un trou")
    func incomplete() async throws {
        let challenge = try #require(Self.pack.challenges.first)
        let session = StubProtocol.session(host: "placement-trou.ts.net") { _ in (200, Data("[]".utf8)) }
        let client = PlacementClient(baseURL: URL(string: "https://placement-trou.ts.net")!, session: session)
        await #expect(throws: ServerError.self) {
            try await client.evaluate(level: "A0", items: [PlacementItem(challenge, answer: "x")])
        }
    }

    @Test("Un passage de l'étape 3a, sans défis, se relit")
    func oldDetails() throws {
        let details = try JSONDecoder().decode(PlacementDetails.self, from: Data(#"{}"#.utf8))
        #expect(details.challenges.isEmpty && details.vocabulary == nil)
    }

    /// Un passage : vocabulaire fiable, A2 réussi avec un défi raté, B1 raté avec un défi montré.
    static func draft(in context: ModelContext) -> (PlacementResult, failedA2: String, shownB1: String) {
        let answers = [VocabularyTest.Answer(item: .init(text: "casa", band: 0), known: true),
                       VocabularyTest.Answer(item: .init(text: "abajero", band: nil), known: false)]
        let outcome = VocabularyTest.outcome(answers: answers, lexicon: pack.lexicon, stoppedEarly: true)
        let result = PlacementStore.startWithVocabulary(outcome, at: Fixture.date(day: 1), in: context)
        var records = ChallengeWalkTests.judge("A2", [.shown, .shown, .shown, .wrong])
        records = ChallengeWalkTests.judge("B1", [.wrong, .shown, .wrong, .wrong], after: records)
        var details = result.placementDetails
        details.challenges = records
        result.placementDetails = details
        return (result, records[3].objectiveID, records[5].objectiveID)
    }

    static func status(_ id: String, in context: ModelContext) throws -> String? {
        let key = AdaptiveKey.make(language: "es", id)
        return try context.fetch(FetchDescriptor<ObjectiveProgress>(predicate: #Predicate { $0.key == key })).first?.status
    }

    @Test("Valider écrit les objectifs, le départ, les preuves et les mots reconnus")
    func complete() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let (result, failedA2, shownB1) = Self.draft(in: context)
        let date = Fixture.date(day: 2)
        let start = try PlacementCompletion.complete(result, workingLevel: "B1", pack: Self.pack, at: date, in: context)

        let firstB1 = try #require(Self.pack.objectives.first { $0.level == "B1" && $0.id != shownB1 })
        #expect(start == firstB1.id)
        #expect(start == PlacementCompletion.previewStart(workingLevel: "B1", records: result.placementDetails.challenges,
                                                          pack: Self.pack)?.id)
        #expect(try Self.status(firstB1.id, in: context) == ObjectiveProgress.Status.active)
        #expect(try Self.status(failedA2, in: context) == ObjectiveProgress.Status.toReinject)
        #expect(try Self.status(shownB1, in: context) == ObjectiveProgress.Status.acquired)
        // En dessous, sans défi : acquis. Au-dessus : verrouillé.
        let a1 = try #require(Self.pack.objectives.first { $0.level == "A1" })
        #expect(try Self.status(a1.id, in: context) == ObjectiveProgress.Status.acquired)
        let b2 = try #require(Self.pack.objectives.first { $0.level == "B2" })
        #expect(try Self.status(b2.id, in: context) == ObjectiveProgress.Status.locked)
        #expect(try context.fetchCount(FetchDescriptor<ObjectiveProgress>()) == 125)

        let evidence = try context.fetch(FetchDescriptor<ObjectiveEvidence>())
        #expect(evidence.count == 8)
        #expect(evidence.allSatisfy { $0.source == ObjectiveEvidence.Source.placement })
        #expect(evidence.filter(\.valid).count == 4)
        // Un défi ne compte pas comme production spontanée.
        let progress = try context.fetch(FetchDescriptor<ObjectiveProgress>())
        #expect(progress.allSatisfy { $0.successes == 0 })

        let lexemes = try context.fetch(FetchDescriptor<LexemeState>())
        #expect(lexemes.map(\.lemma) == ["casa"])
        #expect(lexemes.first?.status == LexemeState.Status.recognized)
        #expect(lexemes.first?.source == PlacementCompletion.lexemeSource)

        #expect(result.completedAt == date)
        #expect(result.level == "B1")
        #expect(result.startObjectiveID == start)
        #expect(PlacementStore.draft(in: context) == nil)
        #expect(PlacementStore.latestCompleted(in: context) === result)
    }

    @Test("Un objectif acquis en conversation le reste, même sous un niveau plus haut choisi")
    func spontaneousKept() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let (result, _, _) = Self.draft(in: context)
        let b2 = try #require(Self.pack.objectives.first { $0.level == "B2" })
        let progress = try ObjectiveTracker.progress(language: "es", objectiveID: b2.id, at: Fixture.date(day: 1),
                                                     in: context)
        progress.status = ObjectiveProgress.Status.acquired
        progress.successes = 3
        // Ethan choisit A1 : tout est remis en jeu au-dessus, sauf l'acquis spontané.
        try PlacementCompletion.complete(result, workingLevel: "A1", pack: Self.pack, at: Fixture.date(day: 2), in: context)
        #expect(try Self.status(b2.id, in: context) == ObjectiveProgress.Status.acquired)
        let a2 = try #require(Self.pack.objectives.first { $0.level == "A2" })
        #expect(result.level == "A1")
        #expect(try Self.status(a2.id, in: context) != ObjectiveProgress.Status.active)
    }
}
