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

    @Test("Un stockage d'avant les conversations s'ouvre, cartes intactes, et en garde une")
    func storeBeforeConversationsOpens() throws {
        let url = Fixture.storeURL()
        let previous = AssimilESApp.models.filter { ObjectIdentifier($0) != ObjectIdentifier(ConversationRecord.self) }
        #expect(previous.count == AssimilESApp.models.count - 1)

        do {
            let container = try Fixture.container(at: url, models: previous)
            let item = try #require(VocabItem(lemma: "estar")).itemID()
            container.mainContext.insert(Card(item: item, angle: Card.Angle.recognize, language: "es",
                                              scheduler: Card.Scheduler.fsrs, at: Fixture.date(day: 8)))
            try container.mainContext.save()
        }

        // Le conteneur est gardé : un contexte seul ne le retient pas.
        let current = try Fixture.container(at: url)
        let context = current.mainContext
        #expect(try context.fetch(FetchDescriptor<Card>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ConversationRecord>()).isEmpty)

        let messages = [ConversationMessage(role: .assistant, content: "¿Qué tal?"),
                        ConversationMessage(role: .user, content: "Yo soy cansado.")]
        let record = ConversationRecord(startedAt: Fixture.date(day: 9), endedAt: Fixture.date(day: 9, hour: 21),
                                        messages: messages)
        context.insert(record)
        try context.save()
        let saved = try #require(try context.fetch(FetchDescriptor<ConversationRecord>()).first)
        #expect(saved.messages == messages)
        #expect(saved.reviewedCorrections == nil)
        saved.reviewedCorrections = [ConversationCorrection(said: "Yo soy cansado.", corrected: "Estoy cansado.",
                                                            explanation: "Un état : estar.")]
        try context.save()
        #expect(try context.fetch(FetchDescriptor<ConversationRecord>()).first?.reviewedCorrections?.count == 1)
    }

    @Test("Un stockage d'avant la prononciation s'ouvre, conversations intactes, et garde une prise")
    func storeBeforePronunciationOpens() throws {
        let url = Fixture.storeURL()
        let previous = AssimilESApp.models.filter { ObjectIdentifier($0) != ObjectIdentifier(PronunciationRecord.self) }
        #expect(previous.count == AssimilESApp.models.count - 1)

        do {
            let container = try Fixture.container(at: url, models: previous)
            container.mainContext.insert(ConversationRecord(startedAt: Fixture.date(day: 9), endedAt: Fixture.date(day: 9),
                                                            messages: [ConversationMessage(role: .user, content: "Hola")]))
            try container.mainContext.save()
        }

        let current = try Fixture.container(at: url)
        let context = current.mainContext
        #expect(try context.fetch(FetchDescriptor<ConversationRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<PronunciationRecord>()).isEmpty)

        let sentence = DrillSentence(lesson: 3, n: 2, text: "Una jarra.", clip: AudioClip(file: "S02.m4a", duration: 1, n: 2),
                                     targets: [.jota, .r])
        let fault = JudgedPhone(expected: "r", heard: "ʁ", fault: true, reason: "r", hint: false, tip: "Le r…",
                                score: nil, threshold: nil, start: 0.5, end: 0.6)
        let result = PronunciationResult(words: [JudgedWord(text: "una", fault: false, phonemes: []),
                                                 JudgedWord(text: "jarra", fault: true, phonemes: [fault])],
                                         heard: "u n a x a ʁ a", seconds: 0.2)
        context.insert(PronunciationRecord(judgedAt: Fixture.date(day: 10), sentence: sentence, attempt: 2, result: result))
        try context.save()

        let saved = try #require(try context.fetch(FetchDescriptor<PronunciationRecord>()).first)
        #expect(saved.lesson == 3 && saved.sentence == 2 && saved.attempt == 2)
        #expect(saved.text == "Una jarra.")
        #expect(saved.faultSymbols == ["r"])
        #expect(saved.result == result)
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
