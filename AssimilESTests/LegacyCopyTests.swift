import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Copie de l'ancien modèle vers les cartes")
@MainActor
struct LegacyCopyTests {

    /// Une phrase marquée telle que l'ancien modèle l'écrit, à une date fixe.
    @discardableResult
    func mark(_ lesson: Int, _ sentence: Int, exercise: Bool = false, day: Int = 3,
              in context: ModelContext) -> DifficultSentence {
        let mark = DifficultSentence(lessonNumber: lesson, sentenceNumber: sentence, isExercise: exercise)
        mark.markedAt = Fixture.date(day: day)
        mark.dueAt = Fixture.date(day: day)
        context.insert(mark)
        return mark
    }

    func cards(_ context: ModelContext) throws -> [String: Card] {
        Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Card>()).map { ($0.key, $0) })
    }

    func legacyEvents(_ context: ModelContext) throws -> [StudyEvent] {
        try context.fetch(FetchDescriptor<StudyEvent>())
            .filter { $0.activity == StudyEvent.Activity.assimilLegacy }
    }

    @Test("Une passe : une carte par phrase marquée, un événement par jour d'étude")
    func onePass() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        mark(12, 4, in: context)
        let exercise = mark(12, 3, exercise: true, day: 4, in: context)
        exercise.recordReview(at: Fixture.date(day: 5, hour: 20))
        let day = Fixture.calendar.startOfDay(for: Fixture.date(day: 5))
        context.insert(StudyDay(day: day, seconds: 600))
        try context.save()

        let report = try #require(LegacyCopy.run(in: context))
        #expect(report.cardsCreated == 2)
        #expect(report.eventsCreated == 1)

        let all = try cards(context)
        #expect(all.count == 2)
        let dialogue = try #require(all["assimil-es:L012:S04#listen"])
        #expect(dialogue.itemID == "assimil-es:L012:S04")
        #expect(dialogue.angle == "listen")
        #expect(dialogue.language == "es")
        #expect(dialogue.scheduler == "ladder")
        #expect(dialogue.isActive)
        #expect(dialogue.createdAt == Fixture.date(day: 3))
        #expect(dialogue.activatedAt == Fixture.date(day: 3))
        #expect(dialogue.dueAt == Fixture.date(day: 3))
        #expect(dialogue.reps == 0)
        #expect(dialogue.lastReviewedAt == nil)
        #expect(dialogue.stability == nil && dialogue.difficulty == nil)

        let reviewed = try #require(all["assimil-es:L012:T03#listen"])
        #expect(reviewed.reps == 1)
        #expect(reviewed.dueAt == exercise.dueAt)
        #expect(reviewed.lastReviewedAt == Fixture.date(day: 5, hour: 20))

        let events = try legacyEvents(context)
        #expect(events.count == 1)
        #expect(events.first?.day == day)
        #expect(events.first?.startedAt == day)
        #expect(events.first?.seconds == 600)
        #expect(events.first?.language == "es")
        #expect(events.first?.courseID == "assimil-es")

        // Aucun journal : l'ancien modèle n'a pas d'historique. Les anciennes tables restent.
        #expect(try context.fetch(FetchDescriptor<ReviewLog>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DifficultSentence>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<StudyDay>()).count == 1)
    }

    @Test("Deux passes : aucun doublon, la seconde ne change rien")
    func twoPasses() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        mark(12, 4, in: context)
        mark(20, 1, in: context)
        context.insert(StudyDay(day: Fixture.calendar.startOfDay(for: Fixture.date(day: 5)), seconds: 300))
        try context.save()

        LegacyCopy.run(in: context)
        let second = try #require(LegacyCopy.run(in: context))
        #expect(second == LegacyCopy.Report())
        #expect(try cards(context).count == 2)
        #expect(try legacyEvents(context).count == 1)
    }

    @Test("Phrase démarquée puis remarquée : carte désactivée, puis réactivée et remise à zéro")
    func unmarkedThenMarkedAgain() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let first = mark(12, 4, in: context)
        first.recordReview(at: Fixture.date(day: 4))
        first.recordReview(at: Fixture.date(day: 5))
        try context.save()
        LegacyCopy.run(in: context)
        let key = "assimil-es:L012:S04#listen"
        #expect(try cards(context)[key]?.reps == 2)

        // Le drapeau retiré : l'ancien modèle supprime la ligne.
        context.delete(first)
        try context.save()
        let unmarked = try #require(LegacyCopy.run(in: context))
        #expect(unmarked.cardsDeactivated == 1)
        let inactive = try #require(try cards(context)[key])
        #expect(!inactive.isActive)
        // Désactivée, pas effacée : l'historique et la date de création restent.
        #expect(inactive.reps == 2)
        #expect(inactive.createdAt == Fixture.date(day: 3))

        // Remarquée : l'ancien modèle recrée une ligne neuve, due tout de suite.
        mark(12, 4, day: 10, in: context)
        try context.save()
        let marked = try #require(LegacyCopy.run(in: context))
        #expect(marked.cardsCreated == 0)
        #expect(marked.cardsUpdated == 1)
        let card = try #require(try cards(context)[key])
        #expect(card.isActive)
        #expect(card.reps == 0)
        #expect(card.dueAt == Fixture.date(day: 10))
        #expect(card.lastReviewedAt == nil)
        #expect(card.activatedAt == Fixture.date(day: 10))
        #expect(card.createdAt == Fixture.date(day: 3))
        #expect(try cards(context).count == 1)
    }

    @Test("Phrase revue entre deux passes : échéance et nombre de revues suivent")
    func reviewedBetweenPasses() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let sentence = mark(12, 4, in: context)
        try context.save()
        LegacyCopy.run(in: context)

        sentence.recordReview(at: Fixture.date(day: 4, hour: 21))
        try context.save()
        let report = try #require(LegacyCopy.run(in: context))
        #expect(report.cardsUpdated == 1)

        let card = try #require(try cards(context)["assimil-es:L012:S04#listen"])
        #expect(card.reps == 1)
        #expect(card.dueAt == sentence.dueAt)
        #expect(card.lastReviewedAt == Fixture.date(day: 4, hour: 21))
        #expect(card.activatedAt == Fixture.date(day: 3))
    }

    @Test("Un jour d'étude qui grossit : l'événement suit, sans doublon")
    func studyDayGrows() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let day = Fixture.calendar.startOfDay(for: Fixture.date(day: 5))
        let studyDay = StudyDay(day: day, seconds: 120)
        context.insert(studyDay)
        try context.save()
        LegacyCopy.run(in: context)

        studyDay.seconds += 480
        context.insert(StudyDay(day: Fixture.calendar.startOfDay(for: Fixture.date(day: 6)), seconds: 60))
        try context.save()
        let report = try #require(LegacyCopy.run(in: context))
        #expect(report.eventsUpdated == 1)
        #expect(report.eventsCreated == 1)

        let events = try legacyEvents(context).sorted { $0.day < $1.day }
        #expect(events.map(\.seconds) == [600, 60])
    }

    @Test("Une clé illisible est ignorée, les autres sont copiées")
    func unreadableKey() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        mark(12, 4, in: context)
        let broken = mark(13, 1, in: context)
        broken.key = "L13-X1"
        try context.save()

        let report = try #require(LegacyCopy.run(in: context))
        #expect(report.skippedKeys == ["L13-X1"])
        #expect(report.cardsCreated == 1)
        #expect(try cards(context).keys.sorted() == ["assimil-es:L012:S04#listen"])
        // La ligne illisible reste où elle est.
        #expect(try context.fetch(FetchDescriptor<DifficultSentence>()).count == 2)
    }
}
