import Foundation
import SwiftData

/// Reprise exacte de l'écoute libre : où en était la leçon quand elle a été quittée.
///
/// **Une ligne par leçon**, et non par leçon et par mode : la contrainte d'unicité
/// porte sur `lessonNumber`. Insérer une seconde ligne pour un autre mode ne créait
/// pas de doublon, elle *remplaçait* la première — la reprise d'un mode écrasait
/// celle de l'autre sans le dire. La ligne garde donc le mode de sa reprise, et une
/// reprise ne s'applique qu'à ce mode. Modifier la contrainte aurait demandé une
/// migration de schéma pour un gain nul.
///
/// Rien ici ne concerne le parcours quotidien, qui vit dans `DailySession`.
@Model
final class LessonProgress {
    #Unique<LessonProgress>([\.lessonNumber])

    var lessonNumber: Int = 0
    /// Index dans la séquence de la séance, pas numéro de phrase : c'est ce qui
    /// permet de reprendre au milieu d'une pause ou d'un exercice.
    var stepIndex: Int = 0
    var mode: String = ""
    /// Fin d'écoute enregistrée par les versions précédentes. Conservée pour ne pas
    /// toucher au schéma, plus écrite ni lue : arriver au bout d'une piste ne dit
    /// pas qu'une leçon est travaillée.
    var completedAt: Date?
    var updatedAt: Date = Date.now

    init(lessonNumber: Int, stepIndex: Int = 0, mode: String = "") {
        self.lessonNumber = lessonNumber
        self.stepIndex = stepIndex
        self.mode = mode
        self.updatedAt = .now
    }
}

/// Phrase marquée difficile d'un geste pendant l'écoute — l'ancienne file de
/// révision. **Plus écrite depuis la bascule** : c'est `Card` qui tient la file. La
/// table reste dans le schéma, figée, et `LegacyCopy` la lit une dernière fois.
@Model
final class DifficultSentence {
    #Unique<DifficultSentence>([\.key])

    /// « L012-S04 » — unique, et lisible en débogage.
    var key: String = ""
    var lessonNumber: Int = 0
    var sentenceNumber: Int = 0
    var isExercise: Bool = false
    var markedAt: Date = Date.now

    /// Échéance et nombre de revues tels que l'ancienne file les tenait, figés à la
    /// bascule : `Card.dueAt` et `Card.reps` ont pris le relais.
    var dueAt: Date = Date.now
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

    static func makeKey(_ lesson: Int, _ sentence: Int, _ isExercise: Bool) -> String {
        String(format: "L%03d-%@%02d", lesson, isExercise ? "T" : "S", sentence)
    }
}

/// Le temps écouté, un total par jour — l'ancien modèle. **Plus écrit depuis la
/// bascule** : `StudyEvent` le remplace, et les jours recopiés y restent
/// (« assimil.legacy »).
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

/// Une séance du parcours quotidien : une nouvelle leçon et ses activités, la
/// deuxième vague quand elle a commencé.
///
/// Une séance n'est jamais modifiée par l'écoute libre. Sa validation est une date,
/// posée une fois ; la progression se déduit des séances validées (`DailyCourse`),
/// elle n'est jamais incrémentée.
@Model
final class DailySession {
    #Unique<DailySession>([\.key])

    /// « U012-1 » : séance 12, premier essai. Une leçon retravaillée le lendemain
    /// ouvre un second essai.
    var key: String = ""
    var unit: Int = 0
    var attempt: Int = 1
    var startedAt: Date = Date.now
    var updatedAt: Date = Date.now
    var completedAt: Date?
    /// Retravailler la même leçon le lendemain, en cas de difficulté.
    var repeatTomorrow: Bool = false
    /// `DailyProgress` en JSON : l'avancement évolue plus vite que le schéma, et un
    /// champ ajouté plus tard ne demande pas de migration.
    var progressData: Data = Data()

    init(unit: Int, attempt: Int, startedAt: Date, stages: [DailyStage]) {
        self.key = Self.makeKey(unit: unit, attempt: attempt)
        self.unit = unit
        self.attempt = attempt
        self.startedAt = startedAt
        self.updatedAt = startedAt
        self.progressData = (try? JSONEncoder().encode(DailyProgress(stages: stages))) ?? Data()
    }

    var progress: DailyProgress {
        get {
            // Un avancement illisible repart de la découverte. Le modèle ne connaît
            // pas le paquet de contenu, donc pas les étapes exactes de la séance :
            // la vue les applique (une étape absente du plan n'est jamais ouverte).
            (try? JSONDecoder().decode(DailyProgress.self, from: progressData))
                ?? DailyProgress(stages: DailyStage.allCases)
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue), data != progressData else { return }
            progressData = data
            updatedAt = .now
        }
    }

    var isValidated: Bool { completedAt != nil }

    static func makeKey(unit: Int, attempt: Int) -> String {
        String(format: "U%03d-%d", unit, attempt)
    }
}

/// Le point de départ du parcours. Créé au premier lancement depuis l'ancien réglage
/// manuel, déplacé seulement par un repositionnement explicite.
@Model
final class CourseAnchor {
    #Unique<CourseAnchor>([\.key])

    var key: String = "course"
    var unit: Int = 1
    /// Les séances validées avant cette date ne comptent plus pour la suite.
    var setAt: Date = Date.distantPast

    init(unit: Int, setAt: Date) {
        self.unit = unit
        self.setAt = setAt
    }
}

enum Streak {
    /// Nombre de jours consécutifs avec une séance validée, en comptant aujourd'hui,
    /// ou hier si la séance du jour n'est pas encore validée (sinon la série
    /// paraîtrait rompue tous les matins).
    ///
    /// La validation, pas le temps écouté : quelques secondes de découverte ne
    /// font pas une séance, et la série ne doit pas dire le contraire de l'accueil.
    static func current(validatedOn dates: [Date], today: Date, calendar: Calendar = .current) -> Int {
        let validated = days(validatedOn: dates, calendar: calendar)
        guard !validated.isEmpty else { return 0 }

        let start = calendar.startOfDay(for: today)
        var cursor = validated.contains(start)
            ? start
            : calendar.date(byAdding: .day, value: -1, to: start)!

        var count = 0
        while validated.contains(cursor) {
            count += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return count
    }

    /// Les jours où une séance a été validée, ramenés à leur début.
    static func days(validatedOn dates: [Date], calendar: Calendar = .current) -> Set<Date> {
        Set(dates.map { calendar.startOfDay(for: $0) })
    }
}
