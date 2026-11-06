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

    func card(_ lesson: Int, _ number: Int, exercise: Bool = false, due: Date) -> Card {
        Card(item: AssimilItem(lesson: lesson, isExercise: exercise, number: number).itemID(),
             angle: Card.Angle.listen, language: "es", scheduler: Card.Scheduler.ladder, at: due)
    }

    @Test("File de révision : deux phrases 3 de leçons différentes restent distinctes")
    func reviewQueueSameNumber() throws {
        let a = card(4, 3, due: Fixture.date(day: 3))
        let b = card(9, 3, due: Fixture.date(day: 3).addingTimeInterval(1))
        let steps = SessionBuilder.build(.review, cards: [b, a], manifest: manifest)
        #expect(steps.count == 4)
        #expect(SessionNavigation.navigableIndex(after: 0, in: steps) == 2)
        #expect(steps[2].lessonNumber == 9)
    }

    @Test("File de révision : échéance d'abord, puis l'ordre des clés ; une carte d'ailleurs est passée")
    func reviewQueueOrder() throws {
        let day = Fixture.date(day: 3)
        let exercise = card(12, 2, exercise: true, due: day)
        let dialogue = card(12, 2, due: day)
        let earlier = card(40, 1, due: Fixture.date(day: 2))
        let foreign = Card(item: try #require(ItemID("conjugaison-es:ser:presente:1s")),
                           angle: Card.Angle.listen, language: "es", scheduler: Card.Scheduler.ladder, at: day)
        let steps = SessionBuilder.build(.review, cards: [exercise, foreign, dialogue, earlier], manifest: manifest)
        let sentences = steps.filter { !$0.isPause }
        #expect(sentences.map(\.markKey) == [earlier.key, dialogue.key, exercise.key])
        #expect(sentences.map(\.isExercise) == [false, false, true])
        #expect(steps.filter(\.isPause).count == 3)
    }

    @Test("L'étape désigne sa carte ; la prise de voix garde l'ancien nom")
    func stepKeys() throws {
        let steps = SessionBuilder.build(.lesson(number: 12, mode: .shadowing), manifest: manifest)
        let dialogue = try #require(steps.first { $0.kind == .dialogue && $0.sentenceNumber == 3 })
        #expect(dialogue.markKey == "assimil-es:L012:S03#listen")
        #expect(dialogue.recordingKey == "L012-S03")
        let exercise = try #require(steps.first { $0.kind == .exercise && $0.sentenceNumber == 2 })
        #expect(exercise.markKey == "assimil-es:L012:T02#listen")
        #expect(exercise.recordingKey == "L012-T02")
        // La pause qui suit une phrase désigne la même carte.
        let pause = try #require(steps.first { $0.isPause && $0.isExercise && $0.sentenceNumber == 2 })
        #expect(pause.markKey == exercise.markKey)
        let title = try #require(steps.first { $0.kind == .title })
        #expect(title.markKey == nil)
    }

    @Test("Le temps compte pour l'activité de l'écran")
    func studyActivity() {
        #expect(SessionRequest.daily(lessonNumber: 3, audio: .discovery).studyActivity == .assimilDaily)
        #expect(SessionRequest.review.studyActivity == .review)
        #expect(SessionRequest.review.studyActivity.courseID == nil)
        #expect(SessionRequest.lesson(number: 3, mode: .passive).studyActivity == .assimilListen)
        #expect(SessionRequest.lesson(number: 3, mode: .passive).studyActivity.courseID == "assimil-es")
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
