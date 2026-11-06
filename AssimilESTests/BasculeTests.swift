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

    // MARK: - Drapeau

    @Test("Drapeau sur une phrase sans carte : carte créée, due tout de suite")
    func flagCreates() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let now = Fixture.date(day: 10, hour: 18)

        #expect(CardReview.toggleFlag(on: item(12, 4), cards: [], at: now, in: context))

        let card = try #require(try allCards(context).first)
        #expect(card.key == "assimil-es:L012:S04#listen")
        #expect(card.itemID == "assimil-es:L012:S04")
        #expect(card.scheduler == Card.Scheduler.ladder)
        #expect(card.language == "es")
        #expect(card.isActive)
        #expect(card.createdAt == now && card.activatedAt == now && card.dueAt == now)
        #expect(card.reps == 0)
        #expect(card.isDue(at: now))
        // Le drapeau n'écrit plus l'ancien modèle.
        #expect(try context.fetch(FetchDescriptor<DifficultSentence>()).isEmpty)
    }

    @Test("Drapeau sur une carte active : désactivée, ni supprimée ni remise à zéro")
    func flagDeactivates() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        CardReview.toggleFlag(on: item(12, 4), cards: [], at: Fixture.date(day: 3), in: context)
        let card = try #require(try allCards(context).first)
        CardReview.review(card, at: Fixture.date(day: 3, hour: 20), in: context)

        #expect(!CardReview.toggleFlag(on: item(12, 4), cards: try allCards(context),
                                        at: Fixture.date(day: 5), in: context))

        #expect(try allCards(context).count == 1)
        #expect(!card.isActive)
        #expect(card.reps == 1)
        #expect(!card.isDue(at: Fixture.date(day: 30)))
        #expect(ReviewSchedule.due(in: [card], now: Fixture.date(day: 30)).isEmpty)
        #expect(try logs(context).count == 1)
    }

    @Test("Drapeau sur une carte inactive : réactivée, remise à zéro, journal gardé")
    func flagReactivates() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        CardReview.toggleFlag(on: item(12, 4), cards: [], at: Fixture.date(day: 3), in: context)
        let card = try #require(try allCards(context).first)
        CardReview.review(card, at: Fixture.date(day: 3, hour: 20), in: context)
        CardReview.review(card, at: Fixture.date(day: 4, hour: 20), in: context)
        CardReview.toggleFlag(on: item(12, 4), cards: [card], at: Fixture.date(day: 5), in: context)

        let now = Fixture.date(day: 9, hour: 7)
        #expect(CardReview.toggleFlag(on: item(12, 4), cards: [card], at: now, in: context))

        #expect(try allCards(context).count == 1)
        #expect(card.isActive)
        #expect(card.reps == 0)
        #expect(card.dueAt == now)
        #expect(card.activatedAt == now)
        #expect(card.createdAt == Fixture.date(day: 3))
        #expect(try logs(context).count == 2)
    }

    // MARK: - Révision

    @Test("Une revue : échéance sur l'échelle, compte, date, et une ligne de journal mains libres")
    func reviewWritesCardAndLog() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        CardReview.toggleFlag(on: item(12, 4), cards: [], at: Fixture.date(day: 3), in: context)
        let card = try #require(try allCards(context).first)

        let first = Fixture.date(day: 3, hour: 21)
        CardReview.review(card, at: first, in: context)
        #expect(card.reps == 1)
        #expect(card.dueAt == ReviewSchedule.next(after: 0, from: first))
        #expect(card.lastReviewedAt == first)

        let second = Fixture.date(day: 4, hour: 8)
        CardReview.review(card, at: second, in: context)
        #expect(card.reps == 2)
        #expect(card.dueAt == ReviewSchedule.next(after: 1, from: second))

        let journal = try logs(context).sorted { $0.reviewedAt < $1.reviewedAt }
        #expect(journal.map(\.reviewedAt) == [first, second])
        #expect(journal.allSatisfy { $0.cardKey == card.key })
        #expect(journal.allSatisfy { $0.rating == nil && $0.context == ReviewLog.Context.handsFree })
        #expect(journal.allSatisfy { $0.spokenMatch == nil && $0.durationMs == nil })
    }

    @Test("Une séance : chaque phrase revue une fois, même rejouée ; une nouvelle séance la revoit")
    func reviewOncePerSession() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        CardReview.toggleFlag(on: item(12, 2), cards: [], at: Fixture.date(day: 3), in: context)
        CardReview.toggleFlag(on: item(30, 1, exercise: true), cards: [], at: Fixture.date(day: 3), in: context)
        let cards = try allCards(context)
        let now = Fixture.date(day: 5)

        let steps = SessionBuilder.build(.review, cards: ReviewSchedule.due(in: cards, now: now), manifest: manifest)
        let sentences = steps.filter(\.isNavigable)
        #expect(sentences.count == 2)

        var session = SessionReviews()
        let recorded = [
            session.record(sentences[0], cards: cards, at: now, in: context),
            // Rejouée, puis retrouvée après un retour en arrière : rien de plus.
            session.record(sentences[0], cards: cards, at: now, in: context),
            session.record(sentences[1], cards: cards, at: now, in: context),
            session.record(sentences[0], cards: cards, at: now.addingTimeInterval(60), in: context),
        ]
        #expect(recorded == [true, false, true, false])

        #expect(try logs(context).count == 2)
        #expect(cards.allSatisfy { $0.reps == 1 })

        // Le lendemain, la séance est reconstruite : ses étapes sont neuves.
        let tomorrow = Fixture.date(day: 6, hour: 9)
        let next = SessionBuilder.build(.review, cards: ReviewSchedule.due(in: cards, now: tomorrow), manifest: manifest)
        var nextSession = SessionReviews()
        let first = try #require(next.first)
        let again = nextSession.record(first, cards: cards, at: tomorrow, in: context)
        #expect(again)
        #expect(try logs(context).count == 3)
    }

    @Test("Une carte désactivée pendant la séance n'est plus revue")
    func noReviewOfInactiveCard() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        CardReview.toggleFlag(on: item(12, 2), cards: [], at: Fixture.date(day: 3), in: context)
        let cards = try allCards(context)
        let steps = SessionBuilder.build(.review, cards: cards, manifest: manifest)
        CardReview.toggleFlag(on: item(12, 2), cards: cards, at: Fixture.date(day: 4), in: context)

        var session = SessionReviews()
        let first = try #require(steps.first)
        let recorded = session.record(first, cards: cards, at: Fixture.date(day: 4), in: context)
        #expect(!recorded)
        #expect(try logs(context).isEmpty)
    }

    @Test("Seules les cartes actives et échues sont dues")
    func dueCards() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let now = Fixture.date(day: 10)
        CardReview.toggleFlag(on: item(1, 1), cards: [], at: Fixture.date(day: 9), in: context)
        CardReview.toggleFlag(on: item(1, 2), cards: [], at: Fixture.date(day: 11), in: context)
        CardReview.toggleFlag(on: item(1, 3), cards: [], at: Fixture.date(day: 8), in: context)
        let off = try #require(try allCards(context).first { $0.itemID == "assimil-es:L001:S03" })
        off.isActive = false

        let due = ReviewSchedule.due(in: try allCards(context), now: now)
        #expect(due.map(\.itemID) == ["assimil-es:L001:S01"])
    }

    // MARK: - Temps d'étude

    @Test("Le temps écouté devient un événement par enregistrement, plus un jour d'étude")
    func studyTimeWritesEvents() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let now = Fixture.date(day: 10, hour: 18, minute: 30)

        StudyTime.record(90, as: .review, in: context, now: now, calendar: Fixture.calendar)
        StudyTime.record(600, as: .assimilDaily, in: context, now: now, calendar: Fixture.calendar)
        StudyTime.record(0, as: .assimilListen, in: context, now: now, calendar: Fixture.calendar)

        let events = try context.fetch(FetchDescriptor<StudyEvent>())
        #expect(events.count == 2)
        let review = try #require(events.first { $0.activity == "review" })
        #expect(review.seconds == 90)
        #expect(review.courseID == nil)
        #expect(review.language == "es")
        #expect(review.startedAt == now.addingTimeInterval(-90))
        #expect(review.day == Fixture.calendar.startOfDay(for: now))
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
        StudyTime.record(30, as: .review, in: context, now: Fixture.date(day: 6, hour: 10), calendar: Fixture.calendar)
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

        // Après la bascule : une phrase marquée et une revue dans les cartes seulement.
        let card = try #require(try allCards(context).first)
        CardReview.review(card, at: Fixture.date(day: 6), in: context)
        CardReview.toggleFlag(on: item(40, 2), cards: try allCards(context), at: Fixture.date(day: 6), in: context)
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
