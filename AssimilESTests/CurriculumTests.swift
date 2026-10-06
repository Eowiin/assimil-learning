import Foundation
import Testing
@testable import AssimilES

@Suite("Parcours : contenu d'une séance")
struct CurriculumTests {
    let manifest = Fixture.manifest()

    @Test("Une leçon ordinaire suit les six étapes")
    func ordinaryLesson() throws {
        let plan = try #require(Curriculum.plan(unit: 12, manifest: manifest))
        #expect(plan.newLesson == 12)
        #expect(plan.waveLesson == nil)
        #expect(!plan.isWeeklyReview)
        #expect(plan.stages == [.discovery, .comprehension, .repetition, .translation, .completion, .finish])
    }

    @Test("Une révision hebdomadaire n'a pas les exercices ordinaires")
    func weeklyReview() throws {
        for unit in stride(from: 7, through: 98, by: 7) {
            let plan = try #require(Curriculum.plan(unit: unit, manifest: manifest))
            #expect(plan.isWeeklyReview)
            #expect(!plan.stages.contains(.translation))
            #expect(!plan.stages.contains(.completion))
            #expect(plan.stages.first == .discovery)
            #expect(plan.stages.last == .finish)
        }
    }

    @Test("La deuxième vague commence à la leçon 50 avec la leçon 1")
    func waveStart() throws {
        #expect(Curriculum.plan(unit: 49, manifest: manifest)?.waveLesson == nil)
        let plan = try #require(Curriculum.plan(unit: 50, manifest: manifest))
        #expect(plan.newLesson == 50)
        #expect(plan.waveLesson == 1)
        #expect(plan.stages.suffix(2) == [.secondWave, .finish])
        // Une révision hebdomadaire reprise en deuxième vague, à côté d'une leçon ordinaire.
        #expect(Curriculum.plan(unit: 56, manifest: manifest)?.waveLesson == 7)
    }

    @Test("Après la dernière leçon, la vague continue seule jusqu'à la leçon 100")
    func waveAfterLastLesson() throws {
        let last = try #require(Curriculum.plan(unit: 100, manifest: manifest))
        #expect(last.newLesson == 100)
        #expect(last.waveLesson == 51)

        let next = try #require(Curriculum.plan(unit: 101, manifest: manifest))
        #expect(next.newLesson == nil)
        #expect(next.waveLesson == 52)
        #expect(next.stages == [.secondWave, .finish])
        #expect(next.headlineLesson == 52)

        #expect(Curriculum.lastUnit(in: manifest) == 149)
        #expect(Curriculum.plan(unit: 149, manifest: manifest)?.waveLesson == 100)
        #expect(Curriculum.plan(unit: 150, manifest: manifest) == nil)
        #expect(Curriculum.plan(unit: 0, manifest: manifest) == nil)
    }

    /// Le manifest versionné ne contient que des noms de fichiers et des durées.
    @Test("Catalogue réel : les révisions 7…98 n'ont pas d'exercice audio, les autres si")
    func realCatalog() {
        for lesson in Manifest.shared.lessons {
            let isWeekly = lesson.number % 7 == 0 && lesson.number <= 98
            #expect(lesson.isReview == isWeekly, "leçon \(lesson.number)")
            #expect(lesson.exercise.isEmpty == isWeekly, "leçon \(lesson.number)")
        }
    }
}
