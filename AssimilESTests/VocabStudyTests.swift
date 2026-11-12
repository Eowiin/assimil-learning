import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Révision du vocabulaire")
@MainActor
struct VocabStudyTests {

    let manifest = Fixture.manifest()

    /// Trois mots par leçon, de la leçon 1 à `lessons`, dans l'ordre du livre.
    func vocabulary(lessons: Int = 3, renamed: [String: String] = [:]) throws -> Vocabulary {
        let words = (1...lessons).flatMap { lesson in
            (1...3).map { i in
                #"{"lemma": "mot\#(lesson)x\#(i)", "forms": ["mot\#(lesson)x\#(i)"], "translation": "sens \#(lesson).\#(i)", "firstLesson": \#(lesson), "count": \#(10 - i), "occurrences": [{"lesson": \#(lesson), "isExercise": false, "n": \#(i)}]}"#
            }
        }
        let renamedJSON = try String(data: JSONEncoder().encode(renamed), encoding: .utf8)!
        let json = #"{"version": 1, "words": [\#(words.joined(separator: ","))], "renamed": \#(renamedJSON)}"#
        return try JSONDecoder().decode(Vocabulary.self, from: Data(json.utf8))
    }

    /// Un vocabulaire réduit à ces mots, sans autre détail.
    func vocabulary(_ lemmas: [String]) throws -> Vocabulary {
        let words = lemmas.map {
            #"{"lemma": "\#($0)", "forms": [], "translation": null, "firstLesson": 1, "count": 1, "occurrences": []}"#
        }
        return try JSONDecoder().decode(Vocabulary.self, from: Data(#"{"version": 1, "words": [\#(words.joined(separator: ","))]}"#.utf8))
    }

    func card(_ lemma: String, _ angle: String = Card.Angle.recognize, created: Date,
              in context: ModelContext) throws -> Card {
        let new = VocabStudy.NewCard(item: try #require(VocabItem(lemma: lemma)), angle: angle)
        return VocabStudy.introduce(new, at: created, in: context)
    }

    func validated(_ unit: Int, on date: Date) -> DailySession {
        let session = DailySession(unit: unit, attempt: 1, startedAt: date, stages: DailyStage.allCases)
        session.completedAt = date
        return session
    }

    // MARK: - Leçons

    @Test("Les mots d'une leçon arrivent le lendemain de sa validation ; avant le point de départ, tout est acquis")
    func availableLessons() {
        let today = Fixture.date(day: 10, hour: 8)
        let sessions = [validated(4, on: Fixture.date(day: 9, hour: 21)),
                        validated(5, on: Fixture.date(day: 10, hour: 7))]
        #expect(VocabStudy.availableLessons(sessions: sessions, anchorUnit: 1, manifest: manifest,
                                            now: today, calendar: Fixture.calendar) == [4])
        #expect(VocabStudy.availableLessons(sessions: sessions, anchorUnit: 4, manifest: manifest,
                                            now: today, calendar: Fixture.calendar) == [1, 2, 3, 4])
        // Le lendemain, la leçon 5 s'ajoute.
        #expect(VocabStudy.availableLessons(sessions: sessions, anchorUnit: 1, manifest: manifest,
                                            now: Fixture.date(day: 11), calendar: Fixture.calendar) == [4, 5])
    }

    // MARK: - Dû et nouveau

    @Test("Due : en révision, dès le matin ; en apprentissage, à la minute ; une carte orpheline, jamais")
    func due() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let morning = Fixture.date(day: 10, hour: 8)

        let tonight = try card("a", created: Fixture.date(day: 1), in: context)
        CardReview.grade(tonight, .easy, at: Fixture.date(day: 1), in: context)
        tonight.dueAt = Fixture.date(day: 10, hour: 21)
        let tomorrow = try card("b", created: Fixture.date(day: 1), in: context)
        CardReview.grade(tomorrow, .easy, at: Fixture.date(day: 1), in: context)
        tomorrow.dueAt = Fixture.date(day: 11, hour: 6)
        let learningLater = try card("c", created: morning, in: context)
        CardReview.grade(learningLater, .good, at: morning.addingTimeInterval(-60), in: context) // due dans 9 min
        let retired = try card("d", created: Fixture.date(day: 1), in: context)
        retired.isActive = false
        let phrase = Card(item: AssimilItem(lesson: 1, isExercise: false, number: 1).itemID(),
                          angle: Card.Angle.listen, language: "es", scheduler: Card.Scheduler.ladder,
                          at: Fixture.date(day: 1))
        context.insert(phrase)
        // « tal » a été absorbé par « qué tal » : sa carte, due, n'a plus de mot.
        let orphan = try card("tal", created: Fixture.date(day: 1), in: context)
        let orphanSoon = try card("tel", created: morning, in: context)
        CardReview.grade(orphanSoon, .good, at: morning.addingTimeInterval(-60), in: context)

        let cards = try context.fetch(FetchDescriptor<Card>())
        let vocabulary = try vocabulary(["a", "b", "c", "d"])
        #expect(VocabStudy.due(cards, in: vocabulary, now: morning, calendar: Fixture.calendar).map(\.key)
                == [tonight.key])
        #expect(VocabStudy.dueSoon(cards, in: vocabulary, now: morning).map(\.key) == [learningLater.key])
        #expect(orphan.isActive, "écartée, pas désactivée : son mot peut revenir")
    }

    @Test("Au plus 20 nouvelles cartes par jour : celles créées aujourd'hui comptent")
    func newPerDay() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let now = Fixture.date(day: 10, hour: 18)
        for i in 0..<15 { _ = try card("hier\(i)", created: Fixture.date(day: 9, hour: 20), in: context) }
        for i in 0..<12 { _ = try card("aujourdhui\(i)", created: Fixture.date(day: 10, hour: 7), in: context) }
        let cards = try context.fetch(FetchDescriptor<Card>())
        #expect(VocabStudy.newRemaining(cards, now: now, calendar: Fixture.calendar) == 8)
        for i in 0..<10 { _ = try card("encore\(i)", created: now, in: context) }
        #expect(VocabStudy.newRemaining(try context.fetch(FetchDescriptor<Card>()), now: now,
                                        calendar: Fixture.calendar) == 0)
    }

    @Test("Nouvelles cartes : ordre du livre, leçons disponibles seulement, plafond respecté")
    func newCardsOrder() throws {
        let vocabulary = try vocabulary(lessons: 3)
        let new = VocabStudy.newCards(vocabulary: vocabulary, lessons: [1, 3], cards: [], limit: 4)
        #expect(new.map(\.item.lemma) == ["mot1x1", "mot1x2", "mot1x3", "mot3x1"])
        #expect(new.allSatisfy { $0.angle == Card.Angle.recognize })
        #expect(VocabStudy.newCards(vocabulary: vocabulary, lessons: [1], cards: [], limit: 0).isEmpty)
    }

    @Test("La carte « retrouver » n'arrive qu'une fois « reconnaître » connue ; un mot retiré ne revient pas")
    func recallUnlockAndRetire() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let vocabulary = try vocabulary(lessons: 1)
        let day1 = Fixture.date(day: 1, hour: 9)

        let first = try card("mot1x1", created: day1, in: context)
        CardReview.grade(first, .good, at: day1, in: context) // en apprentissage, étape 1
        var new = VocabStudy.newCards(vocabulary: vocabulary, lessons: [1],
                                      cards: try context.fetch(FetchDescriptor<Card>()), limit: 10)
        #expect(new.map(\.key) == ["assimil-es:V:mot1x2#recognize", "assimil-es:V:mot1x3#recognize"])

        CardReview.grade(first, .good, at: day1.addingTimeInterval(600), in: context) // passe en révision
        #expect(first.isInReview)
        // Le jour même, pas encore connue : pas de carte « retrouver ».
        #expect(!VocabStudy.newCards(vocabulary: vocabulary, lessons: [1], cards: try context.fetch(FetchDescriptor<Card>()),
                                     limit: 10, calendar: Fixture.calendar).contains { $0.angle == Card.Angle.recall })
        // Réussie deux jours plus tard : connue.
        CardReview.grade(first, .good, at: Fixture.date(day: 3, hour: 9), in: context)
        #expect(first.isKnown(calendar: Fixture.calendar))
        let second = try #require(VocabItem(lemma: "mot1x2"))
        VocabStudy.retire(second, cards: try context.fetch(FetchDescriptor<Card>()), at: day1, in: context)

        new = VocabStudy.newCards(vocabulary: vocabulary, lessons: [1],
                                  cards: try context.fetch(FetchDescriptor<Card>()), limit: 10,
                                  calendar: Fixture.calendar)
        #expect(new.map(\.key) == ["assimil-es:V:mot1x1#recall", "assimil-es:V:mot1x3#recognize"])
        // Retirer crée les deux cartes, inactives : rien n'est supprimé, rien ne revient.
        let retired = try context.fetch(FetchDescriptor<Card>()).filter { $0.vocabItem == second }
        #expect(retired.count == 2 && retired.allSatisfy { !$0.isActive })
    }

    // MARK: - Renommages

    @Test("Une forme de base corrigée déplace la carte et son journal ; si la cible existe, l'ancienne s'efface")
    func renames() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let day = Fixture.date(day: 2)
        let moved = try card("barrar", created: day, in: context)
        CardReview.grade(moved, .good, at: day, in: context)
        let duplicate = try card("leo", created: day, in: context)
        let target = try card("leer", created: day, in: context)
        try context.save()

        let touched = VocabStudy.applyRenames(["barrar": "barrer", "leo": "leer"],
                                              cards: try context.fetch(FetchDescriptor<Card>()), in: context)
        #expect(touched == 2)
        #expect(moved.key == "assimil-es:V:barrer#recognize")
        #expect(moved.itemID == "assimil-es:V:barrer")
        #expect(try context.fetch(FetchDescriptor<ReviewLog>()).map(\.cardKey) == ["assimil-es:V:barrer#recognize"])
        #expect(!duplicate.isActive)
        #expect(target.isActive)
        // Rien à renommer : rien ne bouge.
        #expect(VocabStudy.applyRenames([:], cards: [moved], in: context) == 0)
    }

    // MARK: - La file d'une séance

    @Test("Séance : les dues puis les nouvelles ; une carte ratée revient dans la séance")
    func sessionQueue() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        let now = Fixture.date(day: 10, hour: 9)
        let dueCard = try card("dû", created: Fixture.date(day: 1), in: context)
        let a = VocabStudy.NewCard(item: try #require(VocabItem(lemma: "a")), angle: Card.Angle.recognize)
        let b = VocabStudy.NewCard(item: try #require(VocabItem(lemma: "b")), angle: Card.Angle.recognize)

        var session = VocabSession(due: [dueCard], new: [a, b])
        session.advance(now: now)
        #expect(session.remaining == 3)
        guard case .card(let first) = session.current else { Issue.record("une carte due d'abord"); return }
        #expect(first === dueCard)

        // Ratée : elle revient dans une minute, après les autres s'il en reste.
        CardReview.grade(dueCard, .again, at: now, in: context)
        session.finishCurrent(with: dueCard, now: now)
        #expect(session.current?.item?.lemma == "a")
        #expect(session.remaining == 3)

        // « a » est retirée : « b » suit, puis la carte ratée, même avant son heure.
        session.drop(try #require(VocabItem(lemma: "a")))
        session.finishCurrent(with: nil, now: now)
        #expect(session.current?.item?.lemma == "b")
        session.finishCurrent(with: nil, now: now)
        #expect(session.current?.item?.lemma == "dû")
        // Notée « Facile » : partie pour des jours, la séance est finie.
        CardReview.grade(dueCard, .easy, at: now.addingTimeInterval(30), in: context)
        session.finishCurrent(with: dueCard, now: now.addingTimeInterval(30))
        #expect(session.current == nil)
        #expect(session.remaining == 0)
    }

    // MARK: - Libellés

    @Test("Les délais sous les boutons")
    func delays() {
        let now = Fixture.date(day: 1)
        #expect(VocabReviewView.delay(from: now, to: now.addingTimeInterval(60)) == "1 min")
        #expect(VocabReviewView.delay(from: now, to: now.addingTimeInterval(330)) == "6 min")
        #expect(VocabReviewView.delay(from: now, to: now.addingTimeInterval(3 * 3600)) == "3 h")
        #expect(VocabReviewView.delay(from: now, to: now.addingTimeInterval(8 * 86_400)) == "8 j")
        #expect(VocabReviewView.delay(from: now, to: now.addingTimeInterval(65 * 86_400)) == "2 mois")
        #expect(VocabReviewView.delay(from: now, to: now.addingTimeInterval(500 * 86_400)) == "1,4 an")
        #expect(TodayView.vocabDetail(due: 14, new: 20) == "14 à revoir · 20 nouveaux")
        #expect(TodayView.vocabDetail(due: 1, new: 0) == "1 à revoir")
        #expect(TodayView.vocabDetail(due: 0, new: 1) == "1 nouveau")
    }
}
