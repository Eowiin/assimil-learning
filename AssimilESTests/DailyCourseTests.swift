import Foundation
import SwiftData
import Testing
@testable import AssimilES

@Suite("Parcours : progression quotidienne")
@MainActor
struct DailyCourseTests {
    let manifest = Fixture.manifest()
    let container: ModelContainer
    let store: DailyCourseStore

    init() throws {
        container = try Fixture.container()
        store = DailyCourseStore(context: container.mainContext, manifest: manifest, calendar: Fixture.calendar)
    }

    private func status(_ date: Date, legacy: Int = 12) -> DayStatus {
        store.status(now: date, legacyLesson: legacy)
    }

    private func validatedSession(unit legacy: Int = 12, at date: Date) throws -> DailySession {
        let session = try #require(store.startOrResume(now: date, legacyLesson: legacy))
        Fixture.completeEveryStage(session, manifest: manifest)
        #expect(store.validate(session, now: date))
        return session
    }

    @Test("Séance complète, puis rien de nouveau le même jour")
    func sameDay() throws {
        let morning = Fixture.date(day: 10, hour: 8)
        #expect(status(morning).plan?.unit == 12)

        let session = try #require(store.startOrResume(now: morning, legacyLesson: 12))
        #expect(session.unit == 12)
        guard case .inProgress(let open, _) = status(morning) else { Issue.record("séance attendue en cours"); return }
        #expect(open === session)

        Fixture.completeEveryStage(session, manifest: manifest)
        #expect(store.validate(session, now: Fixture.date(day: 10, hour: 9)))

        guard case .doneToday(let done, let plan, let tomorrow) = status(Fixture.date(day: 10, hour: 23, minute: 59)) else {
            Issue.record("séance attendue terminée"); return
        }
        #expect(done === session)
        #expect(plan.unit == 12)
        #expect(tomorrow?.unit == 13)
        #expect(store.startOrResume(now: Fixture.date(day: 10, hour: 22), legacyLesson: 12) == nil)
        #expect(store.sessions().count == 1)
    }

    @Test("Le lendemain calendaire propose la suivante, sans attendre 24 heures")
    func nextCalendarDay() throws {
        _ = try validatedSession(at: Fixture.date(day: 10, hour: 23, minute: 30))
        guard case .ready(let plan) = status(Fixture.date(day: 11, hour: 0, minute: 5)) else {
            Issue.record("séance suivante attendue"); return
        }
        #expect(plan.unit == 13)
    }

    @Test("Des jours manqués ne font sauter aucune leçon")
    func missedDays() throws {
        _ = try validatedSession(at: Fixture.date(day: 1))
        #expect(status(Fixture.date(day: 20)) == .ready(Curriculum.plan(unit: 13, manifest: manifest)!))
    }

    @Test("Une séance inachevée se reprend le lendemain, là où elle était")
    func resumeUnfinished() throws {
        let session = try #require(store.startOrResume(now: Fixture.date(day: 10), legacyLesson: 12))
        var progress = session.progress
        progress.complete(.discovery, in: Curriculum.plan(unit: 12, manifest: manifest)!.stages)
        session.progress = progress
        store.save()

        guard case .inProgress(let open, _) = status(Fixture.date(day: 11)) else {
            Issue.record("reprise attendue"); return
        }
        #expect(open === session)
        #expect(open.progress.current == .comprehension)
        #expect(store.startOrResume(now: Fixture.date(day: 11), legacyLesson: 12) === session)
        #expect(store.sessions().count == 1)
    }

    @Test("Valider deux fois n'avance qu'une fois")
    func idempotentValidation() throws {
        let session = try validatedSession(at: Fixture.date(day: 10, hour: 9))
        let firstValidation = session.completedAt

        #expect(!store.validate(session, now: Fixture.date(day: 10, hour: 18)))
        #expect(!store.validate(session, now: Fixture.date(day: 11, hour: 8)))
        #expect(session.completedAt == firstValidation)
        #expect(status(Fixture.date(day: 11)).plan?.unit == 13)
        #expect(store.sessions().count == 1)
    }

