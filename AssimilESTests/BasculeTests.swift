import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Bascule : révision, drapeau et temps d'étude sur les nouvelles tables")
@MainActor
struct BasculeTests {
    let manifest = Fixture.manifest()

    func item(_ lesson: Int, _ number: Int, exercise: Bool = false) -> AssimilItem {
        AssimilItem(lesson: lesson, isExercise: exercise, number: number)
    }

    func allCards(_ context: ModelContext) throws -> [Card] {
        try context.fetch(FetchDescriptor<Card>())
    }

    func logs(_ context: ModelContext) throws -> [ReviewLog] {
        try context.fetch(FetchDescriptor<ReviewLog>())
    }

    // MARK: - Cartes de phrases

    @Test("Les cartes de phrases marquées sont désactivées une fois, journal gardé")
    func listenCardsRetired() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let phrase = Card(item: item(12, 4).itemID(), angle: Card.Angle.listen, language: "es",
                          scheduler: Card.Scheduler.ladder, at: Fixture.date(day: 3))
        let word = Card(item: try #require(VocabItem(lemma: "estar")).itemID(), angle: Card.Angle.recognize,
                        language: "es", scheduler: Card.Scheduler.fsrs, at: Fixture.date(day: 3))
        context.insert(phrase)
        context.insert(word)
        context.insert(ReviewLog(cardKey: phrase.key, reviewedAt: Fixture.date(day: 4), context: ReviewLog.Context.handsFree))
        try context.save()

