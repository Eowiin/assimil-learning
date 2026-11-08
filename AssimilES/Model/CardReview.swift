import Foundation
import SwiftData

/// Ce que la révision et le drapeau font aux cartes. Les vues n'écrivent pas les
/// champs d'une carte elles-mêmes : la règle tient ici, et les tests la vérifient.
@MainActor
enum CardReview {

    /// Une carte vient d'être rejouée en révision. L'intervalle est choisi sur le
    /// nombre de revues **avant** celle-ci : la première reprise tombe le
    /// lendemain. Le journal reçoit la revue — c'est lui la source de vérité,
    /// l'échéance et le compte n'en sont qu'un cache.
    static func review(_ card: Card, at date: Date, in context: ModelContext) {
        card.dueAt = ReviewSchedule.next(after: card.reps, from: date)
        card.reps += 1
        card.lastReviewedAt = date
        // Pas de note : la révision se fait en marchant, sans l'œil sur l'écran.
        context.insert(ReviewLog(cardKey: card.key, reviewedAt: date, context: ReviewLog.Context.handsFree))
    }

    /// Une carte notée (FSRS) : l'échéance suit la note, et le journal reçoit la
    /// revue avec sa note — c'est lui qui permettra un jour d'optimiser FSRS.
    static func grade(_ card: Card, _ rating: FSRS.Rating, at date: Date,
                      durationMs: Int? = nil, in context: ModelContext) {
        card.fsrsMemory = FSRS.review(card.fsrsMemory, rating: rating, at: date)
        card.reps += 1
        let log = ReviewLog(cardKey: card.key, reviewedAt: date, context: ReviewLog.Context.graded,
                            rating: rating.rawValue)
        log.durationMs = durationMs
        context.insert(log)
    }

    /// Quand la carte reviendrait pour chaque note : ce qu'on affiche sous les
    /// boutons, comme dans Anki. Rien n'est écrit.
    static func preview(_ card: Card, at date: Date) -> [FSRS.Rating: Date] {
        Dictionary(uniqueKeysWithValues: FSRS.Rating.allCases.map {
            ($0, FSRS.review(card.fsrsMemory, rating: $0, at: date).due)
        })
    }

    /// Le drapeau, sur une phrase. Carte active : désactivée — la phrase est
    /// acquise, son historique reste. Carte inactive : réactivée et remise à zéro,
    /// due tout de suite, en tête de la liste. Pas de carte : créée.
    ///
    /// Rend vrai quand la phrase est marquée après le geste.
    @discardableResult
    static func toggleFlag(on item: AssimilItem, cards: [Card], at date: Date,
                           in context: ModelContext) -> Bool {
        let id = item.itemID()
        let key = Card.makeKey(item: id, angle: Card.Angle.listen)

        guard let card = cards.first(where: { $0.key == key }) else {
            context.insert(Card(item: id, angle: Card.Angle.listen, language: "es",
                                scheduler: Card.Scheduler.ladder, at: date))
            return true
        }
        if card.isActive {
            card.isActive = false
            return false
        }
        // Comme une phrase marquée pour la première fois, sauf `createdAt` et le
        // journal, qui gardent le passé.
        card.isActive = true
        card.activatedAt = date
        card.dueAt = date
        card.reps = 0
        return true
    }
}

/// Les phrases déjà comptées comme revues dans une séance de révision. Revenir en
/// arrière et rejouer une phrase ne doit pas repousser son échéance une seconde
/// fois, ni ajouter une seconde ligne au journal.
///
/// Par étape et non par carte : la séance est reconstruite à chaque ouverture,
/// ses étapes avec elle. Une nouvelle séance revoit donc la phrase, comme avant.
struct SessionReviews {
    private var reviewed: Set<UUID> = []

    /// Rend vrai quand la revue a été enregistrée.
    @MainActor
    @discardableResult
    mutating func record(_ step: SessionStep, cards: [Card], at date: Date, in context: ModelContext) -> Bool {
        guard !reviewed.contains(step.id),
              let key = step.markKey,
              let card = cards.first(where: { $0.key == key && $0.isActive })
        else { return false }
        reviewed.insert(step.id)
        CardReview.review(card, at: date, in: context)
        return true
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
