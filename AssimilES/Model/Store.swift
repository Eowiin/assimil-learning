import Foundation
import SwiftData

/// Reprise exacte : où en était la leçon quand elle a été quittée.
@Model
final class LessonProgress {
    #Unique<LessonProgress>([\.lessonNumber])

    var lessonNumber: Int = 0
    /// Index dans la séquence de la séance, pas numéro de phrase : c'est ce qui
    /// permet de reprendre au milieu d'une pause ou d'un exercice.
    var stepIndex: Int = 0
    var mode: String = ""
    var completedAt: Date?
    var updatedAt: Date = Date.now

    init(lessonNumber: Int, stepIndex: Int = 0, mode: String = "") {
        self.lessonNumber = lessonNumber
        self.stepIndex = stepIndex
        self.mode = mode
        self.updatedAt = .now
    }
}

/// Phrase marquée difficile d'un geste pendant l'écoute. Alimente la liste de
/// révision, et servira de base au SRS.
@Model
final class DifficultSentence {
    #Unique<DifficultSentence>([\.key])

    /// « L012-S04 » — unique, et lisible en débogage.
    var key: String = ""
    var lessonNumber: Int = 0
    var sentenceNumber: Int = 0
    var isExercise: Bool = false
    var markedAt: Date = Date.now

    init(lessonNumber: Int, sentenceNumber: Int, isExercise: Bool) {
        self.key = Self.makeKey(lessonNumber, sentenceNumber, isExercise)
        self.lessonNumber = lessonNumber
        self.sentenceNumber = sentenceNumber
        self.isExercise = isExercise
        self.markedAt = .now
    }

    static func makeKey(_ lesson: Int, _ sentence: Int, _ isExercise: Bool) -> String {
        String(format: "L%03d-%@%02d", lesson, isExercise ? "T" : "S", sentence)
    }
}

/// Un jour d'étude. Assimil ne tient que sur la régularité : c'est la série de
/// jours consécutifs qui est motivante, pas le volume total.
@Model
final class StudyDay {
    #Unique<StudyDay>([\.day])

    var day: Date = Date.now
    var seconds: Double = 0

    init(day: Date, seconds: Double = 0) {
        self.day = day
        self.seconds = seconds
    }
}

enum Streak {
    /// Nombre de jours consécutifs d'étude en comptant aujourd'hui, ou hier si
    /// la séance du jour n'a pas encore eu lieu (sinon la série paraîtrait rompue
    /// tous les matins).
    static func current(from days: [StudyDay], calendar: Calendar = .current) -> Int {
        let studied = Set(days.filter { $0.seconds > 0 }.map { calendar.startOfDay(for: $0.day) })
        guard !studied.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: .now)
        var cursor = studied.contains(today)
            ? today
            : calendar.date(byAdding: .day, value: -1, to: today)!

        var count = 0
        while studied.contains(cursor) {
            count += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return count
    }
}
