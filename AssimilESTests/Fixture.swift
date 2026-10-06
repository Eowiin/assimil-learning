import Foundation
import SwiftData
@testable import AssimilES

/// Données fictives. Le contenu Assimil est hors dépôt : aucun test versionné ne
/// s'appuie dessus.
enum Fixture {

    /// Un catalogue fictif bâti comme le vrai : une révision hebdomadaire toutes les
    /// 7 leçons, sans exercice audio.
    static func manifest(lessonCount: Int = 100, sentences: Int = 3, exercises: Int = 2) -> Manifest {
        var lessons: [[String: Any]] = []
        for n in 1...lessonCount {
            let isReview = n % 7 == 0 && n < lessonCount
            let dialogue: [[String: Any]] = (1...sentences).map {
                ["file": String(format: "S%02d.m4a", $0), "duration": 2.0, "n": $0]
            }
            let exercise: [[String: Any]] = isReview ? [] : (1...exercises).map {
                ["file": String(format: "T%02d.m4a", $0), "duration": 1.5, "n": $0]
            }
            var lesson: [String: Any] = [
                "number": n, "isReview": isReview, "dir": String(format: "L%03d", n),
                "title": ["file": "S00-TITLE.m4a", "duration": 1.0],
                "dialogue": dialogue, "exercise": exercise,
            ]
            if !isReview { lesson["exerciseIntro"] = ["file": "T00-TRANSLATE.m4a", "duration": 2.0] }
            lessons.append(lesson)
        }
        let json: [String: Any] = [
            "version": 1, "lessonCount": lessonCount, "sentenceCount": lessonCount * sentences,
            "totalDuration": 1000.0, "lessons": lessons,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        var manifest = try! JSONDecoder().decode(Manifest.self, from: data)
        manifest.audioRoot = URL(fileURLWithPath: "/fictif/audio")
        return manifest
    }

    static func text(_ json: String) throws -> LessonText {
        try JSONDecoder().decode(LessonText.self, from: Data(json.utf8))
    }

    @MainActor
    static func container(at url: URL? = nil,
                          models: [any PersistentModel.Type] = AssimilESApp.models) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func storeURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("assimil-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("test.store")
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    /// Un jour de septembre 2026, heure locale de Paris.
    static func date(day: Int, hour: Int = 9, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    /// Ce que ferait l'apprenant : chaque étape terminée par son geste, les exercices
    /// confirmés faits dans le livre.
    @MainActor
    static func completeEveryStage(_ session: DailySession, manifest: Manifest) {
        let plan = Curriculum.plan(unit: session.unit, manifest: manifest)!
        var progress = session.progress
        for stage in plan.stages where stage != .finish {
            if stage.isExercise { progress.doneInBook.insert(stage) }
            progress.complete(stage, in: plan.stages)
        }
        session.progress = progress
    }
}
