import Foundation
import SwiftData

/// Ce que la révision fait aux cartes. Les vues n'écrivent pas les champs d'une carte
/// elles-mêmes : la règle tient ici, et les tests la vérifient.
///
/// Il n'y a plus que des cartes notées (FSRS) : la révision des phrases marquées au
/// drapeau, sur une échelle fixe de 1 à 60 jours, a été retirée avec le drapeau
/// (étape 4 du vocabulaire, docs/module-vocabulaire.md).
@MainActor
enum CardReview {

    /// Une carte notée : l'échéance suit la note, et le journal reçoit la revue avec
    /// sa note — c'est lui qui permettra un jour d'optimiser FSRS.
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

    /// Les cartes de phrases marquées (`#listen`) n'ont plus de révision : elles sont
    /// désactivées, pas supprimées — leur historique reste au journal. Au démarrage ;
    /// sans effet une fois fait. Rend le nombre de cartes désactivées.
    @discardableResult
    static func retireListenCards(in context: ModelContext) -> Int {
        let listen = Card.Angle.listen
        let descriptor = FetchDescriptor<Card>(predicate: #Predicate { $0.angle == listen && $0.isActive })
        guard let cards = try? context.fetch(descriptor), !cards.isEmpty else { return 0 }
        cards.forEach { $0.isActive = false }
        try? context.save()
        return cards.count
    }
}
