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

    /// Les cartes actives arrivées à échéance.
    static func due(in cards: [Card], now: Date = .now) -> [Card] {
        cards.filter { $0.isDue(at: now) }
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

/// À quoi a servi un moment d'étude : l'activité et, pour Assimil, le cours.
struct StudyActivity: Equatable {
    let name: String
    /// Nil pour la révision : elle est commune, pas propre à un cours.
    let courseID: String?

    static let assimilDaily = StudyActivity(name: StudyEvent.Activity.assimilDaily,
                                            courseID: PackStore.assimilSpanishID)
    static let review = StudyActivity(name: StudyEvent.Activity.review, courseID: nil)
    static let assimilListen = StudyActivity(name: StudyEvent.Activity.assimilListen,
                                             courseID: PackStore.assimilSpanishID)
}

enum StudyTime {
    /// Inscrit un moment d'étude qui vient de se terminer. L'appelant passe ce que
    /// le lecteur n'a pas encore rendu (`SessionPlayer.takeUnrecordedSeconds`) :
    /// rouvrir un écran ne recompte rien.
    ///
    /// Un événement par enregistrement, jamais un total qu'on gonfle : il dit à
    /// quoi le temps a servi, et le jour se recalcule (`secondsByDay`).
    @MainActor
    static func record(_ seconds: Double, as activity: StudyActivity, in context: ModelContext,
                       now: Date = .now, calendar: Calendar = .current) {
        guard seconds > 0 else { return }
        context.insert(StudyEvent(day: calendar.startOfDay(for: now),
                                  startedAt: now.addingTimeInterval(-seconds),
                                  seconds: seconds,
                                  language: "es",
                                  activity: activity.name,
                                  courseID: activity.courseID))
    }

    /// Tout le temps d'étude, jours recopiés de l'ancien modèle compris : ceux-là
    /// ne sont plus écrits depuis la bascule, rien n'est donc compté deux fois.
    static func total(_ events: [StudyEvent]) -> Double {
        events.reduce(0) { $0 + $1.seconds }
    }

    /// Le temps par jour, sur le jour de l'événement. Rien ne l'affiche encore.
    static func secondsByDay(_ events: [StudyEvent], calendar: Calendar = .current) -> [Date: Double] {
        events.reduce(into: [:]) { $0[calendar.startOfDay(for: $1.day), default: 0] += $1.seconds }
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