    @Test("Une simple écoute ne valide pas")
    func listeningDoesNotValidate() throws {
        let session = try #require(store.startOrResume(now: Fixture.date(day: 10), legacyLesson: 12))
        var progress = session.progress
        progress.recordAudio(.discovery, sentence: nil)
        progress.recordAudio(.repetition, sentence: nil)
        session.progress = progress

        #expect(!store.validate(session, now: Fixture.date(day: 10, hour: 10)))
        #expect(session.completedAt == nil)
        guard case .inProgress = status(Fixture.date(day: 11)) else {
            Issue.record("la séance doit rester en cours"); return
        }
    }

    @Test("Retravailler la leçon le lendemain rouvre la même séance")
    func repeatTomorrow() throws {
        let session = try validatedSession(at: Fixture.date(day: 10))
        store.setRepeatTomorrow(session, true)
        guard case .doneToday(_, _, let tomorrow) = status(Fixture.date(day: 10, hour: 20)) else {
            Issue.record("séance du jour attendue"); return
        }
        #expect(tomorrow?.unit == 12)

        let retake = try #require(store.startOrResume(now: Fixture.date(day: 11), legacyLesson: 12))
        #expect(retake.unit == 12)
        #expect(retake.attempt == 2)
        #expect(retake.key == "U012-2")
        #expect(retake.progress.current == .discovery)
    }

