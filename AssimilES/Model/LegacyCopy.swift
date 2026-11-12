import Foundation
import OSLog
import SwiftData

/// Recopie l'ancien modèle (`DifficultSentence`, `StudyDay`) dans le nouveau (`Card`,
/// `StudyEvent`), avant que les vues ne s'affichent.
///
/// **Une synchronisation, pas une insertion unique.** Avant la bascule, l'app
/// écrivait encore l'ancien modèle : chaque lancement remettait les cartes à
/// l'identique de l'ancien modèle. Passée deux fois de suite, elle ne change rien.
///
/// **Depuis la bascule, elle ne passe qu'une fois** (`finishIfNeeded`) : une
/// dernière synchronisation, inscrite dans `DataMigration`. Ensuite, la relancer
/// serait destructeur — une carte marquée depuis n'a pas de `DifficultSentence` et
/// serait désactivée, une carte revue reprendrait l'ancienne échéance.
///
/// Les anciennes tables ne sont ni modifiées ni supprimées.
@MainActor
enum LegacyCopy {

    /// La clé inscrite dans `DataMigration` quand la dernière copie a réussi.
    static let completionKey = "legacy-copy"

    enum Outcome: Equatable {
        /// Déjà faite : rien n'est relu.
        case alreadyDone
        /// La dernière synchronisation vient de passer, et elle est inscrite.
        case finished(Report)
        /// Échec, journalisé : rien n'est inscrit, le prochain lancement réessaie.
        case failed
    }

