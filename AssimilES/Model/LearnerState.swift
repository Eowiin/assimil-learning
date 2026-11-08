import Foundation
import SwiftData

// L'état de l'apprenant, commun à tous les modules : cartes, journal des revues,
// temps d'étude. Le contenu n'y entre pas — une carte désigne son élément par
// `ItemID`, le paquet fournit le reste.
//
// Ces tables s'ajoutent aux anciennes (migration légère). Depuis la bascule, la
// révision, le drapeau et le temps d'étude n'écrivent plus qu'ici ;
// `DifficultSentence` et `StudyDay` restent dans le schéma, figés.

/// Un élément à retenir, sous un angle donné. « Écouter la phrase L012:S04 » est une
/// carte ; « la retrouver depuis le français » en serait une autre, sur le même item.
@Model
final class Card {
    #Unique<Card>([\.key])
    #Index<Card>([\.dueAt], [\.itemID])

    /// « assimil-es:L012:S04#listen ». Pas `id` : sous `@Model`, ce nom entre en
    /// conflit avec l'`id` d'`Identifiable`.
    var key: String = ""
    /// « assimil-es:L012:S04 » — ce qui relie la carte au contenu du paquet.
    var itemID: String = ""
    var angle: String = Card.Angle.listen
    var language: String = "es"
    /// Ce qui calcule l'échéance : l'échelle fixe d'aujourd'hui (`ReviewSchedule`),
    /// FSRS peut-être un jour. Les cartes d'une même file peuvent ainsi différer.
    var scheduler: String = Card.Scheduler.ladder
    /// Désactiver au lieu de supprimer : une phrase démarquée garde son historique,
    /// et le retrouve si elle est remarquée.
    var isActive: Bool = true
    var createdAt: Date = Date.now
    /// Dernière activation. La liste « À revoir » est triée dessus : une phrase
    /// remarquée remonte en tête, comme une phrase marquée pour la première fois.
    var activatedAt: Date = Date.now

    var dueAt: Date = Date.now
    var reps: Int = 0
    var lastReviewedAt: Date?

    /// Réservés à FSRS, jamais écrits par l'échelle.
    var stability: Double?
    var difficulty: Double?
    /// L'état FSRS (`FSRS.State`) et l'étape d'apprentissage. Nil sur une carte
    /// neuve : elle est en apprentissage, à l'étape 0. Ajoutés à l'étape 2 du
    /// vocabulaire, optionnels : migration légère.
    var fsrsState: String?
    var fsrsStep: Int?

    init(item: ItemID, angle: String, language: String, scheduler: String, at date: Date) {
        self.key = Self.makeKey(item: item, angle: angle)
        self.itemID = item.rawValue
        self.angle = angle
        self.language = language
        self.scheduler = scheduler
        self.createdAt = date
        self.activatedAt = date
        self.dueAt = date
    }

    static func makeKey(item: ItemID, angle: String) -> String {
        "\(item.rawValue)#\(angle)"
    }

    /// Une carte inactive n'est jamais due : elle attend d'être remarquée.
    func isDue(at now: Date) -> Bool { isActive && dueAt <= now }

    /// La phrase Assimil que la carte désigne ; nil pour un autre paquet, ou un
    /// identifiant illisible.
    var assimilItem: AssimilItem? { ItemID(itemID).flatMap(AssimilItem.init) }

    /// Le mot que la carte désigne, pour les cartes de vocabulaire.
    var vocabItem: VocabItem? { ItemID(itemID).flatMap(VocabItem.init) }

    /// Ce que FSRS sait de la carte. Une carte jamais notée est neuve, en
    /// apprentissage à l'étape 0.
    var fsrsMemory: FSRS.Memory {
        get {
            let state = fsrsState.flatMap(FSRS.State.init) ?? .learning
            return FSRS.Memory(state: state,
                               step: state == .review ? nil : (fsrsStep ?? 0),
                               stability: stability, difficulty: difficulty,
                               due: dueAt, lastReview: lastReviewedAt)
        }
        set {
            fsrsState = newValue.state.rawValue
            fsrsStep = newValue.step
            stability = newValue.stability
            difficulty = newValue.difficulty
            dueAt = newValue.due
            lastReviewedAt = newValue.lastReview
        }
    }

    /// « Connue » : passée en révision dans FSRS, c'est-à-dire réussie au moins une
    /// fois un autre jour que celui de sa découverte. C'est ce qui débloque la carte
    /// `recall` d'un mot (docs/module-vocabulaire.md).
    var isKnown: Bool { fsrsState == FSRS.State.review.rawValue }

    enum Angle {
        /// Réentendre la phrase et la redire.
        static let listen = "listen"
        /// Un mot : de l'espagnol vers son sens.
        static let recognize = "recognize"
        /// Un mot : du français vers l'espagnol. N'arrive qu'une fois `recognize` connue.
        static let recall = "recall"
    }

    enum Scheduler {
        /// Intervalles fixes, sans notation (`ReviewSchedule`).
        static let ladder = "ladder"
        static let fsrs = "fsrs"
    }
}

/// Une revue, ajoutée et jamais modifiée. C'est la source de vérité : l'échéance et
/// le compte de `Card` n'en sont qu'un cache, recalculable.
@Model
final class ReviewLog {
    #Index<ReviewLog>([\.cardKey], [\.reviewedAt])

    var cardKey: String = ""
    var reviewedAt: Date = Date.now
    /// Nil pour une revue mains libres : l'app ne demande pas de note en marchant.
    var rating: Int?
    var context: String = ReviewLog.Context.handsFree
    /// La phrase redite a-t-elle été reconnue, quand la revue était à voix haute.
    var spokenMatch: Bool?
    var durationMs: Int?

    init(cardKey: String, reviewedAt: Date, context: String, rating: Int? = nil) {
        self.cardKey = cardKey
        self.reviewedAt = reviewedAt
        self.context = context
        self.rating = rating
    }

    enum Context {
        static let handsFree = "handsFree"
        static let graded = "graded"
        static let spoken = "spoken"
    }
}

/// Un moment d'étude, par activité. Remplace `StudyDay`, qui n'a qu'un total par
/// jour et ne dit pas à quoi le temps a servi.
@Model
final class StudyEvent {
    #Index<StudyEvent>([\.day])

    /// Début de la journée locale : c'est sur lui qu'on agrège par jour.
    var day: Date = Date.now
    var startedAt: Date = Date.now
    var seconds: Double = 0
    var language: String = "es"
    var activity: String = ""
    /// « assimil-es » pour les activités Assimil, nil pour la révision, commune.
    var courseID: String?

    init(day: Date, startedAt: Date, seconds: Double, language: String, activity: String, courseID: String?) {
        self.day = day
        self.startedAt = startedAt
        self.seconds = seconds
        self.language = language
        self.activity = activity
        self.courseID = courseID
    }

    enum Activity {
        static let assimilDaily = "assimil.daily"
        static let review = "review"
        static let assimilListen = "assimil.listen"
        /// Le total d'un jour de l'ancien `StudyDay`, sans détail d'activité.
        static let assimilLegacy = "assimil.legacy"
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

/// Une migration de données menée à son terme. Inscrite dans le stockage et non dans
/// `UserDefaults` : elle voyage avec une sauvegarde, et restaurer une sauvegarde
/// d'avant la migration la relance, comme il faut.
@Model
final class DataMigration {
    #Unique<DataMigration>([\.key])

    var key: String = ""
    var completedAt: Date = Date.now

    init(key: String, completedAt: Date) {
        self.key = key
        self.completedAt = completedAt
    }
}
