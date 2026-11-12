import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Migration des données existantes")
@MainActor
struct MigrationTests {
    let legacyModels: [any PersistentModel.Type] = [LessonProgress.self, DifficultSentence.self, StudyDay.self]

    @Test("Un stockage de l'ancienne version s'ouvre avec les nouveaux modèles, données intactes")
    func legacyStoreOpens() throws {
        let url = Fixture.storeURL()
        let day = Fixture.calendar.startOfDay(for: Fixture.date(day: 8))

        do {
            let legacy = try Fixture.container(at: url, models: legacyModels)
            let context = legacy.mainContext
            let listened = LessonProgress(lessonNumber: 12, stepIndex: 30, mode: StudyMode.shadowing.rawValue)
            // L'ancienne version posait cette date à la fin de l'audio.
            listened.completedAt = Fixture.date(day: 9)
            context.insert(listened)
            context.insert(DifficultSentence(lessonNumber: 12, sentenceNumber: 3, isExercise: false))
            context.insert(StudyDay(day: day, seconds: 600))
            try context.save()
        }

        let current = try Fixture.container(at: url)
        let context = current.mainContext
        let progress = try context.fetch(FetchDescriptor<LessonProgress>())
        #expect(progress.count == 1)
        #expect(progress.first?.stepIndex == 30)
        #expect(try context.fetch(FetchDescriptor<DifficultSentence>()).first?.key == "L012-S03")
        #expect(try context.fetch(FetchDescriptor<StudyDay>()).first?.seconds == 600)
        #expect(try context.fetch(FetchDescriptor<DailySession>()).isEmpty)

        // Le parcours part de l'ancien réglage ; l'ancienne fin d'écoute ne valide rien.
        let store = DailyCourseStore(context: context, manifest: Fixture.manifest(), calendar: Fixture.calendar)
        let anchor = store.ensureAnchor(legacyLesson: 12)
        #expect(anchor.unit == 12)
        guard case .ready(let plan) = store.status(now: Fixture.date(day: 9, hour: 20), legacyLesson: 12) else {
            Issue.record("la leçon 12 doit rester à faire"); return
        }
        #expect(plan.unit == 12)

        // L'ancre n'est créée qu'une fois : changer l'ancien réglage ensuite n'y fait rien.
        #expect(store.ensureAnchor(legacyLesson: 40).unit == 12)
        #expect(try context.fetch(FetchDescriptor<CourseAnchor>()).count == 1)
    }

    /// Le schéma de l'étape 2 (PR #46), avant l'ajout des cartes et du journal.
    let packStoreModels: [any PersistentModel.Type] = [
        LessonProgress.self, DifficultSentence.self, StudyDay.self, DailySession.self, CourseAnchor.self,
    ]

    @Test("Un stockage d'avant les cartes s'ouvre avec le nouveau schéma, données intactes")
    func storeBeforeCardsOpens() throws {
        let url = Fixture.storeURL()
        let day = Fixture.calendar.startOfDay(for: Fixture.date(day: 8))

        do {
            let previous = try Fixture.container(at: url, models: packStoreModels)
            let context = previous.mainContext
            context.insert(LessonProgress(lessonNumber: 12, stepIndex: 30, mode: StudyMode.shadowing.rawValue))
            let mark = DifficultSentence(lessonNumber: 12, sentenceNumber: 3, isExercise: false)
            mark.recordReview(at: Fixture.date(day: 8))
            context.insert(mark)
            context.insert(StudyDay(day: day, seconds: 600))
            let session = DailySession(unit: 12, attempt: 1, startedAt: Fixture.date(day: 8), stages: DailyStage.allCases)
            session.completedAt = Fixture.date(day: 8, hour: 21)
            context.insert(session)
            context.insert(CourseAnchor(unit: 10, setAt: Fixture.date(day: 1)))
            try context.save()
        }

        let current = try Fixture.container(at: url)
        let context = current.mainContext
        #expect(try context.fetch(FetchDescriptor<LessonProgress>()).first?.stepIndex == 30)
        let mark = try #require(try context.fetch(FetchDescriptor<DifficultSentence>()).first)
        #expect(mark.key == "L012-S03")
        #expect(mark.reviewCount == 1)
        #expect(try context.fetch(FetchDescriptor<StudyDay>()).first?.seconds == 600)
        #expect(try context.fetch(FetchDescriptor<DailySession>()).first?.completedAt == Fixture.date(day: 8, hour: 21))
        #expect(try context.fetch(FetchDescriptor<CourseAnchor>()).first?.unit == 10)
        // Les nouvelles tables existent, vides tant que la copie n'est pas passée.
        #expect(try context.fetch(FetchDescriptor<Card>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<ReviewLog>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<StudyEvent>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<DataMigration>()).isEmpty)

        // La copie passe sur ce stockage réel, et le relancer n'y change rien.
        let report = try #require(LegacyCopy.run(in: context))
        #expect(report.cardsCreated == 1 && report.eventsCreated == 1)
        #expect(try context.fetch(FetchDescriptor<Card>()).first?.reps == 1)
        #expect(LegacyCopy.run(in: context) == LegacyCopy.Report())
    }

    @Test("Ancien réglage hors limites ramené dans le catalogue")
    func legacyLessonClamped() throws {
        let container = try Fixture.container()
        let store = DailyCourseStore(context: container.mainContext, manifest: Fixture.manifest(), calendar: Fixture.calendar)
        #expect(store.ensureAnchor(legacyLesson: 0).unit == 1)
    }

    /// Ce que la contrainte d'unicité sur `lessonNumber` fait réellement : une seconde
    /// ligne pour la même leçon remplace la première. C'est pourquoi l'écoute libre met
    /// à jour la ligne de la leçon au lieu d'en insérer une par mode.
    @Test("LessonProgress : une seule ligne par leçon, quel que soit le mode")
    func lessonProgressIsUniquePerLesson() throws {
        let container = try Fixture.container()
        let context = container.mainContext
        context.insert(LessonProgress(lessonNumber: 5, stepIndex: 10, mode: StudyMode.shadowing.rawValue))
        try context.save()
        context.insert(LessonProgress(lessonNumber: 5, stepIndex: 3, mode: StudyMode.passive.rawValue))
        try context.save()

        let rows = try context.fetch(FetchDescriptor<LessonProgress>())
        #expect(rows.filter { $0.lessonNumber == 5 }.count == 1)
    }
}