        #expect(CardReview.retireListenCards(in: context) == 1)
        #expect(!phrase.isActive)
        #expect(word.isActive)
        #expect(try context.fetchCount(FetchDescriptor<Card>()) == 2)
        #expect(try logs(context).count == 1)
        // Relancée : plus rien à faire.
        #expect(CardReview.retireListenCards(in: context) == 0)
    }

    // MARK: - Temps d'étude

    @Test("Le temps écouté devient un événement par enregistrement, plus un jour d'étude")
    func studyTimeWritesEvents() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let now = Fixture.date(day: 10, hour: 18, minute: 30)

        StudyTime.record(90, as: .vocab, in: context, now: now, calendar: Fixture.calendar)
        StudyTime.record(600, as: .assimilDaily, in: context, now: now, calendar: Fixture.calendar)
        StudyTime.record(0, as: .assimilListen, in: context, now: now, calendar: Fixture.calendar)

        let events = try context.fetch(FetchDescriptor<StudyEvent>())
        #expect(events.count == 2)
        let vocab = try #require(events.first { $0.activity == "vocab" })
        #expect(vocab.seconds == 90)
        #expect(vocab.courseID == "assimil-es")
        #expect(vocab.language == "es")
        #expect(vocab.startedAt == now.addingTimeInterval(-90))
        #expect(vocab.day == Fixture.calendar.startOfDay(for: now))
        let daily = try #require(events.first { $0.activity == "assimil.daily" })
        #expect(daily.courseID == "assimil-es")
        #expect(try context.fetch(FetchDescriptor<StudyDay>()).isEmpty)
    }

    @Test("Temps total : les jours recopiés plus le temps d'après, sans double compte")
    func totalWithoutDoubleCount() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let day5 = Fixture.calendar.startOfDay(for: Fixture.date(day: 5))
        context.insert(StudyDay(day: day5, seconds: 600))
        try context.save()

        LegacyCopy.finishIfNeeded(in: context, now: Fixture.date(day: 6))
        StudyTime.record(120, as: .assimilDaily, in: context, now: Fixture.date(day: 6), calendar: Fixture.calendar)
        StudyTime.record(30, as: .vocab, in: context, now: Fixture.date(day: 6, hour: 10), calendar: Fixture.calendar)
        try context.save()
        // Relancée, la bascule ne recopie rien une seconde fois.
        #expect(LegacyCopy.finishIfNeeded(in: context, now: Fixture.date(day: 7)) == .alreadyDone)

        let events = try context.fetch(FetchDescriptor<StudyEvent>())
        #expect(StudyTime.total(events) == 750)
        #expect(try context.fetch(FetchDescriptor<StudyDay>()).first?.seconds == 600)
    }

    @Test("Le temps par jour regroupe les événements de chaque jour")
    func secondsByDay() {
        let calendar = Fixture.calendar
        func event(_ day: Int, hour: Int, _ seconds: Double, _ activity: String) -> StudyEvent {
            let date = Fixture.date(day: day, hour: hour)
            return StudyEvent(day: calendar.startOfDay(for: date), startedAt: date, seconds: seconds,
                              language: "es", activity: activity, courseID: nil)
        }
        let events = [
            event(5, hour: 0, 600, StudyEvent.Activity.assimilLegacy),
            event(5, hour: 21, 60, StudyEvent.Activity.review),
            event(6, hour: 8, 300, StudyEvent.Activity.assimilDaily),
        ]
        let byDay = StudyTime.secondsByDay(events, calendar: calendar)
        #expect(byDay.count == 2)
        #expect(byDay[calendar.startOfDay(for: Fixture.date(day: 5))] == 660)
        #expect(byDay[calendar.startOfDay(for: Fixture.date(day: 6))] == 300)
        #expect(StudyTime.secondsByDay([], calendar: calendar).isEmpty)
    }

    // MARK: - La bascule elle-même

    @Test("Bascule : une dernière copie, inscrite ; lancée deux fois, la seconde ne relit rien")
    func switchOverTwice() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let mark = DifficultSentence(lessonNumber: 12, sentenceNumber: 4, isExercise: false)
        mark.markedAt = Fixture.date(day: 3)
        mark.recordReview(at: Fixture.date(day: 4))
        context.insert(mark)
        context.insert(StudyDay(day: Fixture.calendar.startOfDay(for: Fixture.date(day: 4)), seconds: 300))
        try context.save()

        guard case .finished(let report) = LegacyCopy.finishIfNeeded(in: context, now: Fixture.date(day: 5)) else {
            Issue.record("la première bascule doit copier"); return
        }
        #expect(report.cardsCreated == 1 && report.eventsCreated == 1)
        let migration = try #require(try context.fetch(FetchDescriptor<DataMigration>()).first)
        #expect(migration.key == LegacyCopy.completionKey)
        #expect(migration.completedAt == Fixture.date(day: 5))

        // Après la bascule : une revue et une phrase marquée, dans les cartes seulement
        // (écrites à la main : le drapeau et sa révision sont retirés depuis).
        let card = try #require(try allCards(context).first)
        card.reps += 1
        context.insert(Card(item: item(40, 2).itemID(), angle: Card.Angle.listen, language: "es",
                            scheduler: Card.Scheduler.ladder, at: Fixture.date(day: 6)))
        // Et l'ancien modèle bouge encore (une sauvegarde mal restaurée, par exemple).
        mark.reviewCount = 0
        context.insert(DifficultSentence(lessonNumber: 50, sentenceNumber: 1, isExercise: false))
        try context.save()

        #expect(LegacyCopy.finishIfNeeded(in: context, now: Fixture.date(day: 7)) == .alreadyDone)

        let cards = Dictionary(uniqueKeysWithValues: try allCards(context).map { ($0.key, $0) })
        #expect(cards.count == 2)
        #expect(cards["assimil-es:L012:S04#listen"]?.reps == 2)
        #expect(cards["assimil-es:L040:S02#listen"]?.isActive == true)
        #expect(cards["assimil-es:L050:S01#listen"] == nil)
        #expect(try context.fetch(FetchDescriptor<DataMigration>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<StudyEvent>()).count == 1)
    }

    @Test("Bascule sur un stockage déjà synchronisé à l'étape 3 : rien ne bouge, l'inscription s'ajoute")
    func switchOverAfterStepThree() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let mark = DifficultSentence(lessonNumber: 12, sentenceNumber: 4, isExercise: false)
        context.insert(mark)
        try context.save()
        LegacyCopy.run(in: context)

        #expect(LegacyCopy.finishIfNeeded(in: context) == .finished(LegacyCopy.Report()))
        #expect(try context.fetch(FetchDescriptor<DataMigration>()).count == 1)
        #expect(try allCards(context).count == 1)
    }
}
