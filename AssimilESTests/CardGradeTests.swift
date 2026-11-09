import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Cartes notées (FSRS)")
@MainActor
struct CardGradeTests {

    private func vocabCard(_ lemma: String, _ angle: String = Card.Angle.recognize,
                           in context: ModelContext) throws -> Card {
        let item = try #require(VocabItem(lemma: lemma))
        let card = Card(item: item.itemID(), angle: angle, language: "es",
                        scheduler: Card.Scheduler.fsrs, at: Fixture.date(day: 1))
        context.insert(card)
        return card
    }

    @Test("Une carte neuve est en apprentissage, à l'étape 0, due tout de suite")
    func newCard() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let card = try vocabCard("estar", in: context)
        #expect(card.fsrsMemory == FSRS.Memory.new(at: Fixture.date(day: 1)))
        #expect(!card.isInReview && !card.isKnown())
        #expect(card.vocabItem?.lemma == "estar")
        #expect(card.assimilItem == nil)
    }

    @Test("Noter une carte suit FSRS, compte la revue et l'inscrit au journal avec sa note")
    func gradeWritesCardAndLog() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let card = try vocabCard("estar", in: context)
        let first = Fixture.date(day: 1, hour: 9)
        let second = first.addingTimeInterval(60)

        CardReview.grade(card, .good, at: first, durationMs: 4200, in: context)
        CardReview.grade(card, .good, at: second, in: context)

        // Le même chemin que le scénario « toutBien » de FSRSTests.
        let expected = FSRS.review(FSRS.review(.new(at: Fixture.date(day: 1)), rating: .good, at: first),
                                   rating: .good, at: second)
        #expect(card.fsrsMemory == expected)
        #expect(card.fsrsState == "review" && card.fsrsStep == nil)
        #expect(card.reps == 2)
        // En révision, mais découverte le jour même : pas encore connue.
        #expect(card.isInReview)
        #expect(!card.isKnown(calendar: Fixture.calendar))

        let logs = try context.fetch(FetchDescriptor<ReviewLog>(sortBy: [SortDescriptor(\.reviewedAt)]))
        #expect(logs.map(\.rating) == [3, 3])
        #expect(logs.map(\.context) == [ReviewLog.Context.graded, ReviewLog.Context.graded])
        #expect(logs.map(\.cardKey) == ["assimil-es:V:estar#recognize", "assimil-es:V:estar#recognize"])
        #expect(logs.first?.durationMs == 4200)
    }

    @Test("L'aperçu donne une échéance par note, sans rien écrire")
    func previewWritesNothing() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let card = try vocabCard("casa", in: context)
        let now = Fixture.date(day: 1, hour: 9)
        let before = card.fsrsMemory

        let preview = CardReview.preview(card, at: now)
        #expect(preview[.again] == now.addingTimeInterval(60))
        #expect(preview[.hard] == now.addingTimeInterval(330))
        #expect(preview[.good] == now.addingTimeInterval(600))
        // Facile d'emblée : en révision, huit jours (stabilité initiale 8,3).
        #expect(preview[.easy] == now.addingTimeInterval(8 * 86_400))
        #expect(card.fsrsMemory == before)
        #expect(card.reps == 0)
        #expect(try context.fetchCount(FetchDescriptor<ReviewLog>()) == 0)
    }

    @Test("Une carte à l'état illisible repart en apprentissage, sans planter")
    func unreadableState() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let card = try vocabCard("bien", in: context)
        card.fsrsState = "n'importe quoi"
        #expect(card.fsrsMemory.state == .learning)
        #expect(card.fsrsMemory.step == 0)
    }
}
