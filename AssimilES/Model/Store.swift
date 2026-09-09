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

/// Phrase marquée difficile d'un geste pendant l'écoute. C'est la file de
/// révision : une liste que l'usage remplit tout seul, sans effort de saisie.
@Model
final class DifficultSentence {
    #Unique<DifficultSentence>([\.key])

    /// « L012-S04 » — unique, et lisible en débogage.
    var key: String = ""
    var lessonNumber: Int = 0
    var sentenceNumber: Int = 0
    var isExercise: Bool = false
    var markedAt: Date = Date.now

    /// Quand la phrase doit revenir. Une phrase fraîchement marquée est due tout
    /// de suite : c'est le jour même qu'elle résiste.
    var dueAt: Date = Date.now
    /// Nombre de fois où elle est revenue. C'est lui qui donne l'intervalle
    /// suivant — la phrase ne sort jamais de la file d'elle-même, seul le
    /// drapeau l'en retire.
    var reviewCount: Int = 0
    var lastReviewedAt: Date?

    init(lessonNumber: Int, sentenceNumber: Int, isExercise: Bool) {
        self.key = Self.makeKey(lessonNumber, sentenceNumber, isExercise)
        self.lessonNumber = lessonNumber
        self.sentenceNumber = sentenceNumber
        self.isExercise = isExercise
        self.markedAt = .now
        self.dueAt = .now
    }

    var isDue: Bool { dueAt <= .now }

    /// Appelée quand la phrase vient d'être rejouée en révision. L'intervalle est
    /// choisi sur le nombre de passages **avant** celui-ci : la première reprise
    /// tombe le lendemain.
    func recordReview(at date: Date = .now) {
        dueAt = ReviewSchedule.next(after: reviewCount, from: date)
        reviewCount += 1
        lastReviewedAt = date
    }

    static func makeKey(_ lesson: Int, _ sentence: Int, _ isExercise: Bool) -> String {
        String(format: "L%03d-%@%02d", lesson, isExercise ? "T" : "S", sentence)
    }
}

/// Révision espacée des phrases marquées.
///
/// Pas de notation : l'app sert à marcher en écoutant, et noter chaque phrase
/// demanderait l'œil sur l'écran à chaque pause. La phrase revient donc à
/// intervalle croissant tant qu'elle est marquée, et c'est le même drapeau qu'en
/// écoute qui l'enlève quand elle est acquise — un seul geste, déjà connu.
enum ReviewSchedule {
    /// Intervalles en jours. La suite s'arrête à 60 : au-delà, une phrase qu'on
    /// n'a pas retirée du drapeau mérite de revenir de temps en temps, pas de
    /// disparaître.
    static let intervals = [1, 3, 7, 21, 60]

    /// L'échéance est calée sur le début de journée : une phrase revue le soir
    /// revient le lendemain, pas le lendemain soir. La séance est quotidienne,
    /// l'heure n'a pas à décider de ce qui est dû.
    static func next(after reviewCount: Int,
                     from date: Date = .now,
                     calendar: Calendar = .current) -> Date {
        let days = intervals[min(max(0, reviewCount), intervals.count - 1)]
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: days, to: start) ?? date
    }

    static func due(in marks: [DifficultSentence], now: Date = .now) -> [DifficultSentence] {
        marks.filter { $0.dueAt <= now }
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