    /// Au démarrage. L'inscription est enregistrée avec la copie, d'un même `save` :
    /// l'une ne peut pas exister sans l'autre. Restaurer une sauvegarde d'avant la
    /// bascule ramène un stockage sans inscription, et la copie repasse, comme il faut.
    ///
    /// Si l'inscription ne peut pas être lue, la copie ne passe pas : mieux vaut
    /// réessayer au lancement suivant que d'écraser des cartes déjà basculées.
    @discardableResult
    static func finishIfNeeded(in context: ModelContext, now: Date = .now) -> Outcome {
        let key = completionKey
        do {
            let done = try context.fetchCount(FetchDescriptor<DataMigration>(predicate: #Predicate { $0.key == key }))
            if done > 0 { return .alreadyDone }

            var report = Report()
            try syncCards(in: context, report: &report)
            try syncStudyTime(in: context, report: &report)
            context.insert(DataMigration(key: key, completedAt: now))
            try context.save()
            log.info("bascule : dernière copie, \(report.cardsCreated) cartes créées, \(report.cardsUpdated) mises à jour, \(report.cardsDeactivated) désactivées, \(report.eventsCreated + report.eventsUpdated) jours d'étude recopiés")
            return .finished(report)
        } catch {
            log.error("bascule interrompue : \(String(describing: error), privacy: .public)")
            context.rollback()
            return .failed
        }
    }

    struct Report: Equatable {
        var cardsCreated = 0
        var cardsUpdated = 0
        var cardsDeactivated = 0
        var eventsCreated = 0
        var eventsUpdated = 0
        /// Clés de `DifficultSentence` qu'`AssimilItem` ne sait pas lire.
        var skippedKeys: [String] = []
    }

    /// Une passe de synchronisation, sans inscription. L'app ne l'appelle plus
    /// directement (voir `finishIfNeeded`) ; les tests y vérifient la copie.
    ///
    /// Une erreur de lecture ou d'écriture est journalisée et la passe abandonnée :
    /// la copie ne doit jamais empêcher l'app de s'ouvrir, et la suivante reprendra.
    @discardableResult
    static func run(in context: ModelContext) -> Report? {
        do {
            var report = Report()
            try syncCards(in: context, report: &report)
            try syncStudyTime(in: context, report: &report)
            if context.hasChanges { try context.save() }
            log.info("copie : \(report.cardsCreated) cartes créées, \(report.cardsUpdated) mises à jour, \(report.cardsDeactivated) désactivées, \(report.eventsCreated + report.eventsUpdated) jours d'étude recopiés")
            return report
        } catch {
            log.error("copie interrompue : \(String(describing: error), privacy: .public)")
            context.rollback()
            return nil
        }
    }

    // MARK: - Phrases marquées → cartes

    private static func syncCards(in context: ModelContext, report: inout Report) throws {
        let marks = try context.fetch(FetchDescriptor<DifficultSentence>())
        // La clé est unique dans le stockage ; garder la première au cas où ne coûte rien.
        var cards = Dictionary(try context.fetch(FetchDescriptor<Card>()).map { ($0.key, $0) },
                               uniquingKeysWith: { first, _ in first })
        var marked = Set<String>()

        for mark in marks {
            guard let item = AssimilItem(legacyKey: mark.key) else {
                // Une clé illisible ne fait perdre que sa propre carte.
                log.error("copie : clé illisible ignorée « \(mark.key, privacy: .public) »")
                report.skippedKeys.append(mark.key)
                continue
            }
            let key = Card.makeKey(item: item.itemID(), angle: Card.Angle.listen)
            marked.insert(key)

            let card: Card
            let isNew: Bool
            if let existing = cards[key] {
                card = existing
                isNew = false
            } else {
                isNew = true
                card = Card(item: item.itemID(), angle: Card.Angle.listen, language: "es",
                            scheduler: Card.Scheduler.ladder, at: mark.markedAt)
                context.insert(card)
                cards[key] = card
                report.cardsCreated += 1
            }

            // N'écrire que ce qui diffère : une passe sans changement ne touche à rien.
            // `activatedAt` suit `markedAt` : une phrase démarquée puis remarquée a été
            // recréée dans l'ancien modèle, sa carte réactivée remonte avec elle.
            let changes = [
                assign(mark.markedAt, to: \.activatedAt, of: card),
                assign(mark.dueAt, to: \.dueAt, of: card),
                assign(mark.reviewCount, to: \.reps, of: card),
                assign(mark.lastReviewedAt, to: \.lastReviewedAt, of: card),
                assign(true, to: \.isActive, of: card),
            ]
            if changes.contains(true), !isNew { report.cardsUpdated += 1 }
        }

        // Une carte de l'échelle encore active sans phrase marquée : la phrase a été
        // démarquée entre deux lancements. Désactivée, pas supprimée.
        for card in cards.values
        where card.scheduler == Card.Scheduler.ladder && card.isActive && !marked.contains(card.key) {
            card.isActive = false
            report.cardsDeactivated += 1
        }
    }

    // MARK: - Jours d'étude → événements

    /// Un `StudyDay` donne un événement « assimil.legacy » par jour, retrouvé par
    /// (activité, jour) et mis à jour quand le jour a grossi.
    private static func syncStudyTime(in context: ModelContext, report: inout Report) throws {
        let legacy = StudyEvent.Activity.assimilLegacy
        let days = try context.fetch(FetchDescriptor<StudyDay>())
        var events = Dictionary(
            try context.fetch(FetchDescriptor<StudyEvent>(predicate: #Predicate { $0.activity == legacy }))
                .map { ($0.day, $0) },
            uniquingKeysWith: { first, _ in first })

        for studyDay in days {
            if let event = events[studyDay.day] {
                if assign(studyDay.seconds, to: \.seconds, of: event) { report.eventsUpdated += 1 }
            } else {
                // `StudyDay.day` est déjà le début de la journée : il sert de jour et
                // de début, faute de mieux.
                let event = StudyEvent(day: studyDay.day, startedAt: studyDay.day, seconds: studyDay.seconds,
                                       language: "es", activity: legacy, courseID: PackStore.assimilSpanishID)
                context.insert(event)
                events[studyDay.day] = event
                report.eventsCreated += 1
            }
        }
    }

    // MARK: -

    private static func assign<Model: AnyObject, Value: Equatable>(
        _ value: Value, to keyPath: ReferenceWritableKeyPath<Model, Value>, of model: Model
    ) -> Bool {
        guard model[keyPath: keyPath] != value else { return false }
        model[keyPath: keyPath] = value
        return true
    }

    private static let log = Logger(subsystem: "com.ethansaux.AssimilES", category: "data")
}