    @Test("Révision hebdomadaire validée sans exercices, puis leçon suivante le lendemain")
    func weeklyReview() throws {
        let session = try #require(store.startOrResume(now: Fixture.date(day: 10), legacyLesson: 7))
        let plan = try #require(Curriculum.plan(unit: 7, manifest: manifest))
        var progress = session.progress
        for stage in [DailyStage.discovery, .comprehension, .repetition] {
            do { let done = progress.complete(stage, in: plan.stages); #expect(done) }
        }
        session.progress = progress
        #expect(progress.canValidate(plan.stages))
        #expect(store.validate(session, now: Fixture.date(day: 10)))
        #expect(status(Fixture.date(day: 11), legacy: 7).plan?.unit == 8)
    }

    @Test("Exercices absents : validés par confirmation du livre")
    func bookConfirmation() throws {
        let session = try #require(store.startOrResume(now: Fixture.date(day: 10), legacyLesson: 12))
        let plan = try #require(Curriculum.plan(unit: 12, manifest: manifest))
        var progress = session.progress
        for stage in [DailyStage.discovery, .comprehension, .repetition] { progress.complete(stage, in: plan.stages) }
        do { let done = progress.complete(.translation, in: plan.stages); #expect(!done) }
        progress.doneInBook.insert(.translation)
        do { let done = progress.complete(.translation, in: plan.stages); #expect(done) }
        session.progress = progress
        #expect(!store.validate(session, now: Fixture.date(day: 10)))

        progress.doneInBook.insert(.completion)
        do { let done = progress.complete(.completion, in: plan.stages); #expect(done) }
        session.progress = progress
        #expect(store.validate(session, now: Fixture.date(day: 10)))
    }

    @Test("La vague accompagne les leçons 50 à 100, puis continue seule jusqu'au bout")
    func secondWaveToTheEnd() throws {
        let hundred = try validatedSession(unit: 100, at: Fixture.date(day: 1))
        #expect(Curriculum.plan(unit: hundred.unit, manifest: manifest)?.waveLesson == 51)

        guard case .ready(let after) = status(Fixture.date(day: 2), legacy: 100) else {
            Issue.record("vague seule attendue"); return
        }
        #expect(after.newLesson == nil)
        #expect(after.waveLesson == 52)

        store.reposition(toLesson: 100, now: Fixture.date(day: 2, hour: 10), legacyLesson: 100)
        let anchor = try #require(store.anchor())
        anchor.unit = 149
        store.save()
        _ = try validatedSession(unit: 100, at: Fixture.date(day: 3))
        #expect(status(Fixture.date(day: 4)) == .courseComplete)
    }

    @Test("Replacer le parcours abandonne la séance en cours, garde les validées")
    func reposition() throws {
        _ = try validatedSession(at: Fixture.date(day: 9))
        let open = try #require(store.startOrResume(now: Fixture.date(day: 10), legacyLesson: 12))
        #expect(open.unit == 13)

        store.reposition(toLesson: 30, now: Fixture.date(day: 10, hour: 12), legacyLesson: 12)
        #expect(status(Fixture.date(day: 10, hour: 13)).plan?.unit == 30)
        #expect(store.sessions().filter(\.isValidated).count == 1)
    }

    @Test("La consultation libre ne touche pas au parcours")
    func freeConsultation() throws {
        let before = status(Fixture.date(day: 10))
        let context = container.mainContext
        context.insert(LessonProgress(lessonNumber: 40, stepIndex: 17, mode: StudyMode.shadowing.rawValue))
        context.insert(StudyDay(day: Fixture.calendar.startOfDay(for: Fixture.date(day: 10)), seconds: 300))
        let old = LessonProgress(lessonNumber: 12, stepIndex: 0, mode: StudyMode.passive.rawValue)
        old.completedAt = Fixture.date(day: 10)
        context.insert(old)
        try context.save()

        #expect(status(Fixture.date(day: 10)) == before)
        #expect(store.sessions().isEmpty)
    }
}

@Suite("Parcours : reprise après fermeture de l'app")
@MainActor
struct DailyCourseRelaunchTests {
    let manifest = Fixture.manifest()

    @Test("Chaque étape se retrouve après relance", arguments: 0..<6)
    func resumeAtEveryStage(completedCount: Int) throws {
        let url = Fixture.storeURL()
        let stages = try #require(Curriculum.plan(unit: 12, manifest: manifest)).stages

        do {
            let container = try Fixture.container(at: url)
            let store = DailyCourseStore(context: container.mainContext, manifest: manifest, calendar: Fixture.calendar)
            let session = try #require(store.startOrResume(now: Fixture.date(day: 10), legacyLesson: 12))
            var progress = session.progress
            for stage in stages.prefix(completedCount) {
                if stage.isExercise { progress.doneInBook.insert(stage) }
                progress.complete(stage, in: stages)
            }
            progress.recordAudio(.repetition, sentence: 2)
            progress.setReveal(.translation, 1, RevealState(revealed: true, outcome: .knew))
            var attempt = FillInAttempt()
            attempt.typed = ["tu"]
            attempt.checks = 1
            progress.setFillIn(1, attempt)
            session.progress = progress
            store.save()
        }

        let reopened = try Fixture.container(at: url)
        let store = DailyCourseStore(context: reopened.mainContext, manifest: manifest, calendar: Fixture.calendar)
        guard case .inProgress(let session, _) = store.status(now: Fixture.date(day: 11), legacyLesson: 12) else {
            Issue.record("séance en cours attendue"); return
        }
        let progress = session.progress
        #expect(progress.current == stages[min(completedCount, stages.count - 1)])
        #expect(progress.completed.count == min(completedCount, stages.count - 1))
        #expect(progress.audioSentence(for: .repetition) == 2)
        #expect(progress.reveal(.translation, 1).outcome == .knew)
        #expect(progress.fillIn(1).typed == ["tu"])
    }

    @Test("Une validation relue après relance n'avance pas deux fois")
    func validationSurvivesRelaunch() throws {
        let url = Fixture.storeURL()
        do {
            let container = try Fixture.container(at: url)
            let store = DailyCourseStore(context: container.mainContext, manifest: manifest, calendar: Fixture.calendar)
            let session = try #require(store.startOrResume(now: Fixture.date(day: 10), legacyLesson: 12))
            Fixture.completeEveryStage(session, manifest: manifest)
            #expect(store.validate(session, now: Fixture.date(day: 10)))
        }
        let reopened = try Fixture.container(at: url)
        let store = DailyCourseStore(context: reopened.mainContext, manifest: manifest, calendar: Fixture.calendar)
        guard case .doneToday(let session, _, let tomorrow) = store.status(now: Fixture.date(day: 10, hour: 21), legacyLesson: 12) else {
            Issue.record("séance du jour attendue"); return
        }
        #expect(!store.validate(session, now: Fixture.date(day: 10, hour: 21)))
        #expect(tomorrow?.unit == 13)
        #expect(store.status(now: Fixture.date(day: 11), legacyLesson: 12).plan?.unit == 13)
    }
}
