import Foundation
import SwiftData

// L'état de l'apprenant, commun à tous les modules : cartes, journal des revues,
// temps d'étude. Le contenu n'y entre pas — une carte désigne son élément par
// `ItemID`, le paquet fournit le reste.
//
// Ces tables s'ajoutent aux anciennes (migration légère). Pour l'instant, seule la
// copie (`LegacyCopy`) les écrit, et rien ne les lit : la bascule vient ensuite.

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

    enum Angle {
        /// Réentendre la phrase et la redire : la seule révision qui existe.
        static let listen = "listen"
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

/// Un moment d'étude, par activité. Remplacera `StudyDay`, qui n'a qu'un total
/// par jour et ne dit pas à quoi le temps a servi.
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
