import Foundation
import Testing
import UIKit
@testable import AssimilES

@Suite("Séquences audio et navigation")
@MainActor
struct SessionTests {
    let manifest = Fixture.manifest()

    @Test("Découverte : le dialogue d'un trait, sans pause ni exercice")
    func discovery() {
        let steps = SessionBuilder.build(.daily(lessonNumber: 12, audio: .discovery), manifest: manifest)
        #expect(steps.map(\.kind) == [.title, .dialogue, .dialogue, .dialogue])
        #expect(!steps.contains { $0.isExercise || $0.isPause })
    }

    @Test("Répétition : chaque phrase trois fois, chaque fois suivie de sa pause")
    func repetition() {
        let steps = SessionBuilder.build(.daily(lessonNumber: 12, audio: .repetition(times: 3)), manifest: manifest)
        let sentenceSteps = steps.filter { $0.sentenceNumber == 1 }
        #expect(sentenceSteps.map(\.kind) == [.dialogue, .pause, .dialogue, .pause, .dialogue, .pause])
        #expect(sentenceSteps.map(\.repetition) == [1, 1, 2, 2, 3, 3])
        #expect(steps.filter(\.isNavigable).count == 4) // le titre et une ligne par phrase
        #expect(!steps.contains { $0.isExercise })
        // Le silence diffusé est conservé : les pauses sont des étapes sans fichier.
        #expect(steps.filter(\.isPause).allSatisfy { $0.url == nil && $0.duration >= 1 })
    }

    @Test("L'écoute libre reste comme avant : une pause par phrase, exercice inclus")
    func freeShadowingUnchanged() {
        let steps = SessionBuilder.build(.lesson(number: 12, mode: .shadowing), manifest: manifest)
        #expect(steps.filter { $0.kind == .dialogue }.count == 3)
        #expect(steps.filter { $0.kind == .exercise }.count == 2)
        #expect(steps.allSatisfy { $0.repetition == 1 })
    }

    @Test("Phrase suivante saute les répétitions ; refaire repart de la première")
    func navigation() throws {
        let steps = SessionBuilder.build(.daily(lessonNumber: 12, audio: .repetition(times: 3)), manifest: manifest)
        let secondPass = try #require(steps.firstIndex { $0.sentenceNumber == 1 && $0.repetition == 2 && $0.isPause })
        let firstOfSentence1 = try #require(SessionBuilder.index(ofSentence: 1, in: steps))
        let firstOfSentence2 = try #require(SessionBuilder.index(ofSentence: 2, in: steps))

        #expect(SessionNavigation.startOfSentence(at: secondPass, in: steps) == firstOfSentence1)
        #expect(SessionNavigation.navigableIndex(after: secondPass, in: steps) == firstOfSentence2)
        #expect(SessionNavigation.navigableIndex(before: firstOfSentence2, in: steps) == firstOfSentence1)
        #expect(steps[firstOfSentence2].repetition == 1)
    }

    @Test("File de révision : deux phrases 3 de leçons différentes restent distinctes")
    func reviewQueueSameNumber() throws {
        let a = DifficultSentence(lessonNumber: 4, sentenceNumber: 3, isExercise: false)
        let b = DifficultSentence(lessonNumber: 9, sentenceNumber: 3, isExercise: false)
        b.dueAt = a.dueAt.addingTimeInterval(1)
        let steps = SessionBuilder.build(.review, marks: [a, b], manifest: manifest)
        #expect(steps.count == 4)
        #expect(SessionNavigation.navigableIndex(after: 0, in: steps) == 2)
        #expect(steps[2].lessonNumber == 9)
    }

    @Test("Le temps écouté n'est rendu qu'une fois")
    func ledger() {
        var ledger = PlayTimeLedger()
        ledger.add(3)
        #expect(ledger.takeUnrecorded() == 3)
        #expect(ledger.takeUnrecorded() == 0)
        ledger.add(2)
        ledger.add(-5)
        #expect(ledger.takeUnrecorded() == 2)
        #expect(ledger.total == 5)
    }
}

@Suite("Changement de jour, app ouverte")
@MainActor
struct DayClockTests {
    final class Now: @unchecked Sendable { var date = Fixture.date(day: 10, hour: 23, minute: 59) }

    @Test("Minuit publie le nouveau jour sans relancer l'app")
    func midnight() async throws {
        let now = Now()
        let center = NotificationCenter()
        let clock = DayClock(now: { now.date }, calendar: Fixture.calendar, center: center)
        #expect(clock.today == Fixture.calendar.startOfDay(for: Fixture.date(day: 10)))

        now.date = Fixture.date(day: 11, hour: 0, minute: 1)
        center.post(name: .NSCalendarDayChanged, object: nil)
        let expected = Fixture.calendar.startOfDay(for: Fixture.date(day: 11))
        for _ in 0..<100 where clock.today != expected {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(clock.today == expected)
    }

    @Test("Retour au premier plan : le jour est relu")
    func foreground() async throws {
        let now = Now()
        let center = NotificationCenter()
        let clock = DayClock(now: { now.date }, calendar: Fixture.calendar, center: center)
        now.date = Fixture.date(day: 13, hour: 7)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        let expected = Fixture.calendar.startOfDay(for: now.date)
        for _ in 0..<100 where clock.today != expected {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(clock.today == expected)
    }
}
