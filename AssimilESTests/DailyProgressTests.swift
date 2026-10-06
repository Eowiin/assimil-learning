import Foundation
import Testing
@testable import AssimilES

@Suite("Parcours : étapes d'une séance")
struct DailyProgressTests {
    let stages: [DailyStage] = [.discovery, .comprehension, .repetition, .translation, .completion, .finish]

    @Test("La fin de l'audio ne termine aucune étape")
    func audioEndCompletesNothing() {
        var progress = DailyProgress(stages: stages)
        progress.recordAudio(.discovery, sentence: 3)
        progress.recordAudio(.discovery, sentence: nil)

        #expect(progress.completed.isEmpty)
        #expect(progress.current == .discovery)
        #expect(!progress.canValidate(stages))
    }

    @Test("On ne saute pas au-delà de la première étape à faire")
    func noSkippingAhead() {
        var progress = DailyProgress(stages: stages)
        progress.open(.translation, in: stages)
        #expect(progress.current == .discovery)
        do { let done = progress.complete(.repetition, in: stages); #expect(!done) }
        do { let done = progress.complete(.finish, in: stages); #expect(!done) }
    }

    @Test("Passer aux exercices est un geste, qui ouvre la traduction")
    func voluntaryExercises() {
        var progress = DailyProgress(stages: stages)
        do { let done = progress.complete(.discovery, in: stages); #expect(done) }
        #expect(progress.current == .comprehension)
        do { let done = progress.complete(.comprehension, in: stages); #expect(done) }
        #expect(progress.current == .repetition)

        // La répétition finie à l'audio : on reste sur l'étape.
        progress.recordAudio(.repetition, sentence: nil)
        #expect(progress.current == .repetition)

        do { let done = progress.complete(.repetition, in: stages); #expect(done) }
        #expect(progress.current == .translation)
    }

    @Test("Un exercice exige chaque phrase, ou la confirmation du livre")
    func exercisesNeedEveryItem() {
        var progress = DailyProgress(stages: stages)
        for stage in [DailyStage.discovery, .comprehension, .repetition] {
            progress.complete(stage, in: stages)
        }

        do { let done = progress.complete(.translation, in: stages, items: [1, 2]); #expect(!done) }
        progress.setReveal(.translation, 1, RevealState(revealed: true, outcome: .knew))
        do { let done = progress.complete(.translation, in: stages, items: [1, 2]); #expect(!done) }
        // Affiché mais pas évalué : pas fait.
        progress.setReveal(.translation, 2, RevealState(revealed: true, outcome: nil))
        do { let done = progress.complete(.translation, in: stages, items: [1, 2]); #expect(!done) }
        progress.setReveal(.translation, 2, RevealState(revealed: true, outcome: .notYet))
        do { let done = progress.complete(.translation, in: stages, items: [1, 2]); #expect(done) }

        // Exercice 2 non importé : aucun élément, seule la confirmation le termine.
        do { let done = progress.complete(.completion, in: stages, items: []); #expect(!done) }
        progress.doneInBook.insert(.completion)
        do { let done = progress.complete(.completion, in: stages, items: []); #expect(done) }

        #expect(progress.canValidate(stages))
        #expect(progress.current == .finish)
    }

    @Test("Revenir sur une étape faite ne la défait pas")
    func revisiting() {
        var progress = DailyProgress(stages: stages)
        progress.complete(.discovery, in: stages)
        progress.complete(.comprehension, in: stages)
        progress.open(.discovery, in: stages)

        #expect(progress.current == .discovery)
        #expect(progress.completed == [.discovery, .comprehension])
        #expect(progress.frontier(in: stages) == .repetition)
        #expect(progress.isReachable(.repetition, in: stages))
        #expect(!progress.isReachable(.translation, in: stages))
    }

    @Test("Une phrase à compléter compte une fois réussie ou corrigée")
    func fillInItems() {
        var progress = DailyProgress(stages: stages)
        var attempt = progress.fillIn(1)
        attempt.checks = 2
        progress.setFillIn(1, attempt)
        #expect(!progress.isDone(.completion, items: [1, 2]))

        attempt.solved = true
        progress.setFillIn(1, attempt)
        var other = FillInAttempt()
        other.revealed = true
        progress.setFillIn(2, other)
        #expect(progress.isDone(.completion, items: [1, 2]))
    }

    @Test("L'avancement se relit même incomplet ou d'une version future")
    func tolerantDecoding() throws {
        let json = #"{"current":"repetition","completed":["discovery","etapeInconnue"],"audioSentence":{"repetition":4}}"#
        let progress = try JSONDecoder().decode(DailyProgress.self, from: Data(json.utf8))
        #expect(progress.current == .repetition)
        #expect(progress.completed == [.discovery])
        #expect(progress.audioSentence(for: .repetition) == 4)
        #expect(progress.fillIns.isEmpty)

        let roundTrip = try JSONDecoder().decode(DailyProgress.self, from: JSONEncoder().encode(progress))
        #expect(roundTrip == progress)
    }
}
