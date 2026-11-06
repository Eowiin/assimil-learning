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
